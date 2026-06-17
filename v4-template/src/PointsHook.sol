// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract PointsHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    enum ActionType {
        Swap,
        AddLiquidity
    }

    event UserAction(
        address indexed user,
        PoolId indexed poolId,
        ActionType indexed actionType,
        uint256 ethAmount,
        address referrer,
        uint256 blockTimestamp
    );

    error MissingHookUser();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
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

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (!key.currency0.isAddressZero() || !swapParams.zeroForOne || delta.amount0() >= 0) {
            return (BaseHook.afterSwap.selector, 0);
        }

        (address user, address referrer) = parseHookData(hookData);
        uint256 ethAmount = uint256(int256(-delta.amount0()));

        emit UserAction(user, key.toId(), ActionType.Swap, ethAmount, referrer, block.timestamp);

        return (BaseHook.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (!key.currency0.isAddressZero() || delta.amount0() >= 0) {
            return (BaseHook.afterAddLiquidity.selector, delta);
        }

        (address user, address referrer) = parseHookData(hookData);
        uint256 ethAmount = uint256(int256(-delta.amount0()));

        emit UserAction(user, key.toId(), ActionType.AddLiquidity, ethAmount, referrer, block.timestamp);

        return (BaseHook.afterAddLiquidity.selector, delta);
    }
}
