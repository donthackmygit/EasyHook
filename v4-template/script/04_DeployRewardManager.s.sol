// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseScript} from "./base/BaseScript.sol";
import {PointsRewardManager} from "../src/PointsRewardManager.sol";

/// @notice Deploys the external reward manager that owns and mints POINTS.
contract DeployRewardManagerScript is BaseScript {
    function run() public {
        address rewardSigner = vm.envOr("REWARD_SIGNER", deployerAddress);

        vm.startBroadcast();
        PointsRewardManager rewardManager = new PointsRewardManager(rewardSigner);
        vm.stopBroadcast();

        require(address(rewardManager.pointsToken()) != address(0), "Reward token not deployed");
    }
}
