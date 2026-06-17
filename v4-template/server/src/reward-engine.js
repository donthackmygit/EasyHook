import { ethers } from "ethers";

export const ACTION_TYPE = {
  SWAP: 0,
  ADD_LIQUIDITY: 1,
};

const BPS = 10_000n;
const SILVER_VOLUME = ethers.parseEther("5");
const GOLD_VOLUME = ethers.parseEther("20");
const PLATINUM_VOLUME = ethers.parseEther("50");
const SILVER_BONUS_BPS = 1_000n;
const GOLD_BONUS_BPS = 2_500n;
const PLATINUM_BONUS_BPS = 5_000n;
const LIQUIDITY_BONUS_BPS = 2_000n;
const STREAK_BONUS_PER_DAY_BPS = 500n;
const MAX_STREAK_BONUS_BPS = 2_500n;
const REFERRAL_BONUS_BPS = 500n;
const DAILY_REWARD_CAP = ethers.parseEther("100");

export const userActionAbi = [
  "event UserAction(address indexed user, bytes32 indexed poolId, uint8 indexed actionType, uint256 ethAmount, address referrer, uint256 blockTimestamp)",
];

export function createEmptyActivity(address) {
  return {
    address: ethers.getAddress(address),
    lifetimeVolume: 0n,
    totalRewards: 0n,
    swapCount: 0,
    liquidityEventCount: 0,
    streakDays: 0,
    lastActionDay: 0,
    dailyRewards: new Map(),
  };
}

export function calculateRewards(events) {
  const users = new Map();
  const pools = new Map();

  for (const event of events) {
    const user = getActivity(users, event.user);
    const pool = getPoolStats(pools, event.poolId);
    const day = Math.floor(Number(event.blockTimestamp) / 86_400);
    const oldTier = tierForVolume(user.lifetimeVolume);
    const streakDays = nextStreakDays(user, day);
    let multiplierBps = BPS + tierBonusBps(oldTier) + streakBonusBps(streakDays);

    if (event.actionType === ACTION_TYPE.ADD_LIQUIDITY) {
      multiplierBps += LIQUIDITY_BONUS_BPS;
      user.liquidityEventCount += 1;
      pool.liquidityVolume += event.ethAmount;
      pool.liquidityEventCount += 1;
    } else {
      user.swapCount += 1;
      pool.swapVolume += event.ethAmount;
      pool.swapCount += 1;
    }

    user.streakDays = streakDays;
    user.lastActionDay = day;
    user.lifetimeVolume += event.ethAmount;

    const rawPoints = (event.ethAmount * multiplierBps) / BPS;
    const awardedPoints = applyDailyCap(user, day, rawPoints);

    user.totalRewards += awardedPoints;
    pool.rewardsMinted += awardedPoints;

    if (isRewardableReferrer(event.referrer, event.user) && awardedPoints > 0n) {
      const referrer = getActivity(users, event.referrer);
      const referralPoints = applyDailyCap(referrer, day, (awardedPoints * REFERRAL_BONUS_BPS) / BPS);
      referrer.totalRewards += referralPoints;
      pool.rewardsMinted += referralPoints;
    }
  }

  return { users, pools };
}

export function normalizeUser(activity, issuedRewards = 0n) {
  const claimableRewards = activity.totalRewards > issuedRewards ? activity.totalRewards - issuedRewards : 0n;

  return {
    address: activity.address,
    tier: tierForVolume(activity.lifetimeVolume),
    lifetimeVolume: activity.lifetimeVolume.toString(),
    totalRewards: activity.totalRewards.toString(),
    issuedRewards: issuedRewards.toString(),
    claimableRewards: claimableRewards.toString(),
    swapCount: activity.swapCount,
    liquidityEventCount: activity.liquidityEventCount,
    streakDays: activity.streakDays,
  };
}

export function parseUserActionLogs(logs) {
  const iface = new ethers.Interface(userActionAbi);

  return logs
    .map((log) => {
      const parsed = iface.parseLog(log);
      return {
        user: ethers.getAddress(parsed.args.user),
        poolId: parsed.args.poolId,
        actionType: Number(parsed.args.actionType),
        ethAmount: BigInt(parsed.args.ethAmount),
        referrer: ethers.getAddress(parsed.args.referrer),
        blockTimestamp: BigInt(parsed.args.blockTimestamp),
        blockNumber: log.blockNumber,
        logIndex: log.index,
      };
    })
    .sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex);
}

function getActivity(users, address) {
  const checksumAddress = ethers.getAddress(address);
  if (!users.has(checksumAddress)) {
    users.set(checksumAddress, createEmptyActivity(checksumAddress));
  }

  return users.get(checksumAddress);
}

function getPoolStats(pools, poolId) {
  if (!pools.has(poolId)) {
    pools.set(poolId, {
      poolId,
      swapVolume: 0n,
      liquidityVolume: 0n,
      rewardsMinted: 0n,
      swapCount: 0,
      liquidityEventCount: 0,
    });
  }

  return pools.get(poolId);
}

function nextStreakDays(activity, day) {
  if (activity.lastActionDay === day) {
    return activity.streakDays || 1;
  }

  if (activity.lastActionDay + 1 === day) {
    return activity.streakDays + 1;
  }

  return 1;
}

function applyDailyCap(activity, day, requestedPoints) {
  const claimedToday = activity.dailyRewards.get(day) ?? 0n;
  const remainingRewards = DAILY_REWARD_CAP > claimedToday ? DAILY_REWARD_CAP - claimedToday : 0n;
  const awardedPoints = requestedPoints > remainingRewards ? remainingRewards : requestedPoints;
  activity.dailyRewards.set(day, claimedToday + awardedPoints);
  return awardedPoints;
}

function tierForVolume(volume) {
  if (volume >= PLATINUM_VOLUME) return "Platinum";
  if (volume >= GOLD_VOLUME) return "Gold";
  if (volume >= SILVER_VOLUME) return "Silver";
  return "Bronze";
}

function tierBonusBps(tier) {
  if (tier === "Platinum") return PLATINUM_BONUS_BPS;
  if (tier === "Gold") return GOLD_BONUS_BPS;
  if (tier === "Silver") return SILVER_BONUS_BPS;
  return 0n;
}

function streakBonusBps(streakDays) {
  if (streakDays <= 1) return 0n;

  const bonusBps = BigInt(streakDays - 1) * STREAK_BONUS_PER_DAY_BPS;
  return bonusBps > MAX_STREAK_BONUS_BPS ? MAX_STREAK_BONUS_BPS : bonusBps;
}

function isRewardableReferrer(referrer, user) {
  return referrer !== ethers.ZeroAddress && ethers.getAddress(referrer) !== ethers.getAddress(user);
}
