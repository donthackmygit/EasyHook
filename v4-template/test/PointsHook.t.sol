// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {PointsHook} from "../src/PointsHook.sol";
import {PointsToken} from "../src/PointsToken.sol";

import {BaseTest} from "./utils/BaseTest.sol";

contract PointsHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    PointsHook hook;
    PointsToken pointsToken;
    PoolId poolId;
    PoolKey key;

    Currency currency1;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        deployArtifactsAndLabel();

        (, currency1) = deployCurrencyPair();

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG) ^
                (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("PointsHook.sol:PointsHook", constructorArgs, flags);
        hook = PointsHook(flags);
        pointsToken = hook.pointsToken();

        // Create the pool
        key = PoolKey(
            Currency.wrap(address(0)),
            currency1,
            3000,
            60,
            IHooks(hook)
        );
        poolId = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        deal(address(this), 200 ether);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                Constants.SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                uint128(100e18)
            );

        (tokenId, ) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            100e18,
            amount0 + 1,
            amount1 + 1,
            address(this),
            block.timestamp + 1,
            hook.getHookData(address(this))
        );
    }

    function test_PointsHook_Swap() public {
        uint256 amountIn = 1e18;

        vm.warp(block.timestamp + 1 days);

        (uint256 expectedPoints, , , ) = hook.previewPoints(address(this), amountIn, false);

        uint256 awardedPoints = _swapEthForToken(address(this), address(0), amountIn);

        assertEq(awardedPoints, expectedPoints, "Points awarded for swap should match preview");
    }

    function test_PointsHook_AddLiquidityTracksStats() public {
        (
            uint256 lifetimeVolume,
            uint256 totalRewards,
            ,
            uint256 liquidityEventCount,
            ,
            uint256 claimedToday
        ) = _activity(address(this));
        (
            uint256 swapVolume,
            uint256 liquidityVolume,
            uint256 rewardsMinted,
            uint256 swapCount,
            uint256 poolLiquidityEventCount
        ) = hook.poolStats(poolId);

        assertGt(lifetimeVolume, 0, "Initial liquidity should count as user volume");
        assertEq(totalRewards, pointsToken.balanceOf(address(this)), "User rewards should track token balance");
        assertEq(liquidityEventCount, 1, "Setup should create one liquidity event");
        assertEq(claimedToday, totalRewards, "Initial reward should be claimed today");

        assertEq(swapVolume, 0, "No swaps happened yet");
        assertGt(liquidityVolume, 0, "Pool should track ETH added as liquidity");
        assertEq(rewardsMinted, totalRewards, "Pool minted rewards should match setup rewards");
        assertEq(swapCount, 0, "No pool swaps happened yet");
        assertEq(poolLiquidityEventCount, 1, "Pool should track one liquidity event");
    }

    function test_PointsHook_ReferralBonus() public {
        address trader = address(0xA11CE);
        address referrer = address(0xB0B);
        uint256 amountIn = 1e18;
        (, , uint256 startingRewardsMinted, , ) = hook.poolStats(poolId);

        (uint256 expectedPoints, , , ) = hook.previewPoints(trader, amountIn, false);
        uint256 expectedReferralPoints = (expectedPoints * hook.REFERRAL_BONUS_BPS()) / hook.BPS();

        uint256 awardedPoints = _swapEthForToken(trader, referrer, amountIn);
        (, , uint256 endingRewardsMinted, , ) = hook.poolStats(poolId);
        (uint256 lifetimeVolume, uint256 totalRewards, uint256 swapCount, , , ) = _activity(trader);

        assertEq(awardedPoints, expectedPoints, "Trader should receive previewed points");
        assertEq(pointsToken.balanceOf(referrer), expectedReferralPoints, "Referrer should receive referral points");
        assertEq(lifetimeVolume, amountIn, "Trader volume should be tracked");
        assertEq(totalRewards, expectedPoints, "Trader rewards should be tracked");
        assertEq(swapCount, 1, "Trader swap count should increase");
        assertEq(hook.userPoolVolume(poolId, trader), amountIn, "Pool-user volume should be tracked");
        assertEq(
            endingRewardsMinted - startingRewardsMinted,
            expectedPoints + expectedReferralPoints,
            "Pool should track user and referral rewards"
        );
    }

    function test_PointsHook_StreakBonusIncreasesAfterConsecutiveDay() public {
        address trader = address(0xCAFE);
        uint256 amountIn = 1e18;

        assertEq(_swapEthForToken(trader, address(0), amountIn), amountIn, "First day should have no streak bonus");

        vm.warp(block.timestamp + 1 days);

        (uint256 expectedPoints, uint256 multiplierBps, , uint256 streakDays) = hook.previewPoints(
            trader,
            amountIn,
            false
        );

        assertEq(streakDays, 2, "Second consecutive day should produce a two-day streak");
        assertEq(multiplierBps, hook.BPS() + hook.STREAK_BONUS_PER_DAY_BPS(), "Streak should add 5%");
        assertEq(_swapEthForToken(trader, address(0), amountIn), expectedPoints, "Second day should earn streak bonus");

        (, , , , uint256 storedStreakDays, ) = _activity(trader);
        assertEq(storedStreakDays, 2, "Streak should be stored");
    }

    function test_PointsHook_TierBonusAfterVolumeThreshold() public {
        address trader = address(0xC0DE);
        uint256 amountIn = 1e18;

        _swapEthForToken(trader, address(0), hook.SILVER_VOLUME());

        assertEq(uint256(hook.getTier(trader)), uint256(PointsHook.Tier.Silver), "Trader should reach Silver tier");

        (uint256 expectedPoints, uint256 multiplierBps, PointsHook.Tier tier, ) = hook.previewPoints(
            trader,
            amountIn,
            false
        );

        assertEq(uint256(tier), uint256(PointsHook.Tier.Silver), "Preview should use Silver tier");
        assertEq(multiplierBps, hook.BPS() + hook.SILVER_BONUS_BPS(), "Silver tier should add 10%");
        assertEq(_swapEthForToken(trader, address(0), amountIn), expectedPoints, "Silver tier should boost rewards");
    }

    function test_PointsHook_DailyCapLimitsLargeReward() public {
        address trader = address(0xDAD);
        uint256 amountIn = 101 ether;

        deal(address(this), 1000 ether);

        uint256 awardedPoints = _swapEthForToken(trader, address(0), amountIn);
        (, , , , , uint256 claimedToday) = _activity(trader);

        assertEq(awardedPoints, hook.DAILY_REWARD_CAP(), "Daily cap should limit large rewards");
        assertEq(claimedToday, hook.DAILY_REWARD_CAP(), "Claimed today should stop at the cap");
    }

    function _swapEthForToken(
        address user,
        address referrer,
        uint256 amountIn
    ) internal returns (uint256 awardedPoints) {
        uint256 startingPoints = pointsToken.balanceOf(user);

        swapRouter.swap{value: amountIn}({
            amountSpecified: -int256(amountIn),
            amountLimit: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: hook.getHookData(user, referrer),
            receiver: user,
            deadline: block.timestamp + 1
        });

        awardedPoints = pointsToken.balanceOf(user) - startingPoints;
    }

    function _activity(
        address user
    )
        internal
        view
        returns (
            uint256 lifetimeVolume,
            uint256 totalRewards,
            uint256 swapCount,
            uint256 liquidityEventCount,
            uint256 streakDays,
            uint256 claimedToday
        )
    {
        uint256 lastActionDay;
        uint256 lastClaimDay;

        (
            lifetimeVolume,
            totalRewards,
            swapCount,
            liquidityEventCount,
            streakDays,
            lastActionDay,
            claimedToday,
            lastClaimDay
        ) = hook.userActivity(user);
    }
}
