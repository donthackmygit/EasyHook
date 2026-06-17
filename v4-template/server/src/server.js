import express from "express";
import { ethers } from "ethers";
import {
  calculateRewards,
  createEmptyActivity,
  normalizeUser,
  parseUserActionLogs,
  userActionAbi,
} from "./reward-engine.js";

const PORT = Number(process.env.PORT ?? 3001);
const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const POINTS_HOOK_ADDRESS = process.env.POINTS_HOOK_ADDRESS;
const REWARD_MANAGER_ADDRESS = process.env.REWARD_MANAGER_ADDRESS;
const REWARD_SIGNER_PRIVATE_KEY = process.env.REWARD_SIGNER_PRIVATE_KEY;
const START_BLOCK = Number(process.env.START_BLOCK ?? 0);
const CLAIM_TTL_SECONDS = Number(process.env.CLAIM_TTL_SECONDS ?? 3600);

const provider = new ethers.JsonRpcProvider(RPC_URL);
const hookInterface = new ethers.Interface(userActionAbi);
const issuedRewards = new Map();
let nextNonce = 1n;

const app = express();
app.use(express.json());

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    rpcUrl: RPC_URL,
    hookConfigured: Boolean(POINTS_HOOK_ADDRESS),
    rewardManagerConfigured: Boolean(REWARD_MANAGER_ADDRESS),
  });
});

app.get(
  "/users/:address/score",
  asyncHandler(async (req, res) => {
    const user = ethers.getAddress(req.params.address);
    const state = await loadRewardState();
    const activity = state.users.get(user) ?? createEmptyActivity(user);

    res.json(normalizeUser(activity, getIssuedRewards(user)));
  })
);

app.get(
  "/users/:address/rewards",
  asyncHandler(async (req, res) => {
    const user = ethers.getAddress(req.params.address);
    const state = await loadRewardState();
    const activity = state.users.get(user) ?? createEmptyActivity(user);

    res.json({
      user,
      rewards: normalizeUser(activity, getIssuedRewards(user)),
    });
  })
);

app.get(
  "/leaderboard",
  asyncHandler(async (req, res) => {
    const limit = Number(req.query.limit ?? 20);
    const state = await loadRewardState();
    const users = [...state.users.values()]
      .sort((a, b) => compareBigIntDesc(a.totalRewards, b.totalRewards))
      .slice(0, limit)
      .map((activity) => normalizeUser(activity, getIssuedRewards(activity.address)));

    res.json({ users });
  })
);

app.post(
  "/users/:address/claim-signature",
  asyncHandler(async (req, res) => {
    if (!REWARD_MANAGER_ADDRESS) {
      return res.status(500).json({ error: "Missing REWARD_MANAGER_ADDRESS" });
    }

    if (!REWARD_SIGNER_PRIVATE_KEY) {
      return res.status(500).json({ error: "Missing REWARD_SIGNER_PRIVATE_KEY" });
    }

    const user = ethers.getAddress(req.params.address);
    const state = await loadRewardState();
    const activity = state.users.get(user) ?? createEmptyActivity(user);
    const issued = getIssuedRewards(user);
    const claimable = activity.totalRewards > issued ? activity.totalRewards - issued : 0n;
    const requestedAmount = req.body?.amount ? BigInt(req.body.amount) : claimable;

    if (requestedAmount <= 0n || requestedAmount > claimable) {
      return res.status(400).json({
        error: "Invalid claim amount",
        claimableRewards: claimable.toString(),
      });
    }

    const network = await provider.getNetwork();
    const wallet = new ethers.Wallet(REWARD_SIGNER_PRIVATE_KEY, provider);
    const nonce = nextNonce++;
    const deadline = BigInt(Math.floor(Date.now() / 1000) + CLAIM_TTL_SECONDS);
    const verifyingContract = ethers.getAddress(REWARD_MANAGER_ADDRESS);

    const domain = {
      name: "PointsRewardManager",
      version: "1",
      chainId: network.chainId,
      verifyingContract,
    };
    const types = {
      Claim: [
        { name: "user", type: "address" },
        { name: "amount", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    };
    const claim = {
      user,
      amount: requestedAmount,
      nonce,
      deadline,
    };
    const signature = await wallet.signTypedData(domain, types, claim);

    issuedRewards.set(user, issued + requestedAmount);

    res.json({
      user,
      amount: requestedAmount.toString(),
      nonce: nonce.toString(),
      deadline: deadline.toString(),
      signature,
      rewardManager: verifyingContract,
      pointsToken: "Read pointsToken() from rewardManager",
    });
  })
);

app.use((err, _req, res, _next) => {
  res.status(500).json({ error: err.message });
});

app.listen(PORT, () => {
  console.log(`Reward server listening on http://localhost:${PORT}`);
});

async function loadRewardState() {
  if (!POINTS_HOOK_ADDRESS) {
    throw new Error("Missing POINTS_HOOK_ADDRESS");
  }

  const event = hookInterface.getEvent("UserAction");
  const logs = await provider.getLogs({
    address: ethers.getAddress(POINTS_HOOK_ADDRESS),
    topics: [event.topicHash],
    fromBlock: START_BLOCK,
    toBlock: "latest",
  });
  const events = parseUserActionLogs(logs);

  return calculateRewards(events);
}

function getIssuedRewards(user) {
  return issuedRewards.get(ethers.getAddress(user)) ?? 0n;
}

function compareBigIntDesc(left, right) {
  if (left === right) return 0;
  return left > right ? -1 : 1;
}

function asyncHandler(handler) {
  return (req, res, next) => Promise.resolve(handler(req, res, next)).catch(next);
}
