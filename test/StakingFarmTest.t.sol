// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Base} from "test/Base.t.sol";
import {StakingFarm} from "src/Initialization/StakingFarm.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Token} from "test/mocks/Token.sol";
import {console2} from "forge-std/console2.sol";

contract StakingFarmTest is Base {
    StakingFarm staking;
    Token stakingToken;
    Token rewardToken;

    address user = address(0x2);
    address owner = address(0x3);

    function setUp() external {
        stakingToken = new Token("stk", "stk");
        rewardToken = new Token("rwd", "rwd");

        vm.prank(owner);
        staking = new StakingFarm(address(stakingToken), address(rewardToken));

        stakingToken.mint(user, 100_000e18);
    }

    function testStakingBeforeStartTime() external {
        vm.prank(owner);
        staking.setStartTime(block.timestamp + 1 days);

        vm.warp(block.timestamp + 1 hours);
        vm.startPrank(user);
        stakingToken.approve(address(staking), type(uint128).max);
        staking.deposit(10_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 24 hours);

        uint256 pendingReward = staking.pendingReward(user);
        console2.log("User pending reward: ", pendingReward);
        // 36000_000_000_000_000_000_000
    }
}
