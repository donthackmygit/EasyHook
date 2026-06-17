# EasyHook Reward Server

This server keeps reward scoring outside the Uniswap hook.

The hook only emits `UserAction` events. The server reads those events through RPC,
calculates user score, tier, streak, daily cap and referral rewards, then signs an
EIP-712 claim. `PointsRewardManager` verifies that signature before minting POINTS.

## Install

```powershell
cd server
npm install
```

## Run

```powershell
$env:RPC_URL="http://127.0.0.1:8545"
$env:POINTS_HOOK_ADDRESS="0x..."
$env:REWARD_MANAGER_ADDRESS="0x..."
$env:REWARD_SIGNER_PRIVATE_KEY="0x..."
$env:START_BLOCK="0"
npm start
```

## API

- `GET /users/:address/score`
- `GET /users/:address/rewards`
- `GET /leaderboard`
- `POST /users/:address/claim-signature`

The claim signature response can be submitted to:

```solidity
PointsRewardManager.claimPoints(user, amount, nonce, deadline, signature)
```
