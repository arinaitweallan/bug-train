// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Base} from "test/Base.t.sol";
import {StakingFarm} from "src/Initialization/StakingFarm.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Token} from "test/mocks/Token.sol";

contract StakingFarmTest is Base {
    StakingFarm staking;
    Token stakingToken;
    Token rewardToken;

    function setUp() external {
        stakingToken = new Token("stk", "stk");
        rewardToken = new Token("rwd", "rwd");
        staking = new StakingFarm(address(stakingToken), address(rewardToken));
    }
}
