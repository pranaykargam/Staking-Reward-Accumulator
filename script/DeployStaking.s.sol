// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Staking.sol";

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
}

contract DeployStaking is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address stakingToken = vm.envAddress("STAKING_TOKEN");
        address rewardToken = vm.envAddress("REWARD_TOKEN");
        uint256 rewardPerBlock = vm.envUint("REWARD_PER_BLOCK");
        uint256 startBlock = vm.envUint("START_BLOCK");
        uint256 endBlock = vm.envUint("END_BLOCK");

        uint256 rewardFunding = vm.envOr("REWARD_FUNDING", uint256(0));

        vm.startBroadcast(deployerPrivateKey);
        Staking staking = new Staking(
            stakingToken,
            rewardToken,
            rewardPerBlock,
            startBlock,
            endBlock
        );

        if (rewardFunding > 0) {
            IERC20Minimal(rewardToken).approve(address(staking), rewardFunding);
            staking.fundRewards(rewardFunding);
        }

        vm.stopBroadcast();
    }
}

