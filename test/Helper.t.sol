// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Base} from "test/Base.t.sol";
import {console2} from "forge-std/console2.sol";

contract Helper is Base {
    uint256 used = 100;

    function castIntToUint(int256 toCast) internal pure returns (uint256 result) {
        result = uint256(toCast);
    }

    function castIUntToInt(uint256 toCast) internal pure returns (int256 result) {
        result = int256(toCast);
    }

    function _divide(uint256 number, uint256 usedAdd) internal returns (uint256) {
        used += usedAdd;

        used /= number;
        return used;
    }

    function testDivide() public {
        uint256 result = _divide(10, 100);
        uint256 expected = 20; // 100 + 100 = 200 / 10 = 20
        assertEq(result, expected);
    }

    function testCastIntToUint() public pure {
        uint256 _r = castIntToUint(-50e18);
        console2.log("Result: ", _r);
    }

    function test2CastUintToInt(uint256 _toCast) public pure {
        int256 _r = castIUntToInt(_toCast);

        // assert(_toCast == _r);
        console2.log("Result: ", _r);
    }
}
