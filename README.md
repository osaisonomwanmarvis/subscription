# SubscriptionPlatform Smart Contract

## Overview

The SubscriptionPlatform is a robust Solidity smart contract that enables creators to offer subscription services to users. It supports both ETH and ERC20 token payments, includes automatic fee distribution, and provides features like auto-renewal, subscription suspension, and reactivation.

## Features

- **Multi-Tier Subscriptions**: Creators can create up to 10 subscription tiers with different pricing and benefits
- **Dual Payment Support**: Accepts both ETH and whitelisted ERC20 tokens
- **Auto-Renewal**: Users can enable automatic subscription renewal
- **Subscription Management**: Users can suspend and reactivate subscriptions
- **Fee Distribution**: Automatically distributes payments between creators and platform
- **Comprehensive Analytics**: Tracks creator earnings and subscriber counts
- **Emergency Controls**: Owner can pause the contract in case of issues

## Contract Details

### Key Components

- **SubscriptionPlan**: Defines subscription tiers with fees, duration, and metadata
- **SubscriptionRecord**: Tracks individual subscription transactions
- **CreatorAnalytics**: Stores earnings and subscriber statistics

### Security Features

- Reentrancy protection using OpenZeppelin's ReentrancyGuard
- Input validation for all parameters
- Access control modifiers (onlyOwner, onlyCreator)
- Emergency pause functionality
- Safe token transfers using OpenZeppelin's SafeERC20

## Deployment

### Prerequisites

- Solidity ^0.8.20
- OpenZeppelin contracts ^4.8.0

### Constructor Parameters

```javascript
constructor(address _defaultTokenAddress)
```

- `_defaultTokenAddress`: Address of the default ERC20 token for payments

## Usage Guide

### For Creators

#### Add Subscription Plans:

```javascript
function updateCreatorPlan(
    uint256 tierIndex,
    uint256 fee,
    uint256 tokenFee,
    uint256 duration,
    string calldata metadata,
    string calldata benefits,
    bool active
)
```

#### Manage Plan Status:

```javascript
function togglePlanStatus(uint256 tierIndex)
```

### For Users

#### Subscribe with ETH:

```javascript
function subscribe(address creator, uint256 tierIndex) payable
```

#### Subscribe with Tokens:

```javascript
function subscribeWithToken(address creator, uint256 tierIndex, address token)
```

#### Manage Subscriptions:

```javascript
function enableAutoRenewal(address creator)
function disableAutoRenewal(address creator)
function suspendSubscription(address creator)
function reactivateSubscription(address creator)
```

### For Platform Owners

#### Manage Platform Settings:

```javascript
function updatePlatformFee(uint256 newFeePercent)
function addWhitelistedToken(address token)
function removeWhitelistedToken(address token)
function pause()
function unpause()
```

#### Withdraw Funds:

```javascript
function withdrawETH(uint256 amount)
function withdrawTokens(address token, uint256 amount)
```

## Fee Structure

- Platform fee: Configurable percentage (default 5%)
- Fees are automatically distributed during subscription payments
- Maximum platform fee limit: 10%

## Limits and Restrictions

- Subscription duration: 1-365 days
- Maximum tiers per creator: 10
- String length limits: metadata (256 chars), benefits (512 chars)

## Events

The contract emits comprehensive events for all major actions:

- **Subscription events**: `Subscribed`, `SubscribedWithToken`
- **Management events**: `AutoRenewalEnabled`, `SubscriptionSuspended`
- **Creator events**: `CreatorAdded`, `PlanUpdated`
- **Platform events**: `PlatformFeeUpdated`, `TokenWhitelisted`
- **Financial events**: `ETHWithdrawn`, `FeesDistributed`

## Security Considerations

1. Always verify contract addresses before interacting
2. Use only whitelisted tokens for payments
3. Check subscription status before attempting management operations
4. The contract owner has significant control - verify owner identity

## Emergency Procedures

- Contract can be paused by owner in case of vulnerabilities
- Emergency withdrawal function available for owner
- All funds are secure and can be recovered by owner if needed

## Testing

The contract includes comprehensive custom errors for all failure cases:

- `NotOwner()`, `NotCreator()` for access control
- `InsufficientPayment()`, `TokenNotSupported()` for payment issues
- `InvalidDuration()`, `TierLimitExceeded()` for parameter validation

### Running Tests

```bash
# Install dependencies
npm install

# Run tests
npx hardhat test

# Run with gas reporting
REPORT_GAS=true npx hardhat test

# Run coverage
npx hardhat coverage
```

## Development Setup

```bash
# Clone the repository
git clone https://github.com/yourusername/subscription-platform-smart-contract.git
cd subscription-platform-smart-contract

# Install dependencies
npm install

# Compile contracts
npx hardhat compile

# Deploy to local network
npx hardhat run scripts/deploy.js --network localhost

# Deploy to testnet (e.g., Sepolia)
npx hardhat run scripts/deploy.js --network sepolia
```

## Contract Architecture

```
SubscriptionPlatform
├── Creator Management
│   ├── Add/Remove Creators
│   └── Creator Analytics
├── Subscription Plans
│   ├── Multi-tier Support
│   └── Plan Management
├── Payment Processing
│   ├── ETH Payments
│   ├── Token Payments
│   └── Fee Distribution
├── Subscription Lifecycle
│   ├── Auto-renewal
│   ├── Suspension
│   └── Reactivation
└── Platform Administration
    ├── Fee Management
    ├── Token Whitelisting
    └── Emergency Controls
```

## Gas Optimizations

- Packed structs for efficient storage
- Batch operations where possible
- Optimized mapping usage
- Event-based logging for off-chain indexing

## Support

For issues related to this smart contract, please:

1. Check the existing [Issues](../../issues) on GitHub
2. Review the comprehensive test suite for usage examples
3. Create a new issue with detailed information about your problem

**Important**: Always test with small amounts first and verify contract functionality on testnets before mainnet usage.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request