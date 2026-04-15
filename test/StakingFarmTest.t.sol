// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Base} from "test/Base.t.sol";
import {StakingFarm} from "src/Initialization/StakingFarm.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StakingFarmTest is Base {
    StakingFarm staking;

    function setUp() external {
        staking = new StakingFarm();
    }
}
