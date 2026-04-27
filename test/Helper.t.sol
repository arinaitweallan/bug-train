// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Base} from "test/Base.t.sol";
import {console2} from "forge-std/console2.sol";

contract Helper is Base {
    function castIntToUint(int256 toCast) internal pure returns (uint256 result) {
        result = uint256(toCast);
    }

    function testCastIntToUint() public pure {
        uint256 _r = castIntToUint(-50e18);
        console2.log("Result: ", _r);
    }
}
