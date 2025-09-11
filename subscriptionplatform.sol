solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

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
error AlreadySuspended();
error InvalidFee();
error InvalidStringLength();
error ArrayLengthMismatch();
error TierLimitExceeded();
error PlanNotActive();
error InsufficientAllowance();
error PendingOwnerOnly();

contract SubscriptionPlatform is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    
    address public pendingOwnerOverride;
    uint256 public platformFeePercent = 500; // 5% in basis points (500/10000)
    uint256 public gracePeriod = 7 days;
    uint256 public constant MAX_TIERS = 10;
    uint256 public constant MAX_FEE_PERCENT = 1000; // 10%
    uint256 public constant MAX_HISTORY_RECORDS = 100; // Limit subscription history
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
    mapping(address => mapping(address => uint256)) public userTierIndex; // user -> creator -> tier index
    mapping(address => address[]) public userActiveSubscriptions; // user -> list of creators

    // Arrays for iterable access
    address[] public allWhitelistedTokens;

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
        uint256 tierIndex;
        uint256 startTime;
        uint256 endTime;
        uint256 amountPaid;
        address paymentToken;  // address(0) for ETH
    }

    struct CreatorAnalytics {
        uint128 totalEarningsETH;
        uint128 totalEarningsTokens;
        uint32 totalSubscribers;
        // Active subscribers calculated on-demand to ensure accuracy
    }

    // Events
    event Subscribed(address indexed user, address indexed creator, uint256 tierIndex, uint256 expiry);
    event SubscribedWithToken(address indexed user, address indexed creator, uint256 tierIndex, uint256 expiry);
    event AutoRenewalEnabled(address indexed creator, address indexed user);
    event AutoRenewalDisabled(address indexed creator, address indexed user);
    event SubscriptionSuspended(address indexed user, address indexed creator, uint256 expiry);
    event SubscriptionReactivated(address indexed user, address indexed creator, uint256 expiry);
    event SubscriptionCancelled(address indexed user, address indexed creator);
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
    event PlanStatusToggled(address indexed creator, uint256 indexed tierIndex, bool active);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event TokenWhitelisted(address indexed token);
    event TokenRemovedFromWhitelist(address indexed token);
    event Paused();
    event Unpaused();
    event ETHWithdrawn(address indexed to, uint256 amount);
    event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);
    event FeesDistributed(address indexed creator, uint256 creatorShare, uint256 platformFee);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner()) revert NotOwner();
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

    modifier validString(string calldata _str, uint256 maxLength) {
        if (bytes(_str).length == 0) revert InvalidStringLength();
        if (bytes(_str).length > maxLength) revert InvalidStringLength();
        _;
    }

    modifier hasSufficientAllowance(address token, uint256 amount) {
        if (token != address(0) && IERC20(token).allowance(msg.sender, address(this)) < amount) {
            revert InsufficientAllowance();
        }
        _;
    }

    constructor(address _defaultTokenAddress) validAddress(_defaultTokenAddress) {
        _transferOwnership(msg.sender);
        defaultPaymentToken = IERC20(_defaultTokenAddress);
        creators[msg.sender] = true;
        whitelistedTokens[_defaultTokenAddress] = true;
        allWhitelistedTokens.push(_defaultTokenAddress);
        
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
        if (!plan.active) revert PlanNotActive();
        if (plan.duration < 1 days || plan.duration > 365 days) revert InvalidDuration();
        if (msg.value < plan.fee) revert InsufficientPayment();

        // Calculate and distribute fees
        (uint256 creatorShare, uint256 platformFee) = _calculateFees(plan.fee);
        _distributeETHFees(creator, creatorShare, platformFee);

        _processSubscription(creator, tierIndex, plan.duration, plan.fee, address(0));

        // Refund excess payment
        if (msg.value > plan.fee) {
            (bool success, ) = msg.sender.call{value: msg.value - plan.fee}("");
            if (!success) revert TransferFailed();
        }

        emit Subscribed(msg.sender, creator, tierIndex, creatorSubscriptions[creator][msg.sender]);
    }

    function subscribeWithToken(
        address creator,
        uint256 tierIndex,
        address token
    ) external 
      notPaused 
      validAddress(creator) 
      validAddress(token) 
      hasSufficientAllowance(token, creatorTiers[creator][tierIndex].tokenFee)
      nonReentrant 
    {
        if (!creators[creator]) revert InvalidCreator();
        if (tierIndex >= creatorTiers[creator].length) revert InvalidTierIndex();
        if (!whitelistedTokens[token]) revert TokenNotSupported();

        SubscriptionPlan memory plan = creatorTiers[creator][tierIndex];
        if (!plan.active) revert PlanNotActive();
        if (plan.duration < 1 days || plan.duration > 365 days) revert InvalidDuration();

        IERC20 paymentToken = IERC20(token);
        
        // Calculate and distribute fees
        (uint256 creatorShare, uint256 platformFee) = _calculateFees(plan.tokenFee);
        _distributeTokenFees(creator, paymentToken, plan.tokenFee, creatorShare, platformFee);

        _processSubscription(creator, tierIndex, plan.duration, plan.tokenFee, token);

        emit SubscribedWithToken(msg.sender, creator, tierIndex, creatorSubscriptions[creator][msg.sender]);
    }

    function enableAutoRenewal(address creator) external validAddress(creator) {
        if (!_isSubscriptionActive(creator, msg.sender)) revert NoActiveSubscription();
        
        autoRenewal[creator][msg.sender] = true;
        emit AutoRenewalEnabled(creator, msg.sender);
    }

    function disableAutoRenewal(address creator) external validAddress(creator) {
        autoRenewal[creator][msg.sender] = false;
        emit AutoRenewalDisabled(creator, msg.sender);
    }

    function suspendSubscription(address creator) external validAddress(creator) {
        if (suspendedSubscriptions[creator][msg.sender] > 0) revert AlreadySuspended();
        if (!_isSubscriptionActive(creator, msg.sender)) revert NoActiveSubscription();
        
        suspendedSubscriptions[creator][msg.sender] = creatorSubscriptions[creator][msg.sender];
        creatorSubscriptions[creator][msg.sender] = 0;
        
        // Remove from active subscriptions list
        _removeActiveSubscription(msg.sender, creator);
        
        emit SubscriptionSuspended(msg.sender, creator, suspendedSubscriptions[creator][msg.sender]);
    }

    function reactivateSubscription(address creator) external validAddress(creator) {
        if (suspendedSubscriptions[creator][msg.sender] == 0) revert NoSuspendedSubscription();
        
        creatorSubscriptions[creator][msg.sender] = suspendedSubscriptions[creator][msg.sender];
        suspendedSubscriptions[creator][msg.sender] = 0;
        
        // Add to active subscriptions list if still valid
        if (_isSubscriptionActive(creator, msg.sender)) {
            _addActiveSubscription(msg.sender, creator);
        }
        
        emit SubscriptionReactivated(msg.sender, creator, creatorSubscriptions[creator][msg.sender]);
    }

    function cancelSuspendedSubscription(address creator) external validAddress(creator) {
        if (suspendedSubscriptions[creator][msg.sender] == 0) revert NoSuspendedSubscription();
        
        delete suspendedSubscriptions[creator][msg.sender];
        delete userTierIndex[msg.sender][creator];
        
        emit SubscriptionCancelled(msg.sender, creator);
    }

    function _processSubscription(
        address creator,
        uint256 tierIndex,
        uint256 duration,
        uint256 amountPaid,
        address paymentToken
    ) internal {
        bool wasExpired = !_isSubscriptionActive(creator, msg.sender);
        bool isNewSubscriber = creatorSubscriptions[creator][msg.sender] == 0;

        // Calculate new expiry time
        uint256 newExpiry = _calculateNewExpiry(creatorSubscriptions[creator][msg.sender], duration);

        creatorSubscriptions[creator][msg.sender] = newExpiry;
        userTierIndex[msg.sender][creator] = tierIndex;

        // Update analytics
        if (isNewSubscriber) {
            creatorAnalytics[creator].totalSubscribers++;
        }
        
        // Add to active subscriptions list
        _addActiveSubscription(msg.sender, creator);

        // Record subscription history (with limit)
        if (subscriptionHistory[msg.sender].length >= MAX_HISTORY_RECORDS) {
            // Remove the oldest record to make space
            for (uint256 i = 0; i < subscriptionHistory[msg.sender].length - 1; i++) {
                subscriptionHistory[msg.sender][i] = subscriptionHistory[msg.sender][i + 1];
            }
            subscriptionHistory[msg.sender].pop();
        }
        
        subscriptionHistory[msg.sender].push(
            SubscriptionRecord({
                user: msg.sender,
                creator: creator,
                tierIndex: tierIndex,
                startTime: block.timestamp,
                endTime: newExpiry,
                amountPaid: amountPaid,
                paymentToken: paymentToken
            })
        );
    }

    function _addActiveSubscription(address user, address creator) internal {
        // Check if already in the list
        for (uint256 i = 0; i < userActiveSubscriptions[user].length; i++) {
            if (userActiveSubscriptions[user][i] == creator) {
                return;
            }
        }
        
        userActiveSubscriptions[user].push(creator);
    }
    
    function _removeActiveSubscription(address user, address creator) internal {
        for (uint256 i = 0; i < userActiveSubscriptions[user].length; i++) {
            if (userActiveSubscriptions[user][i] == creator) {
                // Swap with last element and pop
                userActiveSubscriptions[user][i] = userActiveSubscriptions[user][userActiveSubscriptions[user].length - 1];
                userActiveSubscriptions[user].pop();
                return;
            }
        }
    }

    function _calculateNewExpiry(uint256 currentExpiry, uint256 duration) 
        internal 
        view 
        returns (uint256) 
    {
        uint256 baseTime = currentExpiry > block.timestamp ? currentExpiry : block.timestamp;
        return baseTime + duration;
    }

    function _calculateFees(uint256 amount) internal view returns (uint256 creatorShare, uint256 platformFee) {
        platformFee = (amount * platformFeePercent) / 10000;
        creatorShare = amount - platformFee;
    }

    function _distributeETHFees(address creator, uint256 creatorShare, uint256 platformFee) internal {
        // Transfer creator share
        (bool success1, ) = creator.call{value: creatorShare}("");
        if (!success1) revert TransferFailed();

        // Transfer platform fee to owner
        (bool success2, ) = owner().call{value: platformFee}("");
        if (!success2) revert TransferFailed();

        emit FeesDistributed(creator, creatorShare, platformFee);
    }

    function _distributeTokenFees(
        address creator, 
        IERC20 token, 
        uint256 totalAmount,
        uint256 creatorShare, 
        uint256 platformFee
    ) internal {
        // Transfer creator share directly from user to creator
        token.safeTransferFrom(msg.sender, creator, creatorShare);

        // Transfer platform fee directly from user to owner
        token.safeTransferFrom(msg.sender, owner(), platformFee);

        emit FeesDistributed(creator, creatorShare, platformFee);
    }

    function _isSubscriptionActive(address creator, address user) internal view returns (bool) {
        uint256 expiry = creatorSubscriptions[creator][user];
        return expiry > block.timestamp || (expiry + gracePeriod > block.timestamp && expiry != 0);
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
    ) external onlyCreator 
      validString(metadata, 256)
      validString(benefits, 512) 
    {
        if (duration < 1 days || duration > 365 days) revert InvalidDuration();
        if (tierIndex >= MAX_TIERS) revert TierLimitExceeded();

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
            if (creatorTiers[msg.sender].length >= MAX_TIERS) revert TierLimitExceeded();
            creatorTiers[msg.sender].push(newPlan);
        }
        
        emit PlanUpdated(msg.sender, tierIndex, fee, tokenFee, duration, metadata, benefits);
    }

    function togglePlanStatus(uint256 tierIndex) external onlyCreator {
        if (tierIndex >= creatorTiers[msg.sender].length) revert InvalidTierIndex();
        
        bool newStatus = !creatorTiers[msg.sender][tierIndex].active;
        creatorTiers[msg.sender][tierIndex].active = newStatus;
        
        emit PlanStatusToggled(msg.sender, tierIndex, newStatus);
    }

    // -------------------------
    // Platform Controls
    // -------------------------
    function addWhitelistedToken(address token) external onlyOwner validAddress(token) {
        if (!whitelistedTokens[token]) {
            whitelistedTokens[token] = true;
            allWhitelistedTokens.push(token);
            emit TokenWhitelisted(token);
        }
    }

    function removeWhitelistedToken(address token) external onlyOwner validAddress(token) {
        if (whitelistedTokens[token]) {
            whitelistedTokens[token] = false;
            
            // Remove from the list
            for (uint256 i = 0; i < allWhitelistedTokens.length; i++) {
                if (allWhitelistedTokens[i] == token) {
                    allWhitelistedTokens[i] = allWhitelistedTokens[allWhitelistedTokens.length - 1];
                    allWhitelistedTokens.pop();
                    break;
                }
            }
            
            emit TokenRemovedFromWhitelist(token);
        }
    }

    function updatePlatformFee(uint256 newFeePercent) external onlyOwner {
        if (newFeePercent > MAX_FEE_PERCENT) revert InvalidFee();
        
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

    // Override Ownable2Step functions for safe ownership transfer
    function transferOwnership(address newOwner) public override onlyOwner validAddress(newOwner) {
        pendingOwnerOverride = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwnerOverride) {
            revert PendingOwnerOnly();
        }
        _transferOwnership(msg.sender);
        pendingOwnerOverride = address(0);
    }

    // -------------------------
    // Withdrawal Functions
    // -------------------------
    function withdrawETH(uint256 amount) external onlyOwner {
        if (amount > address(this).balance) revert NoFundsToWithdraw();
        
        (bool success, ) = owner().call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit ETHWithdrawn(owner(), amount);
    }

    function withdrawTokens(address token, uint256 amount) external onlyOwner validAddress(token) {
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        
        if (amount > balance) revert NoFundsToWithdraw();
        tokenContract.safeTransfer(owner(), amount);
        
        emit TokensWithdrawn(token, owner(), amount);
    }

    function emergencyWithdrawAll() external onlyOwner {
        // Withdraw all ETH
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool success, ) = owner().call{value: ethBalance}("");
            if (!success) revert TransferFailed();
            emit ETHWithdrawn(owner(), ethBalance);
        }
        
        // Withdraw all whitelisted tokens
        for (uint256 i = 0; i < allWhitelistedTokens.length; i++) {
            address token = allWhitelistedTokens[i];
            IERC20 tokenContract = IERC20(token);
            uint256 tokenBalance = tokenContract.balanceOf(address(this));
            
            if (tokenBalance > 0) {
                tokenContract.safeTransfer(owner(), tokenBalance);
                emit TokensWithdrawn(token, owner(), tokenBalance);
            }
        }
    }

    // -------------------------
    // View Functions
    // -------------------------
    function isSubscriptionActive(address creator, address user) external view returns (bool) {
        return _isSubscriptionActive(creator, user);
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

    function getUserActiveSubscriptions(address user) external view returns (address[] memory, uint256[] memory) {
        address[] memory activeCreators = userActiveSubscriptions[user];
        uint256[] memory expiryTimes = new uint256[](activeCreators.length);
        
        for (uint256 i = 0; i < activeCreators.length; i++) {
            expiryTimes[i] = creatorSubscriptions[activeCreators[i]][user];
        }
        
        return (activeCreators, expiryTimes);
    }

    function getActiveSubscriberCount(address creator) external view returns (uint32) {
        // Calculate active subscribers on-demand for accuracy
        uint32 count = 0;
        for (uint256 i = 0; i < userActiveSubscriptions[msg.sender].length; i++) {
            address user = userActiveSubscriptions[msg.sender][i];
            if (_isSubscriptionActive(creator, user)) {
                count++;
            }
        }
        return count;
    }

    function getCreatorAnalytics(address creator) external view returns (CreatorAnalytics memory) {
        return creatorAnalytics[creator];
    }

    // -------------------------
    // Auto-renewal processing
    // -------------------------
    function processAutoRenewals(address[] calldata creatorsList, address[] calldata users) external onlyOwner {
        if (creatorsList.length != users.length) revert ArrayLengthMismatch();
        
        for (uint256 i = 0; i < creatorsList.length; i++) {
            address creator = creatorsList[i];
            address user = users[i];
            
            if (autoRenewal[creator][user] && 
                creatorSubscriptions[creator][user] <= block.timestamp + gracePeriod) {
                
                uint256 tierIndex = userTierIndex[user][creator];
                SubscriptionPlan memory plan = creatorTiers[creator][tierIndex];
                
                if (plan.active && plan.duration > 0) {
                    // Process payment based on the original payment method
                    // This would need to be implemented based on your payment infrastructure
                    // For now, this is a placeholder
                }
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