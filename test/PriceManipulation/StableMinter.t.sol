// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {StableMinter} from "src/PriceManipulation/StableMinter.sol";
import {Base} from "test/Base.t.sol";
import {Token} from "test/mocks/Token.sol";

contract MockPool {
    function getReserves() external view returns (uint256 rA, uint256 rB) {
        rA = 1e18;
        rB = 1e18;
    }
}

contract StableMinterTest is Base {
    MockPool pool;
    StableMinter minter;
    Token token;

    address user = address(0x11);

    function setUp() external {
        token = new Token("Collateral Token", "CTK");
        pool = new MockPool();

        minter = new StableMinter(address(token), address(pool));
        token.mint(user, 10_000e18);
    }

    function testRedeem() external {
        uint256 stableAmt = 500e18;
        vm.startPrank(user);
        // deposit
        token.approve(address(minter), type(uint128).max);
        minter.depositAndMint(1_000e18, stableAmt);
        // redeem
        minter.redeem(stableAmt);
        vm.stopPrank();

        // assert collateral balance remaining and no way to get it back
        uint256 collateral = minter.deposits(user);
        uint256 _minted = minter.minted(user);

        assertGe(collateral, 0);
        assertEq(_minted, 0);

        vm.prank(user);
        vm.expectRevert("Exceeds minted");
        minter.redeem(1);
    }
}
