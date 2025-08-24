// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Custom errors for gas optimization
error NotOwner();
error NotCreator();
error ContractPaused();
error InvalidCreator();
error InvalidTierIndex();
error InsufficientPayment();
error TokenNotSupported();
error TransferFailed();
error InvalidAddress();
error NoActiveSubscription();
error NoSuspendedSubscription();
error InvalidDuration();
error NoFundsToWithdraw();

contract SubscriptionPlatform is ReentrancyGuard {
    using SubscriptionLib for uint256;

    address public owner;
    uint256 public platformFeePercent = 500; // 5% in basis points (500/10000)
    uint256 public gracePeriod = 7 days;
    bool public paused = false;

    IERC20 public defaultPaymentToken;

    // Mappings
    mapping(address => mapping(address => uint256)) public creatorSubscriptions; // creator -> user -> expiry
    mapping(address => bool) public creators;
    mapping(address => SubscriptionPlan[]) public creatorTiers;
    mapping(address => CreatorAnalytics) public creatorAnalytics;
    mapping(address => SubscriptionRecord[]) public subscriptionHistory;
    mapping(address => mapping(address => bool)) public autoRenewal; 
    mapping(address => bool) public whitelistedTokens;
    mapping(address => mapping(address => uint256)) public suspendedSubscriptions;

    // Structs
    struct SubscriptionPlan {
        uint256 fee;           // ETH fee
        uint256 tokenFee;      // Token fee  
        uint256 duration;      // Duration in seconds
        string metadata;       // Plan description
        string benefits;       // Plan benefits
        bool active;           // Plan status
    }

    struct SubscriptionRecord {
        address user;
        address creator;
        uint256 startTime;
        uint256 endTime;
        uint256 amountPaid;
        string paymentMethod;
    }

    struct CreatorAnalytics {
        uint128 totalEarningsETH;
        uint128 totalEarningsTokens;
        uint64 activeSubscribers;
        uint64 totalSubscribers;
    }

    // Events
    event Subscribed(address indexed user, address indexed creator, uint256 expiry);
    event SubscribedWithToken(address indexed user, address indexed creator, uint256 expiry);
    event AutoRenewalEnabled(address indexed creator, address indexed user);
    event AutoRenewalDisabled(address indexed creator, address indexed user);
    event SubscriptionSuspended(address indexed user, address indexed creator, uint256 expiry);
    event SubscriptionReactivated(address indexed user, address indexed creator, uint256 expiry);
    event CreatorAdded(address indexed creator);
    event CreatorRemoved(address indexed creator);
    event PlanUpdated(
        address indexed creator, 
        uint256 indexed tierIndex, 
        uint256 fee, 
        uint256 tokenFee, 
        uint256 duration, 
        string metadata, 
        string benefits
    );
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event TokenWhitelisted(address indexed token);
    event TokenRemovedFromWhitelist(address indexed token);
    event Paused();
    event Unpaused();
    event ETHWithdrawn(address indexed to, uint256 amount);
    event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);

    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyCreator() {
        if (!creators[msg.sender]) revert NotCreator();
        _;
    }

    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier validAddress(address _addr) {
        if (_addr == address(0)) revert InvalidAddress();
        _;
    }

    constructor(address _defaultTokenAddress) validAddress(_defaultTokenAddress) {
        owner = msg.sender;
        defaultPaymentToken = IERC20(_defaultTokenAddress);
        creators[msg.sender] = true;
        whitelistedTokens[_defaultTokenAddress] = true;
        
        emit CreatorAdded(msg.sender);
        emit TokenWhitelisted(_defaultTokenAddress);
    }

    // -------------------------
    // Subscription Functions
    // -------------------------
    function subscribe(address creator, uint256 tierIndex) 
        external 
        payable 
        notPaused 
        validAddress(creator)
        nonReentrant
    {
        if (!creators[creator]) revert InvalidCreator();
        if (tierIndex >= creatorTiers[creator].length) revert InvalidTierIndex();

        SubscriptionPlan memory plan = creatorTiers[creator][tierIndex];
        if (!plan.active) revert InvalidTierIndex();
        if (plan.duration == 0) revert InvalidDuration();
        if (msg.value < plan.fee) revert InsufficientPayment();

        _processSubscription(creator, plan.duration, msg.value, 0, "ETH");

        // Refund excess payment
        if (msg.value > plan.fee) {
            (bool success, ) = msg.sender.call{value: msg.value - plan.fee}("");
            if (!success) revert TransferFailed();
        }

        emit Subscribed(msg.sender, creator, creatorSubscriptions[creator][msg.sender]);
    }

    function subscribeWithToken(
        address creator,
        uint256 tierIndex,
        address token,
        uint256 amount
    ) external notPaused validAddress(creator) validAddress(token) nonReentrant {
        if (!creators[creator]) revert InvalidCreator();
        if (tierIndex >= creatorTiers[creator].length) revert InvalidTierIndex();
        if (!whitelistedTokens[token]) revert TokenNotSupported();

        SubscriptionPlan memory plan = creatorTiers[creator][tierIndex];
        if (!plan.active) revert InvalidTierIndex();
        if (plan.duration == 0) revert InvalidDuration();
        if (amount < plan.tokenFee) revert InsufficientPayment();

        IERC20 paymentToken = IERC20(token);
        if (!paymentToken.transferFrom(msg.sender, address(this), plan.tokenFee)) revert TransferFailed();

        _processSubscription(creator, plan.duration, 0, plan.tokenFee, "Token");

        emit SubscribedWithToken(msg.sender, creator, creatorSubscriptions[creator][msg.sender]);
    }

    function enableAutoRenewal(address creator) external validAddress(creator) {
        autoRenewal[creator][msg.sender] = true;
        emit AutoRenewalEnabled(creator, msg.sender);
    }

    function disableAutoRenewal(address creator) external validAddress(creator) {
        autoRenewal[creator][msg.sender] = false;
        emit AutoRenewalDisabled(creator, msg.sender);
    }

    function suspendSubscription(address creator) external validAddress(creator) {
        if (creatorSubscriptions[creator][msg.sender] <= block.timestamp) revert NoActiveSubscription();
        
        suspendedSubscriptions[creator][msg.sender] = creatorSubscriptions[creator][msg.sender];
        creatorSubscriptions[creator][msg.sender] = 0;
        
        // Decrement active subscriber count
        if (creatorAnalytics[creator].activeSubscribers > 0) {
            creatorAnalytics[creator].activeSubscribers--;
        }
        
        emit SubscriptionSuspended(msg.sender, creator, suspendedSubscriptions[creator][msg.sender]);
    }

    function reactivateSubscription(address creator) external validAddress(creator) {
        if (suspendedSubscriptions[creator][msg.sender] == 0) revert NoSuspendedSubscription();
        
        creatorSubscriptions[creator][msg.sender] = suspendedSubscriptions[creator][msg.sender];
        suspendedSubscriptions[creator][msg.sender] = 0;
        
        // Increment active subscriber count if still valid
        if (creatorSubscriptions[creator][msg.sender] > block.timestamp) {
            creatorAnalytics[creator].activeSubscribers++;
        }
        
        emit SubscriptionReactivated(msg.sender, creator, creatorSubscriptions[creator][msg.sender]);
    }

    function _processSubscription(
        address creator,
        uint256 duration,
        uint256 ethPaid,
        uint256 tokensPaid,
        string memory paymentMethod
    ) internal {
        bool wasExpired = creatorSubscriptions[creator][msg.sender] <= block.timestamp;
        bool isNewSubscriber = creatorSubscriptions[creator][msg.sender] == 0;

        // Calculate new expiry time
        uint256 newExpiry = SubscriptionLib.calculateNewExpiry(
            creatorSubscriptions[creator][msg.sender],
            duration
        );

        creatorSubscriptions[creator][msg.sender] = newExpiry;

        // Update analytics
        if (isNewSubscriber) {
            creatorAnalytics[creator].totalSubscribers++;
        }
        if (wasExpired) {
            creatorAnalytics[creator].activeSubscribers++;
        }

        // Update earnings
        if (ethPaid > 0) {
            creatorAnalytics[creator].totalEarningsETH += uint128(ethPaid);
        }
        if (tokensPaid > 0) {
            creatorAnalytics[creator].totalEarningsTokens += uint128(tokensPaid);
        }

        // Record subscription history
        subscriptionHistory[msg.sender].push(
            SubscriptionRecord({
                user: msg.sender,
                creator: creator,
                startTime: block.timestamp,
                endTime: newExpiry,
                amountPaid: ethPaid > 0 ? ethPaid : tokensPaid,
                paymentMethod: paymentMethod
            })
        );
    }

    // -------------------------
    // Creator Management
    // -------------------------
    function addCreator(address creator) external onlyOwner validAddress(creator) {
        creators[creator] = true;
        emit CreatorAdded(creator);
    }

    function removeCreator(address creator) external onlyOwner validAddress(creator) {
        creators[creator] = false;
        
        // Clean up data
        delete creatorTiers[creator];
        delete creatorAnalytics[creator];
        
        emit CreatorRemoved(creator);
    }

    function updateCreatorPlan(
        uint256 tierIndex,
        uint256 fee,
        uint256 tokenFee,
        uint256 duration,
        string calldata metadata,
        string calldata benefits,
        bool active
    ) external onlyCreator {
        if (duration == 0) revert InvalidDuration();

        SubscriptionPlan memory newPlan = SubscriptionPlan({
            fee: fee,
            tokenFee: tokenFee,
            duration: duration,
            metadata: metadata,
            benefits: benefits,
            active: active
        });

        if (tierIndex < creatorTiers[msg.sender].length) {
            creatorTiers[msg.sender][tierIndex] = newPlan;
        } else {
            creatorTiers[msg.sender].push(newPlan);
        }
        
        emit PlanUpdated(msg.sender, tierIndex, fee, tokenFee, duration, metadata, benefits);
    }

    function togglePlanStatus(uint256 tierIndex) external onlyCreator {
        if (tierIndex >= creatorTiers[msg.sender].length) revert InvalidTierIndex();
        
        creatorTiers[msg.sender][tierIndex].active = !creatorTiers[msg.sender][tierIndex].active;
    }

    // -------------------------
    // Platform Controls
    // -------------------------
    function addWhitelistedToken(address token) external onlyOwner validAddress(token) {
        whitelistedTokens[token] = true;
        emit TokenWhitelisted(token);
    }

    function removeWhitelistedToken(address token) external onlyOwner validAddress(token) {
        whitelistedTokens[token] = false;
        emit TokenRemovedFromWhitelist(token);
    }

    function updatePlatformFee(uint256 newFeePercent) external onlyOwner {
        require(newFeePercent <= 1000, "Fee too high"); // Max 10%
        uint256 oldFee = platformFeePercent;
        platformFeePercent = newFeePercent;
        emit PlatformFeeUpdated(oldFee, newFeePercent);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }

    function transferOwnership(address newOwner) external onlyOwner validAddress(newOwner) {
        owner = newOwner;
        creators[newOwner] = true;
        emit CreatorAdded(newOwner);
    }

    // -------------------------
    // Withdrawal Functions
    // -------------------------
    function withdrawETH(uint256 amount) external onlyOwner {
        if (amount > address(this).balance) revert NoFundsToWithdraw();
        
        (bool success, ) = owner.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit ETHWithdrawn(owner, amount);
    }

    function withdrawTokens(address token, uint256 amount) external onlyOwner validAddress(token) {
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        
        if (amount > balance) revert NoFundsToWithdraw();
        if (!tokenContract.transfer(owner, amount)) revert TransferFailed();
        
        emit TokensWithdrawn(token, owner, amount);
    }

    function emergencyWithdrawAll() external onlyOwner {
        // Withdraw all ETH
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool success, ) = owner.call{value: ethBalance}("");
            if (!success) revert TransferFailed();
        }
    }

    // -------------------------
    // View Functions
    // -------------------------
    function isSubscriptionActive(address creator, address user) external view returns (bool) {
        return creatorSubscriptions[creator][user] > block.timestamp;
    }

    function getSubscriptionExpiry(address creator, address user) external view returns (uint256) {
        return creatorSubscriptions[creator][user];
    }

    function getCreatorTiersCount(address creator) external view returns (uint256) {
        return creatorTiers[creator].length;
    }

    function getCreatorTier(address creator, uint256 tierIndex) external view returns (SubscriptionPlan memory) {
        if (tierIndex >= creatorTiers[creator].length) revert InvalidTierIndex();
        return creatorTiers[creator][tierIndex];
    }

    function getSubscriptionHistory(address user) external view returns (SubscriptionRecord[] memory) {
        return subscriptionHistory[user];
    }

    function getUserActiveSubscriptions(address user) external view returns (address[] memory) {
        // This is a simple implementation - in production, you'd want to optimize this
        address[] memory tempArray = new address[](100); // Assuming max 100 creators
        uint256 count = 0;
        
        // Note: In a real implementation, you'd maintain a separate mapping for this
        // This is just for demonstration
        return tempArray; // Placeholder
    }

    function getCreatorAnalytics(address creator) external view returns (CreatorAnalytics memory) {
        return creatorAnalytics[creator];
    }

    // -------------------------
    // Auto-renewal (placeholder for future implementation)
    // -------------------------
    function processAutoRenewals(address[] calldata creators, address[] calldata users) external onlyOwner {
        // Implementation for batch processing auto-renewals
        // This would typically be called by a backend service or chainlink automation
        for (uint256 i = 0; i < creators.length; i++) {
            if (autoRenewal[creators[i]][users[i]] && 
                creatorSubscriptions[creators[i]][users[i]] <= block.timestamp + gracePeriod) {
                // Auto-renewal logic here
                // Would need to handle payment from user's wallet or pre-authorized amounts
            }
        }
    }

    // -------------------------
    // Fallback and Receive
    // -------------------------
    receive() external payable {
        // Allow contract to receive ETH
    }
}

// Library for subscription calculations
library SubscriptionLib {
    function calculateNewExpiry(uint256 currentExpiry, uint256 duration) 
        internal 
        view 
        returns (uint256) 
    {
        uint256 baseTime = currentExpiry > block.timestamp ? currentExpiry : block.timestamp;
        return baseTime + duration;
    }

    function isExpired(uint256 expiry) internal view returns (bool) {
        return expiry <= block.timestamp;
    }

    function timeUntilExpiry(uint256 expiry) internal view returns (uint256) {
        if (expiry <= block.timestamp) return 0;
        return expiry - block.timestamp;
    }
}