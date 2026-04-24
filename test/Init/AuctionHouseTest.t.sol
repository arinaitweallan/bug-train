// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AuctionHouse} from "src/Initialization/AuctionHouse.sol";
import {Base} from "test/Base.t.sol";
import {Token} from "test/mocks/Token.sol";

contract AuctionHouseTest is Base {
    AuctionHouse auction;
    Token token;

    address attacker = address(0x1);

    function setUp() external {
        auction = new AuctionHouse();
        token = new Token("Bid Token", "BTN");

        auction.initialize(address(this), address(token), 86400);
        token.mint(attacker, 1000e18);
    }

    function testBidBeforeInit() external {
        vm.expectRevert();
        auction.bid(10_000e18);
    }

    function testExploitPath() external {
        vm.prank(attacker);
        token.approve(address(auction), type(uint128).max);

        vm.prank(attacker);
        auction.bid(100e18);

        assertEq(auction.epochWinner(1), attacker);
    }
}
