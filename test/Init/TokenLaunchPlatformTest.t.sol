// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Base} from "test/Base.t.sol";
import {TokenLaunchPlatform} from "src/Initialization/TokenLaunchPlatform.sol";
import {Token} from "test/mocks/Token.sol";

contract TokenLaunchPlatformTest is Base {
    TokenLaunchPlatform platform;
    Token launchToken;
    Token paymentToken;

    address _deployer = address(0x2);
    address user = address(0xee);

    function setUp() external {
        launchToken = new Token("LTN", "LTN");
        paymentToken = new Token("PTN", "PTN");

        vm.prank(_deployer);
        platform = new TokenLaunchPlatform();

        _configure();
    }

    function _configure() internal {
        vm.prank(_deployer);
        platform.configure(address(launchToken), address(paymentToken), 1e18);
    }

    function _launch() internal {
        platform.launch();
    }

    function testRegister() external {
        vm.prank(user);
        platform.registerForLaunch();
    }

    function testContributeAfterLaunch() external {
        // without registering for launch
        _launch();

        paymentToken.mint(user, 10e18);
        vm.prank(user);
        paymentToken.approve(address(platform), type(uint128).max);

        vm.prank(user);
        platform.contribute(10e18);
    }
}
