// ===== test/SubscriptionPlatform.test.js =====
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("SubscriptionPlatform", function () {
    let subscriptionPlatform;
    let mockToken;
    let owner, creator, user1, user2, user3;

    const PLATFORM_FEE = 500; // 5%
    const GRACE_PERIOD = 7 * 24 * 60 * 60; // 7 days
    const SUBSCRIPTION_DURATION = 30 * 24 * 60 * 60; // 30 days
    const TIER_FEE = ethers.parseEther("0.1");
    const TOKEN_FEE = ethers.parseUnits("100", 18);

    beforeEach(async function () {
        [owner, creator, user1, user2, user3] = await ethers.getSigners();

        // Deploy mock ERC20 token
        const MockToken = await ethers.getContractFactory("MockERC20");
        mockToken = await MockToken.deploy("Test Token", "TEST", 18);
        await mockToken.waitForDeployment();

        // Deploy SubscriptionPlatform
        const SubscriptionPlatform = await ethers.getContractFactory("SubscriptionPlatform");
        subscriptionPlatform = await SubscriptionPlatform.deploy(await mockToken.getAddress());
        await subscriptionPlatform.waitForDeployment();

        // Setup initial state
        await subscriptionPlatform.addCreator(creator.address);
        
        // Mint tokens to users
        await mockToken.mint(user1.address, ethers.parseUnits("1000", 18));
        await mockToken.mint(user2.address, ethers.parseUnits("1000", 18));
    });

    describe("Deployment", function () {
        it("Should set the right owner", async function () {
            expect(await subscriptionPlatform.owner()).to.equal(owner.address);
        });

        it("Should set the default payment token", async function () {
            expect(await subscriptionPlatform.defaultPaymentToken()).to.equal(await mockToken.getAddress());
        });

        it("Should whitelist the default token", async function () {
            expect(await subscriptionPlatform.whitelistedTokens(await mockToken.getAddress())).to.be.true;
        });

        it("Should add owner as creator", async function () {
            expect(await subscriptionPlatform.creators(owner.address)).to.be.true;
        });
    });

    describe("Creator Management", function () {
        it("Should add a new creator", async function () {
            await expect(subscriptionPlatform.addCreator(user1.address))
                .to.emit(subscriptionPlatform, "CreatorAdded")
                .withArgs(user1.address);
            
            expect(await subscriptionPlatform.creators(user1.address)).to.be.true;
        });

        it("Should remove a creator", async function () {
            await expect(subscriptionPlatform.removeCreator(creator.address))
                .to.emit(subscriptionPlatform, "CreatorRemoved")
                .withArgs(creator.address);
            
            expect(await subscriptionPlatform.creators(creator.address)).to.be.false;
        });

        it("Should revert when non-owner tries to add creator", async function () {
            await expect(subscriptionPlatform.connect(user1).addCreator(user2.address))
                .to.be.revertedWithCustomError(subscriptionPlatform, "NotOwner");
        });
    });

    describe("Subscription Plans", function () {
        beforeEach(async function () {
            // Create a subscription tier
            await subscriptionPlatform.connect(creator).updateCreatorPlan(
                0, // tierIndex
                TIER_FEE,
                TOKEN_FEE,
                SUBSCRIPTION_DURATION,
                "Basic Plan",
                "Access to basic content",
                true // active
            );
        });

        it("Should create a new subscription plan", async function () {
            await expect(subscriptionPlatform.connect(creator).updateCreatorPlan(
                1, // new tier
                ethers.parseEther("0.2"),
                ethers.parseUnits("200", 18),
                SUBSCRIPTION_DURATION * 2,
                "Premium Plan",
                "Access to premium content",
                true
            )).to.emit(subscriptionPlatform, "PlanUpdated");

            expect(await subscriptionPlatform.getCreatorTiersCount(creator.address)).to.equal(2);
        });

        it("Should update existing plan", async function () {
            const newFee = ethers.parseEther("0.15");
            await subscriptionPlatform.connect(creator).updateCreatorPlan(
                0, // existing tier
                newFee,
                TOKEN_FEE,
                SUBSCRIPTION_DURATION,
                "Updated Basic Plan",
                "Updated benefits",
                true
            );

            const plan = await subscriptionPlatform.getCreatorTier(creator.address, 0);
            expect(plan.fee).to.equal(newFee);
            expect(plan.metadata).to.equal("Updated Basic Plan");
        });

        it("Should toggle plan status", async function () {
            await subscriptionPlatform.connect(creator).togglePlanStatus(0);
            const plan = await subscriptionPlatform.getCreatorTier(creator.address, 0);
            expect(plan.active).to.be.false;
        });

        it("Should revert when non-creator tries to update plan", async function () {
            await expect(subscriptionPlatform.connect(user1).updateCreatorPlan(
                0, TIER_FEE, TOKEN_FEE, SUBSCRIPTION_DURATION, "Hack", "Hack", true
            )).to.be.revertedWithCustomError(subscriptionPlatform, "NotCreator");
        });
    });

    describe("ETH Subscriptions", function () {
        beforeEach(async function () {
            await subscriptionPlatform.connect(creator).updateCreatorPlan(
                0, TIER_FEE, TOKEN_FEE, SUBSCRIPTION_DURATION, "Basic Plan", "Access to basic content", true
            );
        });

        it("Should allow ETH subscription", async function () {
            await expect(subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: TIER_FEE }))
                .to.emit(subscriptionPlatform, "Subscribed")
                .withArgs(user1.address, creator.address, await time.latest() + SUBSCRIPTION_DURATION + 1);

            expect(await subscriptionPlatform.isSubscriptionActive(creator.address, user1.address)).to.be.true;
        });

        it("Should refund excess ETH", async function () {
            const excessAmount = ethers.parseEther("0.05");
            const totalSent = TIER_FEE + excessAmount;

            const initialBalance = await ethers.provider.getBalance(user1.address);
            
            const tx = await subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: totalSent });
            const receipt = await tx.wait();
            const gasUsed = receipt.gasUsed * receipt.gasPrice;

            const finalBalance = await ethers.provider.getBalance(user1.address);
            
            // User should only pay the tier fee + gas, excess should be refunded
            expect(finalBalance).to.be.closeTo(
                initialBalance - TIER_FEE - gasUsed, 
                ethers.parseEther("0.001") // Small tolerance for gas estimation differences
            );
        });

        it("Should update creator analytics", async function () {
            await subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: TIER_FEE });
            
            const analytics = await subscriptionPlatform.getCreatorAnalytics(creator.address);
            expect(analytics.totalEarningsETH).to.equal(TIER_FEE);
            expect(analytics.activeSubscribers).to.equal(1);
            expect(analytics.totalSubscribers).to.equal(1);
        });

        it("Should revert for insufficient payment", async function () {
            const insufficientAmount = TIER_FEE - ethers.parseEther("0.01");
            
            await expect(subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: insufficientAmount }))
                .to.be.revertedWithCustomError(subscriptionPlatform, "InsufficientPayment");
        });

        it("Should revert for invalid creator", async function () {
            await expect(subscriptionPlatform.connect(user1).subscribe(user2.address, 0, { value: TIER_FEE }))
                .to.be.revertedWithCustomError(subscriptionPlatform, "InvalidCreator");
        });

        it("Should revert for invalid tier index", async function () {
            await expect(subscriptionPlatform.connect(user1).subscribe(creator.address, 999, { value: TIER_FEE }))
                .to.be.revertedWithCustomError(subscriptionPlatform, "InvalidTierIndex");
        });
    });

    describe("Token Subscriptions", function () {
        beforeEach(async function () {
            await subscriptionPlatform.connect(creator).updateCreatorPlan(
                0, TIER_FEE, TOKEN_FEE, SUBSCRIPTION_DURATION, "Basic Plan", "Access to basic content", true
            );
            
            // Approve tokens
            await mockToken.connect(user1).approve(await subscriptionPlatform.getAddress(), TOKEN_FEE);
        });

        it("Should allow token subscription", async function () {
            await expect(subscriptionPlatform.connect(user1).subscribeWithToken(
                creator.address, 0, await mockToken.getAddress(), TOKEN_FEE
            )).to.emit(subscriptionPlatform, "SubscribedWithToken");

            expect(await subscriptionPlatform.isSubscriptionActive(creator.address, user1.address)).to.be.true;
        });

        it("Should update token earnings", async function () {
            await subscriptionPlatform.connect(user1).subscribeWithToken(
                creator.address, 0, await mockToken.getAddress(), TOKEN_FEE
            );
            
            const analytics = await subscriptionPlatform.getCreatorAnalytics(creator.address);
            expect(analytics.totalEarningsTokens).to.equal(TOKEN_FEE);
        });

        it("Should revert for non-whitelisted token", async function () {
            const MockToken2 = await ethers.getContractFactory("MockERC20");
            const mockToken2 = await MockToken2.deploy("Test Token 2", "TEST2", 18);
            
            await expect(subscriptionPlatform.connect(user1).subscribeWithToken(
                creator.address, 0, await mockToken2.getAddress(), TOKEN_FEE
            )).to.be.revertedWithCustomError(subscriptionPlatform, "TokenNotSupported");
        });
    });

    describe("Subscription Management", function () {
        beforeEach(async function () {
            await subscriptionPlatform.connect(creator).updateCreatorPlan(
                0, TIER_FEE, TOKEN_FEE, SUBSCRIPTION_DURATION, "Basic Plan", "Access to basic content", true
            );
            
            // User subscribes
            await subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: TIER_FEE });
        });

        it("Should enable auto-renewal", async function () {
            await expect(subscriptionPlatform.connect(user1).enableAutoRenewal(creator.address))
                .to.emit(subscriptionPlatform, "AutoRenewalEnabled")
                .withArgs(creator.address, user1.address);
            
            expect(await subscriptionPlatform.autoRenewal(creator.address, user1.address)).to.be.true;
        });

        it("Should disable auto-renewal", async function () {
            await subscriptionPlatform.connect(user1).enableAutoRenewal(creator.address);
            
            await expect(subscriptionPlatform.connect(user1).disableAutoRenewal(creator.address))
                .to.emit(subscriptionPlatform, "AutoRenewalDisabled")
                .withArgs(creator.address, user1.address);
            
            expect(await subscriptionPlatform.autoRenewal(creator.address, user1.address)).to.be.false;
        });

        it("Should suspend active subscription", async function () {
            await expect(subscriptionPlatform.connect(user1).suspendSubscription(creator.address))
                .to.emit(subscriptionPlatform, "SubscriptionSuspended");
            
            expect(await subscriptionPlatform.isSubscriptionActive(creator.address, user1.address)).to.be.false;
            expect(await subscriptionPlatform.suspendedSubscriptions(creator.address, user1.address)).to.be.gt(0);
        });

        it("Should reactivate suspended subscription", async function () {
            await subscriptionPlatform.connect(user1).suspendSubscription(creator.address);
            
            await expect(subscriptionPlatform.connect(user1).reactivateSubscription(creator.address))
                .to.emit(subscriptionPlatform, "SubscriptionReactivated");
            
            expect(await subscriptionPlatform.isSubscriptionActive(creator.address, user1.address)).to.be.true;
            expect(await subscriptionPlatform.suspendedSubscriptions(creator.address, user1.address)).to.equal(0);
        });
    });

    describe("Platform Administration", function () {
        it("Should add whitelisted token", async function () {
            const MockToken2 = await ethers.getContractFactory("MockERC20");
            const mockToken2 = await MockToken2.deploy("Test Token 2", "TEST2", 18);
            
            await expect(subscriptionPlatform.addWhitelistedToken(await mockToken2.getAddress()))
                .to.emit(subscriptionPlatform, "TokenWhitelisted");
            
            expect(await subscriptionPlatform.whitelistedTokens(await mockToken2.getAddress())).to.be.true;
        });

        it("Should remove whitelisted token", async function () {
            await expect(subscriptionPlatform.removeWhitelistedToken(await mockToken.getAddress()))
                .to.emit(subscriptionPlatform, "TokenRemovedFromWhitelist");
            
            expect(await subscriptionPlatform.whitelistedTokens(await mockToken.getAddress())).to.be.false;
        });

        it("Should update platform fee", async function () {
            const newFee = 750; // 7.5%
            
            await expect(subscriptionPlatform.updatePlatformFee(newFee))
                .to.emit(subscriptionPlatform, "PlatformFeeUpdated")
                .withArgs(PLATFORM_FEE, newFee);
            
            expect(await subscriptionPlatform.platformFeePercent()).to.equal(newFee);
        });

        it("Should revert for excessive platform fee", async function () {
            await expect(subscriptionPlatform.updatePlatformFee(1500)) // 15%
                .to.be.revertedWith("Fee too high");
        });

        it("Should pause and unpause contract", async function () {
            await expect(subscriptionPlatform.pause())
                .to.emit(subscriptionPlatform, "Paused");
            
            expect(await subscriptionPlatform.paused()).to.be.true;
            
            await expect(subscriptionPlatform.unpause())
                .to.emit(subscriptionPlatform, "Unpaused");
            
            expect(await subscriptionPlatform.paused()).to.be.false;
        });
    });

    describe("Withdrawal Functions", function () {
        beforeEach(async function () {
            // Setup subscription plan and subscribe to generate funds
            await subscriptionPlatform.connect(creator).updateCreatorPlan(
                0, TIER_FEE, TOKEN_FEE, SUBSCRIPTION_DURATION, "Basic Plan", "Access to basic content", true
            );
            
            await subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: TIER_FEE });
            
            // Add tokens to contract
            await mockToken.connect(user1).approve(await subscriptionPlatform.getAddress(), TOKEN_FEE);
            await subscriptionPlatform.connect(user1).subscribeWithToken(
                creator.address, 0, await mockToken.getAddress(), TOKEN_FEE
            );
        });

        it("Should withdraw ETH", async function () {
            const contractBalance = await ethers.provider.getBalance(await subscriptionPlatform.getAddress());
            const initialOwnerBalance = await ethers.provider.getBalance(owner.address);
            
            await expect(subscriptionPlatform.withdrawETH(contractBalance))
                .to.emit(subscriptionPlatform, "ETHWithdrawn")
                .withArgs(owner.address, contractBalance);
        });

        it("Should withdraw tokens", async function () {
            const tokenBalance = await mockToken.balanceOf(await subscriptionPlatform.getAddress());
            
            await expect(subscriptionPlatform.withdrawTokens(await mockToken.getAddress(), tokenBalance))
                .to.emit(subscriptionPlatform, "TokensWithdrawn")
                .withArgs(await mockToken.getAddress(), owner.address, tokenBalance);
        });

        it("Should emergency withdraw all", async function () {
            await subscriptionPlatform.emergencyWithdrawAll();
            
            expect(await ethers.provider.getBalance(await subscriptionPlatform.getAddress())).to.equal(0);
        });

        it("Should revert when non-owner tries to withdraw", async function () {
            await expect(subscriptionPlatform.connect(user1).withdrawETH(ethers.parseEther("0.01")))
                .to.be.revertedWithCustomError(subscriptionPlatform, "NotOwner");
        });
    });

    describe("Subscription Expiry and Renewal", function () {
        beforeEach(async function () {
            await subscriptionPlatform.connect(creator).updateCreatorPlan(
                0, TIER_FEE, TOKEN_FEE, SUBSCRIPTION_DURATION, "Basic Plan", "Access to basic content", true
            );
        });

        it("Should extend existing subscription", async function () {
            // First subscription
            await subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: TIER_FEE });
            const firstExpiry = await subscriptionPlatform.getSubscriptionExpiry(creator.address, user1.address);
            
            // Advance time but not past expiry
            await time.increase(SUBSCRIPTION_DURATION / 2);
            
            // Second subscription should extend from current expiry
            await subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: TIER_FEE });
            const secondExpiry = await subscriptionPlatform.getSubscriptionExpiry(creator.address, user1.address);
            
            expect(secondExpiry).to.be.gt(firstExpiry);
            expect(secondExpiry - firstExpiry).to.equal(SUBSCRIPTION_DURATION);
        });

        it("Should start new subscription after expiry", async function () {
            // Subscribe
            await subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: TIER_FEE });
            
            // Fast forward past expiry
            await time.increase(SUBSCRIPTION_DURATION + 1);
            
            // Subscribe again - should start from current time
            const currentTime = await time.latest();
            await subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: TIER_FEE });
            
            const newExpiry = await subscriptionPlatform.getSubscriptionExpiry(creator.address, user1.address);
            expect(newExpiry).to.be.closeTo(currentTime + SUBSCRIPTION_DURATION + 1, 2);
        });
    });

    describe("Edge Cases", function () {
        it("Should handle zero address validation", async function () {
            await expect(subscriptionPlatform.addCreator(ethers.ZeroAddress))
                .to.be.revertedWithCustomError(subscriptionPlatform, "InvalidAddress");
        });

        it("Should handle paused state", async function () {
            await subscriptionPlatform.pause();
            
            await subscriptionPlatform.connect(creator).updateCreatorPlan(
                0, TIER_FEE, TOKEN_FEE, SUBSCRIPTION_DURATION, "Basic Plan", "Access to basic content", true
            );
            
            await expect(subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: TIER_FEE }))
                .to.be.revertedWithCustomError(subscriptionPlatform, "ContractPaused");
        });

        it("Should handle inactive plans", async function () {
            await subscriptionPlatform.connect(creator).updateCreatorPlan(
                0, TIER_FEE, TOKEN_FEE, SUBSCRIPTION_DURATION, "Basic Plan", "Access to basic content", false // inactive
            );
            
            await expect(subscriptionPlatform.connect(user1).subscribe(creator.address, 0, { value: TIER_FEE }))
                .to.be.revertedWithCustomError(subscriptionPlatform, "InvalidTierIndex");
        });
    });
});

// ===== Mock ERC20 Contract for Testing =====
// contracts/mocks/MockERC20.sol

/*
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
*/