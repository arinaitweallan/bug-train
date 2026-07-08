// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";

contract Cast is Test {
    struct PoolSlot0 {
        uint8 pauseLevel;
        int8 curBinIdx;
        uint104 curPosInBin;
        int24 curBinDistFromProvidedPriceE6;
        uint24 spreadFeeE6;
        uint24 notionalFeeE8;
    }

    function pack(
        uint8 pauseLevel,
        int8 curBinIdx,
        uint104 curPosInBin,
        int24 curBinDistFromProvidedPriceE6,
        uint24 spreadFeeE6,
        uint24 notionalFeeE8
    ) internal pure returns (uint256 packed) {
        packed = uint256(pauseLevel);
        // casting int8 -> int256 is lossless; outer uint256 is masked to 8 bits so no truncation
        // forge-lint: disable-next-line(unsafe-typecast)

        // @check: is this casting safe
        packed |= (uint256(uint256(int256(curBinIdx)) & 0xff) << 8);
        packed |= uint256(curPosInBin) << 16;
        // casting int24 -> int256 is lossless; outer uint256 is masked to 24 bits so no truncation
        // forge-lint: disable-next-line(unsafe-typecast)

        // @check: is this casting safe
        packed |= (uint256(uint256(int256(curBinDistFromProvidedPriceE6)) & 0xffffff) << 120);
        packed |= uint256(spreadFeeE6) << 144;
        packed |= uint256(notionalFeeE8) << 168;
    }

    function unpack(uint256 packed) internal pure returns (PoolSlot0 memory s) {
        uint8 pauseLevel;
        int256 binIdxWide;
        int256 distWide;

        assembly ("memory-safe") {
            pauseLevel := and(packed, 0xff)
            binIdxWide := signextend(0, shr(8, packed))
            distWide := signextend(2, shr(120, packed))
        }

        s.pauseLevel = pauseLevel;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.curBinIdx = int8(binIdxWide);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.curPosInBin = uint104((packed >> 16) & type(uint104).max);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.curBinDistFromProvidedPriceE6 = int24(distWide);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.spreadFeeE6 = uint24((packed >> 144) & 0xFFFFFF);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.notionalFeeE8 = uint24((packed >> 168) & 0xFFFFFF);
    }

    /// @notice Read the pool's packed slot 0 (caller must be `MetricOmmPool` or delegate context).
    function loadPackedSlot0() internal view returns (uint256 packed) {
        assembly ("memory-safe") {
            packed := sload(0)
        }
    }

    function testPacking(int24 curBin) external {
        vm.assume(curBin < 0);

        PoolSlot0 memory slot0 = PoolSlot0({
            pauseLevel: 0,
            curBinIdx: 0,
            curPosInBin: 0,
            curBinDistFromProvidedPriceE6: curBin,
            spreadFeeE6: 0,
            notionalFeeE8: 0
        });

        uint256 packed = pack(
            slot0.pauseLevel,
            slot0.curBinIdx,
            slot0.curPosInBin,
            slot0.curBinDistFromProvidedPriceE6,
            slot0.spreadFeeE6,
            slot0.notionalFeeE8
        );

        PoolSlot0 memory s = unpack(packed);

        assertEq(s.curBinDistFromProvidedPriceE6, curBin);
        console2.log("Packed: ", packed);
    }

    /// ============================================================================================ ///

    function _castToInt256(int8 number) internal returns (int256 value) {
        value = int256(number);
    }

    function testCast(int8 number) external {
        int256 answer = _castToInt256(number);
        assertEq(int8(answer), number);
    }

    function _castIntToUint(int24 x) internal returns (uint256 y) {
        // y = uint256(x);
        y = uint256(uint256(int256(x)) & 0xffffff);
    }

    function testIntToUint() external {
        int24 a = -1;

        uint256 b = _castIntToUint(a);
        console2.log("Answer is: ", b);
    }
}
