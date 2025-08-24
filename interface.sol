// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ===== ISubscriptionPlatform.sol =====
interface ISubscriptionPlatform {
    // Structs (for interface compatibility)
    struct SubscriptionPlan {
        uint256 fee;
        uint256 tokenFee;
        uint256 duration;
        string metadata;
        string benefits;
        bool active;
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

    // Core subscription functions
    function subscribe(address creator, uint256 tierIndex) external payable;
    
    function subscribeWithToken(
        address creator,
        uint256 tierIndex,
        address token,
        uint256 amount
    ) external;

    function enableAutoRenewal(address creator) external;
    function disableAutoRenewal(address creator) external;
    function suspendSubscription(address creator) external;
    function reactivateSubscription(address creator) external;

    // View functions
    function isSubscriptionActive(address creator, address user) external view returns (bool);
    function getSubscriptionExpiry(address creator, address user) external view returns (uint256);
    function getCreatorAnalytics(address creator) external view returns (CreatorAnalytics memory);
}

// ===== ICreatorTiers.sol =====
interface ICreatorTiers {
    // Events
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

    // Creator management functions
    function addCreator(address creator) external;
    function removeCreator(address creator) external;
    
    function updateCreatorPlan(
        uint256 tierIndex,
        uint256 fee,
        uint256 tokenFee,
        uint256 duration,
        string calldata metadata,
        string calldata benefits,
        bool active
    ) external;

    function togglePlanStatus(uint256 tierIndex) external;

    // View functions
    function getCreatorTiersCount(address creator) external view returns (uint256);
    function getCreatorTier(address creator, uint256 tierIndex) 
        external 
        view 
        returns (ISubscriptionPlatform.SubscriptionPlan memory);
}

// ===== IPlatformAdmin.sol =====
interface IPlatformAdmin {
    // Events
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event TokenWhitelisted(address indexed token);
    event TokenRemovedFromWhitelist(address indexed token);
    event Paused();
    event Unpaused();
    event ETHWithdrawn(address indexed to, uint256 amount);
    event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);

    // Admin functions
    function addWhitelistedToken(address token) external;
    function removeWhitelistedToken(address token) external;
    function updatePlatformFee(uint256 newFeePercent) external;
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;

    // Withdrawal functions
    function withdrawETH(uint256 amount) external;
    function withdrawTokens(address token, uint256 amount) external;
    function emergencyWithdrawAll() external;
}