// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Base} from "test/Base.t.sol";
import {console2} from "forge-std/console2.sol";
import {StakingRewards} from "src/PriceManipulation/StakingRewards.sol";
import {Token} from "test/mocks/Token.sol";

contract StakingRewardsTest is Base {
    Token stakingToken;
    Token rewardToken;
    StakingRewards stake;

    address rewarder = address(0x11);
    address user = address(0x22);

    function setUp() external {
        stakingToken = new Token("STK", "STK");
        rewardToken = new Token("RTN", "RTN");

        vm.prank(rewarder);
        stake = new StakingRewards(address(stakingToken), address(rewardToken));
    }

    function _deposit(address _user, uint256 _amount) internal {
        vm.startPrank(_user);
        stakingToken.mint(_user, _amount);
        stakingToken.approve(address(stake), type(uint128).max);

        stake.stake(_amount);
        vm.stopPrank();
    }

    function _rewardDistribution(uint256 _amount) internal {
        rewardToken.mint(rewarder, _amount);
        vm.prank(rewarder);
        rewardToken.approve(address(stake), type(uint128).max);

        vm.prank(rewarder);
        stake.distributeReward(_amount);
    }

    function testStakeBeforeRewardDistribution() external {
        // legitimate stakers
        address staker = address(0x1111);
        address staker1 = address(0x2222);

        _deposit(staker, 5_000e18);
        // reward distribution
        _rewardDistribution(1_000e18);
        _deposit(staker1, 5_000e18);

        vm.warp(block.timestamp + 20 days);

        // attacker stakes before reward distribution
        address attacker = address(0xA);
        _deposit(attacker, 10_000e18);
        _rewardDistribution(2_000e18);

        // checks the pending rewards
        uint256 attackerReward = stake.pendingReward(attacker);
        uint256 stakerReward = stake.pendingReward(staker);
        uint256 staker1Reward = stake.pendingReward(staker1);

        console2.log("attackerReward: ", attackerReward);
        console2.log("stakerReward: ", stakerReward);
        console2.log("staker1Reward: ", staker1Reward);
    }
}

