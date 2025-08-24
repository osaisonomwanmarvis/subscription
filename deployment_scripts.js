// ===== scripts/deploy.js =====
const { ethers, upgrades } = require("hardhat");

async function main() {
    const [deployer, admin, treasury] = await ethers.getSigners();

    console.log("Deploying contracts with the account:", deployer.address);
    console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

    // Deploy Mock ERC20 Token for testing
    const MockToken = await ethers.getContractFactory("MockERC20");
    const mockToken = await MockToken.deploy("Platform Token", "PLT", 18);
    await mockToken.waitForDeployment();
    console.log("Mock Token deployed to:", await mockToken.getAddress());

    // Deploy the upgradeable subscription platform
    const SubscriptionPlatform = await ethers.getContractFactory("SubscriptionPlatformUpgradeable");
    
    const subscriptionPlatform = await upgrades.deployProxy(
        SubscriptionPlatform,
        [
            await mockToken.getAddress(), // default payment token
            admin.address,                // admin address
            treasury.address,            // treasury address
            500                          // 5% platform fee
        ],
        {
            initializer: 'initialize',
            kind: 'uups'
        }
    );
    
    await subscriptionPlatform.waitForDeployment();
    console.log("SubscriptionPlatform deployed to:", await subscriptionPlatform.getAddress());

    // Deploy Auto Renewal Manager
    const AutoRenewalManager = await ethers.getContractFactory("AutoRenewalManager");
    const autoRenewalManager = await AutoRenewalManager.deploy(
        await subscriptionPlatform.getAddress()
    );
    await autoRenewalManager.waitForDeployment();
    console.log("AutoRenewalManager deployed to:", await autoRenewalManager.getAddress());

    // Deploy Chainlink Automation Upkeep
    const SubscriptionAutomationUpkeep = await ethers.getContractFactory("SubscriptionAutomationUpkeep");
    const automationUpkeep = await SubscriptionAutomationUpkeep.deploy(
        await subscriptionPlatform.getAddress(),
        await autoRenewalManager.getAddress()
    );
    await automationUpkeep.waitForDeployment();
    console.log("SubscriptionAutomationUpkeep deployed to:", await automationUpkeep.getAddress());

    // Setup initial configuration
    console.log("\nSetting up initial configuration...");

    // Add some initial creators for testing
    const creatorAddresses = [admin.address, treasury.address];
    for (const creator of creatorAddresses) {
        if (creator !== admin.address) { // admin is already a creator
            await subscriptionPlatform.connect(admin).addCreator(creator);
            console.log(`Added creator: ${creator}`);
        }
    }

    // Add additional whitelisted tokens
    await subscriptionPlatform.connect(admin).addWhitelistedToken(await mockToken.getAddress());
    console.log("Whitelisted mock token");

    // Create sample subscription plans
    await subscriptionPlatform.connect(admin).createSubscriptionPlan(
        ethers.parseEther("0.25"),    // 0.25 ETH
        ethers.parseUnits("250", 18), // 250 tokens
        90 * 24 * 60 * 60,           // 90 days
        "Premium Plan",
        "Access to premium content and exclusive features",
        500                          // max 500 subscribers
    );
    console.log("Created premium subscription plan");

    // Mint some tokens to deployer for testing
    await mockToken.mint(deployer.address, ethers.parseUnits("10000", 18));
    console.log("Minted 10000 tokens to deployer");

    // Save deployment addresses
    const deploymentInfo = {
        network: hre.network.name,
        mockToken: await mockToken.getAddress(),
        subscriptionPlatform: await subscriptionPlatform.getAddress(),
        autoRenewalManager: await autoRenewalManager.getAddress(),
        automationUpkeep: await automationUpkeep.getAddress(),
        deployer: deployer.address,
        admin: admin.address,
        treasury: treasury.address,
        deploymentBlock: await ethers.provider.getBlockNumber(),
        timestamp: new Date().toISOString()
    };

    console.log("\n=== Deployment Summary ===");
    console.log(deploymentInfo);

    // Save to file
    const fs = require('fs');
    fs.writeFileSync(
        `./deployments/${hre.network.name}-deployment.json`,
        JSON.stringify(deploymentInfo, null, 2)
    );

    // Verify contracts on Etherscan (if not local network)
    if (hre.network.name !== "hardhat" && hre.network.name !== "localhost") {
        console.log("\nWaiting before verification...");
        await new Promise(resolve => setTimeout(resolve, 30000)); // Wait 30 seconds

        try {
            await hre.run("verify:verify", {
                address: await mockToken.getAddress(),
                constructorArguments: ["Platform Token", "PLT", 18]
            });
            console.log("MockERC20 verified");
        } catch (error) {
            console.log("MockERC20 verification failed:", error.message);
        }

        try {
            await hre.run("verify:verify", {
                address: await autoRenewalManager.getAddress(),
                constructorArguments: [await subscriptionPlatform.getAddress()]
            });
            console.log("AutoRenewalManager verified");
        } catch (error) {
            console.log("AutoRenewalManager verification failed:", error.message);
        }

        try {
            await hre.run("verify:verify", {
                address: await automationUpkeep.getAddress(),
                constructorArguments: [
                    await subscriptionPlatform.getAddress(),
                    await autoRenewalManager.getAddress()
                ]
            });
            console.log("SubscriptionAutomationUpkeep verified");
        } catch (error) {
            console.log("SubscriptionAutomationUpkeep verification failed:", error.message);
        }
    }

    console.log("\nDeployment completed successfully!");
    return deploymentInfo;
}

// ===== scripts/upgrade.js =====
async function upgradeContract() {
    const [deployer, admin] = await ethers.getSigners();
    
    console.log("Upgrading contract with account:", admin.address);

    // Get the current proxy address (replace with actual address)
    const PROXY_ADDRESS = process.env.SUBSCRIPTION_PLATFORM_ADDRESS;
    
    if (!PROXY_ADDRESS) {
        throw new Error("SUBSCRIPTION_PLATFORM_ADDRESS environment variable not set");
    }

    // Deploy the new implementation
    const SubscriptionPlatformV2 = await ethers.getContractFactory("SubscriptionPlatformUpgradeable");
    
    console.log("Upgrading SubscriptionPlatform...");
    const upgraded = await upgrades.upgradeProxy(PROXY_ADDRESS, SubscriptionPlatformV2);
    
    console.log("SubscriptionPlatform upgraded successfully");
    console.log("Proxy address:", await upgraded.getAddress());
    
    // Verify the upgrade worked
    const currentVersion = await upgraded.getProtocolVersion();
    console.log("New protocol version:", currentVersion.toString());
    
    return upgraded;
}

// ===== scripts/setup-local-testing.js =====
async function setupLocalTesting() {
    const [deployer, admin, treasury, creator1, creator2, user1, user2] = await ethers.getSigners();
    
    // Load deployment info
    const fs = require('fs');
    const deploymentInfo = JSON.parse(
        fs.readFileSync('./deployments/localhost-deployment.json', 'utf8')
    );
    
    // Get contract instances
    const mockToken = await ethers.getContractAt("MockERC20", deploymentInfo.mockToken);
    const subscriptionPlatform = await ethers.getContractAt(
        "SubscriptionPlatformUpgradeable",
        deploymentInfo.subscriptionPlatform
    );
    const autoRenewalManager = await ethers.getContractAt(
        "AutoRenewalManager",
        deploymentInfo.autoRenewalManager
    );
    
    console.log("Setting up local testing environment...");
    
    // Add more creators
    await subscriptionPlatform.connect(admin).addCreator(creator1.address);
    await subscriptionPlatform.connect(admin).addCreator(creator2.address);
    console.log("Added additional creators");
    
    // Mint tokens to users
    const userAddresses = [user1.address, user2.address, creator1.address, creator2.address];
    for (const userAddress of userAddresses) {
        await mockToken.mint(userAddress, ethers.parseUnits("1000", 18));
    }
    console.log("Minted tokens to users");
    
    // Creator1 creates subscription plans
    await subscriptionPlatform.connect(creator1).createSubscriptionPlan(
        ethers.parseEther("0.05"),    // 0.05 ETH
        ethers.parseUnits("50", 18),  // 50 tokens
        7 * 24 * 60 * 60,            // 7 days
        "Weekly Plan",
        "Short-term access for testing",
        100                          // max 100 subscribers
    );
    
    await subscriptionPlatform.connect(creator1).createSubscriptionPlan(
        ethers.parseEther("0.15"),    // 0.15 ETH
        ethers.parseUnits("150", 18), // 150 tokens
        365 * 24 * 60 * 60,          // 365 days
        "Yearly Plan",
        "Long-term subscription with best value",
        50                           // max 50 subscribers
    );
    console.log("Creator1 created subscription plans");
    
    // Creator2 creates subscription plans
    await subscriptionPlatform.connect(creator2).createSubscriptionPlan(
        ethers.parseEther("0.08"),    // 0.08 ETH
        ethers.parseUnits("80", 18),  // 80 tokens
        14 * 24 * 60 * 60,           // 14 days
        "Bi-weekly Plan",
        "Two week access period",
        75                           // max 75 subscribers
    );
    console.log("Creator2 created subscription plans");
    
    // Set up some test subscriptions
    await subscriptionPlatform.connect(user1).subscribe(creator1.address, 0, {
        value: ethers.parseEther("0.05")
    });
    console.log("User1 subscribed to Creator1's weekly plan");
    
    // Approve and subscribe with tokens
    await mockToken.connect(user2).approve(subscriptionPlatform.getAddress(), ethers.parseUnits("80", 18));
    await subscriptionPlatform.connect(user2).subscribeWithToken(
        creator2.address,
        0,
        mockToken.getAddress(),
        ethers.parseUnits("80", 18)
    );
    console.log("User2 subscribed to Creator2's plan with tokens");
    
    // Set up auto-renewal authorization
    await autoRenewalManager.connect(user1).authorizePayment(
        creator1.address,
        ethers.parseEther("0.1"),     // max amount per renewal
        ethers.parseEther("1.0"),     // max total amount
        ethers.ZeroAddress,           // ETH payment
        30 * 24 * 60 * 60            // 30 days validity
    );
    console.log("User1 authorized auto-renewal payments");
    
    console.log("\nLocal testing environment setup complete!");
    console.log("You can now test subscriptions, renewals, and other features.");
    
    return {
        contracts: {
            mockToken,
            subscriptionPlatform,
            autoRenewalManager
        },
        accounts: {
            deployer,
            admin,
            treasury,
            creator1,
            creator2,
            user1,
            user2
        }
    };
}

// ===== hardhat.config.js =====
require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("dotenv").config();

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x" + "0".repeat(64);
const INFURA_API_KEY = process.env.INFURA_API_KEY;
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY;

module.exports = {
    solidity: {
        version: "0.8.20",
        settings: {
            optimizer: {
                enabled: true,
                runs: 200,
            },
            viaIR: true, // Enable for better optimization with large contracts
        },
    },
    networks: {
        hardhat: {
            chainId: 31337,
            accounts: {
                count: 20,
                accountsBalance: "10000000000000000000000", // 10000 ETH
            },
        },
        localhost: {
            url: "http://127.0.0.1:8545",
            chainId: 31337,
        },
        sepolia: {
            url: `https://sepolia.infura.io/v3/${INFURA_API_KEY}`,
            accounts: [PRIVATE_KEY],
            chainId: 11155111,
        },
        mainnet: {
            url: `https://mainnet.infura.io/v3/${INFURA_API_KEY}`,
            accounts: [PRIVATE_KEY],
            chainId: 1,
            gasPrice: 20000000000, // 20 gwei
        },
        polygon: {
            url: "https://polygon-rpc.com/",
            accounts: [PRIVATE_KEY],
            chainId: 137,
        },
        arbitrum: {
            url: "https://arb1.arbitrum.io/rpc",
            accounts: [PRIVATE_KEY],
            chainId: 42161,
        },
    },
    etherscan: {
        apiKey: {
            mainnet: ETHERSCAN_API_KEY,
            sepolia: ETHERSCAN_API_KEY,
            polygon: process.env.POLYGONSCAN_API_KEY,
            arbitrumOne: process.env.ARBISCAN_API_KEY,
        },
    },
    gasReporter: {
        enabled: process.env.REPORT_GAS !== undefined,
        currency: "USD",
        coinmarketcap: process.env.COINMARKETCAP_API_KEY,
    },
    paths: {
        sources: "./contracts",
        tests: "./test",
        cache: "./cache",
        artifacts: "./artifacts",
    },
    mocha: {
        timeout: 40000,
    },
};

// ===== package.json Scripts Section =====
/*
{
  "scripts": {
    "compile": "hardhat compile",
    "test": "hardhat test",
    "test:gas": "REPORT_GAS=true hardhat test",
    "deploy:localhost": "hardhat run scripts/deploy.js --network localhost",
    "deploy:sepolia": "hardhat run scripts/deploy.js --network sepolia",
    "deploy:mainnet": "hardhat run scripts/deploy.js --network mainnet",
    "upgrade:localhost": "hardhat run scripts/upgrade.js --network localhost",
    "upgrade:sepolia": "hardhat run scripts/upgrade.js --network sepolia",
    "setup:local": "hardhat run scripts/setup-local-testing.js --network localhost",
    "verify:sepolia": "hardhat verify --network sepolia",
    "node": "hardhat node",
    "console:localhost": "hardhat console --network localhost",
    "size": "hardhat size-contracts",
    "coverage": "hardhat coverage"
  },
  "dependencies": {
    "@openzeppelin/contracts": "^5.0.0",
    "@openzeppelin/contracts-upgradeable": "^5.0.0",
    "@openzeppelin/hardhat-upgrades": "^3.0.0"
  },
  "devDependencies": {
    "@nomicfoundation/hardhat-toolbox": "^4.0.0",
    "@nomicfoundation/hardhat-network-helpers": "^1.0.0",
    "hardhat": "^2.19.0",
    "hardhat-gas-reporter": "^1.0.8",
    "solidity-coverage": "^0.8.1",
    "dotenv": "^16.3.0"
  }
}
*/

// ===== .env.example =====
/*
# Private key for deployment (without 0x prefix)
PRIVATE_KEY=your_private_key_here

# API Keys
INFURA_API_KEY=your_infura_api_key
ETHERSCAN_API_KEY=your_etherscan_api_key
POLYGONSCAN_API_KEY=your_polygonscan_api_key
ARBISCAN_API_KEY=your_arbiscan_api_key
COINMARKETCAP_API_KEY=your_coinmarketcap_api_key

# Contract Addresses (filled after deployment)
SUBSCRIPTION_PLATFORM_ADDRESS=
AUTO_RENEWAL_MANAGER_ADDRESS=
MOCK_TOKEN_ADDRESS=

# Gas Settings
REPORT_GAS=true
*/

if (require.main === module) {
    main()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error(error);
            process.exit(1);
        });
}

module.exports = {
    main,
    upgradeContract,
    setupLocalTesting
};(
        ethers.parseEther("0.1"),     // 0.1 ETH
        ethers.parseUnits("100", 18), // 100 tokens
        30 * 24 * 60 * 60,           // 30 days
        "Basic Plan",
        "Access to basic content",
        1000                         // max 1000 subscribers
    );
    console.log("Created basic subscription plan");

    await subscriptionPlatform.connect(admin).createSubscriptionPlan