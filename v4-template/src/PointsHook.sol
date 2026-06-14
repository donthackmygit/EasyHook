// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PointsToken} from "./PointsToken.sol";

contract PointsHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    uint256 public constant BPS = 10_000;
    uint256 public constant SILVER_VOLUME = 5 ether;
    uint256 public constant GOLD_VOLUME = 20 ether;
    uint256 public constant PLATINUM_VOLUME = 50 ether;
    uint256 public constant SILVER_BONUS_BPS = 1_000;
    uint256 public constant GOLD_BONUS_BPS = 2_500;
    uint256 public constant PLATINUM_BONUS_BPS = 5_000;
    uint256 public constant LIQUIDITY_BONUS_BPS = 2_000;
    uint256 public constant STREAK_BONUS_PER_DAY_BPS = 500;
    uint256 public constant MAX_STREAK_BONUS_BPS = 2_500;
    uint256 public constant REFERRAL_BONUS_BPS = 500;
    uint256 public constant DAILY_REWARD_CAP = 100 ether;

    enum RewardKind {
        Swap,
        AddLiquidity
    }

    enum Tier {
        Bronze,
        Silver,
        Gold,
        Platinum
    }

    struct UserActivity {
        uint256 lifetimeVolume;
        uint256 totalRewards;
        uint256 swapCount;
        uint256 liquidityEventCount;
        uint256 streakDays;
        uint256 lastActionDay;
        uint256 claimedToday;
        uint256 lastClaimDay;
    }

    struct PoolStats {
        uint256 swapVolume;
        uint256 liquidityVolume;
        uint256 rewardsMinted;
        uint256 swapCount;
        uint256 liquidityEventCount;
    }

    PointsToken public pointsToken;

    mapping(address user => UserActivity activity) public userActivity;
    mapping(PoolId poolId => PoolStats stats) public poolStats;
    mapping(PoolId poolId => mapping(address user => uint256 volume)) public userPoolVolume;

    event PointsAwarded(
        address indexed user,
        PoolId indexed poolId,
        RewardKind indexed kind,
        uint256 ethAmount,
        uint256 pointsAmount,
        uint256 multiplierBps,
        Tier tier,
        uint256 streakDays
    );
    event ReferralAwarded(address indexed referrer, address indexed user, uint256 pointsAmount);
    event TierChanged(address indexed user, Tier oldTier, Tier newTier);
    event DailyCapReached(address indexed user, uint256 requestedPoints, uint256 awardedPoints);

    error MissingHookUser();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        pointsToken = new PointsToken();
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function getPointsForAmount(uint256 amount) internal pure returns (uint256) {
        return amount;
    }

    function getHookData(address user) public pure returns (bytes memory) {
        return abi.encode(user, address(0));
    }

    function getHookData(address user, address referrer) public pure returns (bytes memory) {
        return abi.encode(user, referrer);
    }

    function parseHookData(bytes calldata data) public pure returns (address user, address referrer) {
        if (data.length == 32) {
            user = abi.decode(data, (address));
        } else {
            (user, referrer) = abi.decode(data, (address, address));
        }

        if (user == address(0)) revert MissingHookUser();
    }

    function getTier(address user) public view returns (Tier) {
        return _tierForVolume(userActivity[user].lifetimeVolume);
    }

    function previewPoints(
        address user,
        uint256 ethAmount,
        bool isLiquidity
    ) public view returns (uint256 points, uint256 multiplierBps, Tier tier, uint256 streakDays) {
        tier = _tierForVolume(userActivity[user].lifetimeVolume);
        streakDays = _nextStreakDays(user);
        multiplierBps = BPS + _tierBonusBps(tier) + _streakBonusBps(streakDays);

        if (isLiquidity) {
            multiplierBps += LIQUIDITY_BONUS_BPS;
        }

        points = (getPointsForAmount(ethAmount) * multiplierBps) / BPS;
        uint256 remainingRewards = _remainingDailyRewards(user);
        if (points > remainingRewards) {
            points = remainingRewards;
        }
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override onlyPoolManager returns (bytes4, int128) {
        // We only award points in the ETH/TOKEN pools.
        if (!key.currency0.isAddressZero()) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // We only award points if the user is buying the TOKEN
        if (!swapParams.zeroForOne) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // Let's figure out who's the user
        (address user, address referrer) = parseHookData(hookData);

        if (delta.amount0() >= 0) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // How much ETH are they spending?
        uint256 ethSpendAmount = uint256(int256(-delta.amount0()));

        // And award the points!
        _awardPoints(user, referrer, key, ethSpendAmount, RewardKind.Swap);

        return (BaseHook.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override onlyPoolManager returns (bytes4, BalanceDelta) {
        // We only award points in the ETH/TOKEN pools.
        if (!key.currency0.isAddressZero()) {
            return (BaseHook.afterAddLiquidity.selector, delta);
        }

        // Let's figure out who's the user
        (address user, address referrer) = parseHookData(hookData);

        if (delta.amount0() >= 0) {
            return (BaseHook.afterAddLiquidity.selector, delta);
        }

        // How much ETH are they spending?
        uint256 ethSpendAmount = uint256(int256(-delta.amount0()));

        // And award the points!
        _awardPoints(user, referrer, key, ethSpendAmount, RewardKind.AddLiquidity);

        return (BaseHook.afterAddLiquidity.selector, delta);
    }

    function _awardPoints(
        address user,
        address referrer,
        PoolKey calldata key,
        uint256 ethAmount,
        RewardKind kind
    ) internal {
        UserActivity storage activity = userActivity[user];
        PoolId poolId = key.toId();
        Tier oldTier = _tierForVolume(activity.lifetimeVolume);
        uint256 streakDays = _nextStreakDays(user);
        uint256 multiplierBps = BPS + _tierBonusBps(oldTier) + _streakBonusBps(streakDays);

        if (kind == RewardKind.AddLiquidity) {
            multiplierBps += LIQUIDITY_BONUS_BPS;
            activity.liquidityEventCount++;
            poolStats[poolId].liquidityVolume += ethAmount;
            poolStats[poolId].liquidityEventCount++;
        } else {
            activity.swapCount++;
            poolStats[poolId].swapVolume += ethAmount;
            poolStats[poolId].swapCount++;
        }

        activity.streakDays = streakDays;
        activity.lastActionDay = _today();
        activity.lifetimeVolume += ethAmount;
        userPoolVolume[poolId][user] += ethAmount;

        uint256 rawPoints = (getPointsForAmount(ethAmount) * multiplierBps) / BPS;
        uint256 awardedPoints = _applyDailyCap(user, rawPoints);

        if (awardedPoints > 0) {
            activity.totalRewards += awardedPoints;
            poolStats[poolId].rewardsMinted += awardedPoints;
            pointsToken.mint(user, awardedPoints);
        }

        Tier newTier = _tierForVolume(activity.lifetimeVolume);
        if (newTier != oldTier) {
            emit TierChanged(user, oldTier, newTier);
        }

        emit PointsAwarded(user, poolId, kind, ethAmount, awardedPoints, multiplierBps, oldTier, streakDays);

        if (referrer != address(0) && referrer != user && awardedPoints > 0) {
            uint256 referralPoints = _applyDailyCap(referrer, (awardedPoints * REFERRAL_BONUS_BPS) / BPS);

            if (referralPoints > 0) {
                userActivity[referrer].totalRewards += referralPoints;
                poolStats[poolId].rewardsMinted += referralPoints;
                pointsToken.mint(referrer, referralPoints);
                emit ReferralAwarded(referrer, user, referralPoints);
            }
        }
    }

    function _applyDailyCap(address user, uint256 requestedPoints) internal returns (uint256 awardedPoints) {
        UserActivity storage activity = userActivity[user];
        uint256 today = _today();

        if (activity.lastClaimDay != today) {
            activity.lastClaimDay = today;
            activity.claimedToday = 0;
        }

        uint256 remainingRewards = DAILY_REWARD_CAP > activity.claimedToday
            ? DAILY_REWARD_CAP - activity.claimedToday
            : 0;

        awardedPoints = requestedPoints > remainingRewards ? remainingRewards : requestedPoints;
        activity.claimedToday += awardedPoints;

        if (awardedPoints < requestedPoints) {
            emit DailyCapReached(user, requestedPoints, awardedPoints);
        }
    }

    function _remainingDailyRewards(address user) internal view returns (uint256) {
        UserActivity storage activity = userActivity[user];

        if (activity.lastClaimDay != _today()) {
            return DAILY_REWARD_CAP;
        }

        return DAILY_REWARD_CAP > activity.claimedToday ? DAILY_REWARD_CAP - activity.claimedToday : 0;
    }

    function _nextStreakDays(address user) internal view returns (uint256) {
        UserActivity storage activity = userActivity[user];
        uint256 today = _today();

        if (activity.lastActionDay == today) {
            return activity.streakDays == 0 ? 1 : activity.streakDays;
        }

        if (activity.lastActionDay + 1 == today) {
            return activity.streakDays + 1;
        }

        return 1;
    }

    function _tierForVolume(uint256 lifetimeVolume) internal pure returns (Tier) {
        if (lifetimeVolume >= PLATINUM_VOLUME) {
            return Tier.Platinum;
        }

        if (lifetimeVolume >= GOLD_VOLUME) {
            return Tier.Gold;
        }

        if (lifetimeVolume >= SILVER_VOLUME) {
            return Tier.Silver;
        }

        return Tier.Bronze;
    }

    function _tierBonusBps(Tier tier) internal pure returns (uint256) {
        if (tier == Tier.Platinum) {
            return PLATINUM_BONUS_BPS;
        }

        if (tier == Tier.Gold) {
            return GOLD_BONUS_BPS;
        }

        if (tier == Tier.Silver) {
            return SILVER_BONUS_BPS;
        }

        return 0;
    }

    function _streakBonusBps(uint256 streakDays) internal pure returns (uint256) {
        if (streakDays <= 1) {
            return 0;
        }

        uint256 bonusBps = (streakDays - 1) * STREAK_BONUS_PER_DAY_BPS;
        return bonusBps > MAX_STREAK_BONUS_BPS ? MAX_STREAK_BONUS_BPS : bonusBps;
    }

    function _today() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }
}
