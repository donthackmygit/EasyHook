// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {PointsHook} from "../src/PointsHook.sol";
import {PointsRewardManager} from "../src/PointsRewardManager.sol";
import {PointsToken} from "../src/PointsToken.sol";

import {BaseTest} from "./utils/BaseTest.sol";

contract PointsHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    event UserAction(
        address indexed user,
        PoolId indexed poolId,
        PointsHook.ActionType indexed actionType,
        uint256 ethAmount,
        address referrer,
        uint256 blockTimestamp
    );

    uint256 private constant REWARD_SIGNER_PK = 0xA11CE;
    uint256 private constant WRONG_SIGNER_PK = 0xB0B;

    PointsHook hook;
    PointsRewardManager rewardManager;
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

        address flags = address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG) ^ (0x4444 << 144));
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("PointsHook.sol:PointsHook", constructorArgs, flags);
        hook = PointsHook(flags);

        rewardManager = new PointsRewardManager(vm.addr(REWARD_SIGNER_PK));
        pointsToken = rewardManager.pointsToken();

        key = PoolKey(Currency.wrap(address(0)), currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        deal(address(this), 200 ether);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(100e18)
        );

        (tokenId,) = positionManager.mint(
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

    function test_PointsHook_EmitsUserActionOnSwap() public {
        address trader = address(0xCAFE);
        address referrer = address(0xBEEF);

        vm.expectEmit(true, true, true, false, address(hook));
        emit UserAction(trader, poolId, PointsHook.ActionType.Swap, 0, address(0), 0);

        _swapEthForToken(trader, referrer, 1e18);
    }

    function test_PointsHook_EmitsUserActionOnAddLiquidity() public {
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(1e18)
        );

        vm.expectEmit(true, true, true, false, address(hook));
        emit UserAction(address(this), poolId, PointsHook.ActionType.AddLiquidity, 0, address(0), 0);

        positionManager.increaseLiquidity(
            tokenId, 1e18, amount0 + 1, amount1 + 1, block.timestamp + 1, hook.getHookData(address(this))
        );
    }

    function test_PointsRewardManager_ClaimsWithValidServerSignature() public {
        address user = address(0xCAFE);
        uint256 amount = 15e18;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signClaim(REWARD_SIGNER_PK, user, amount, nonce, deadline);

        assertEq(pointsToken.owner(), address(rewardManager), "Reward manager should own POINTS minting");

        rewardManager.claimPoints(user, amount, nonce, deadline, signature);

        assertEq(pointsToken.balanceOf(user), amount, "Claim should mint the server-approved amount");
        assertTrue(rewardManager.usedNonces(user, nonce), "Nonce should be marked as used");
    }

    function test_PointsRewardManager_RevertsInvalidSignature() public {
        address user = address(0xCAFE);
        uint256 amount = 15e18;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signClaim(WRONG_SIGNER_PK, user, amount, nonce, deadline);

        vm.expectRevert(PointsRewardManager.InvalidSignature.selector);
        rewardManager.claimPoints(user, amount, nonce, deadline, signature);
    }

    function test_PointsRewardManager_RevertsReusedNonce() public {
        address user = address(0xCAFE);
        uint256 amount = 15e18;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signClaim(REWARD_SIGNER_PK, user, amount, nonce, deadline);

        rewardManager.claimPoints(user, amount, nonce, deadline, signature);

        vm.expectRevert(PointsRewardManager.NonceAlreadyUsed.selector);
        rewardManager.claimPoints(user, amount, nonce, deadline, signature);
    }

    function test_PointsRewardManager_RevertsExpiredSignature() public {
        address user = address(0xCAFE);
        uint256 amount = 15e18;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1;
        bytes memory signature = _signClaim(REWARD_SIGNER_PK, user, amount, nonce, deadline);

        vm.warp(deadline + 1);

        vm.expectRevert(PointsRewardManager.ClaimExpired.selector);
        rewardManager.claimPoints(user, amount, nonce, deadline, signature);
    }

    function _swapEthForToken(address user, address referrer, uint256 amountIn) internal {
        swapRouter.swap{value: amountIn}({
            amountSpecified: -int256(amountIn),
            amountLimit: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: hook.getHookData(user, referrer),
            receiver: user,
            deadline: block.timestamp + 1
        });
    }

    function _signClaim(uint256 privateKey, address user, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = rewardManager.claimDigest(user, amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
