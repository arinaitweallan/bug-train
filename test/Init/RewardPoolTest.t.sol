// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Base} from "test/Base.t.sol";
import {Token} from "test/mocks/Token.sol";
import {RewardPool} from "src/Initialization/RewardPool.sol";

contract RewardPoolTest is Base {
    RewardPool pool;
    Token stakingToken;
    Token rewardToken;

    address distributor = address(0x9aa);

    function setUp() external {
        stakingToken = new Token("STK", "STK");
        rewardToken = new Token("RTK", "RTK");

        pool = new RewardPool(address(stakingToken), address(rewardToken), distributor);
    }

    function testStakeBeforeNotifyRewards() external {
        address _user = address(0x911);

        stakingToken.mint(_user, type(uint112).max);
        rewardToken.mint(distributor, type(uint112).max);

        // call stake() before notify rewards
        vm.prank(_user);
        stakingToken.approve(address(pool), type(uint112).max);

        vm.prank(_user);
        pool.stake(1_000_000e18);

        // distributor calls notify rewards
        vm.prank(distributor);
        rewardToken.approve(address(pool), type(uint112).max);

        vm.prank(distributor);
        pool.notifyRewardAmount(700_000e18);

        vm.warp(block.timestamp + 1 days);

        vm.prank(_user);
        pool.getReward();
    }
}
