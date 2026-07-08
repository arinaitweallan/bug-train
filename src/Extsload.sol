// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";

/// @notice Interface for functions to access any storage slot in a contract
interface IExtsload {
    /// @notice Called by external contracts to access granular pool state
    /// @param slot Key of slot to sload
    /// @return value The value of the slot as bytes32
    function extsload(bytes32 slot) external view returns (bytes32 value);

    /// @notice Called by external contracts to access granular pool state
    /// @param startSlot Key of slot to start sloading from
    /// @param nSlots Number of slots to load into return value
    /// @return values List of loaded values.
    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values);

    /// @notice Called by external contracts to access sparse pool state
    /// @param slots List of slots to SLOAD from.
    /// @return values List of loaded values.
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values);
}

/// @notice Enables public storage access for efficient state retrieval by external contracts.
/// https://eips.ethereum.org/EIPS/eip-2330#rationale
abstract contract Extsload is IExtsload {
    /// @inheritdoc IExtsload
    function extsload(bytes32 slot) external view returns (bytes32) {
        assembly ("memory-safe") {
            mstore(0, sload(slot))
            return(0, 0x20)
        }
    }

    /// @inheritdoc IExtsload
    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory) {
        assembly ("memory-safe") {
            let memptr := mload(0x40)
            let start := memptr
            // A left bit-shift of 5 is equivalent to multiplying by 32 but costs less gas.
            let length := shl(5, nSlots)
            // The abi offset of dynamic array in the returndata is 32.
            mstore(memptr, 0x20)
            // Store the length of the array returned
            mstore(add(memptr, 0x20), nSlots)
            // update memptr to the first location to hold a result
            memptr := add(memptr, 0x40)
            let end := add(memptr, length)
            for {} 1 {} {
                mstore(memptr, sload(startSlot))
                memptr := add(memptr, 0x20)
                startSlot := add(startSlot, 1)
                if iszero(lt(memptr, end)) { break }
            }
            return(start, sub(end, start))
        }
    }

    /// @inheritdoc IExtsload
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory) {
        assembly ("memory-safe") {
            let memptr := mload(0x40)
            let start := memptr
            // for abi encoding the response - the array will be found at 0x20
            mstore(memptr, 0x20)
            // next we store the length of the return array
            mstore(add(memptr, 0x20), slots.length)
            // update memptr to the first location to hold an array entry
            memptr := add(memptr, 0x40)
            // A left bit-shift of 5 is equivalent to multiplying by 32 but costs less gas.
            let end := add(memptr, shl(5, slots.length))
            let calldataptr := slots.offset
            for {} 1 {} {
                mstore(memptr, sload(calldataload(calldataptr)))
                memptr := add(memptr, 0x20)
                calldataptr := add(calldataptr, 0x20)
                if iszero(lt(memptr, end)) { break }
            }
            return(start, sub(end, start))
        }
    }
}

contract B {
    // slot 0
    uint256 internal slot0 = 100;
    // slot 1
    uint256 private slot1 = 200;

    // slot 2 (Packed variables)
    // [slot23 (16 bytes) | slot22 (8 bytes) | slot21 (8 bytes)]
    uint64 internal slot21 = 2; // 8 bytes
    uint64 internal slot22 = 3; // 8 bytes
    uint128 internal slot23 = 4; // 16 bytes
}

// Concrete implementation of your abstract Extsload contract for deployment
contract ExtsloadPoolManager is Extsload, B {
    // We inherit B directly here to simulate a Uniswap v4 style architecture
    // where the storage variables live inside the same contract that exposes extsload.
}

contract ExtsloadTest is Test {
    ExtsloadPoolManager poolManager;

    function setUp() external {
        // Deploy our integrated contract containing both Contract B's layout and the extsload implementation
        poolManager = new ExtsloadPoolManager();
    }

    /// @notice Test 1: Single slot read -> extsload(bytes32)
    function testReadSingleSlot() external view {
        // Read private slot 1 (value 200)
        bytes32 val1 = poolManager.extsload(bytes32(uint256(1)));

        assertEq(uint256(val1), 200);
        console2.log("Single Slot 1 (Private):", uint256(val1));
    }

    /// @notice Test 2: Sequential batch read -> extsload(bytes32, uint256)
    function testReadSequentialSlots() external view {
        bytes32 startSlot = bytes32(uint256(0));
        uint256 nSlots = 3; // Read slots 0, 1, and 2

        // Execute the range-bound loop version of your contract
        bytes32[] memory results = poolManager.extsload(startSlot, nSlots);

        assertEq(results.length, 3);
        assertEq(uint256(results[0]), 100); // slot0
        assertEq(uint256(results[1]), 200); // slot1

        console2.log("Batch Sequential Length:", results.length);
        console2.log("Slot 0 from Batch:", uint256(results[0]));
        console2.log("Slot 1 from Batch:", uint256(results[1]));
        console2.log("slot21: ", uint64(uint256(results[2]))); // Truncates higher bits, outputs 2
        console2.log("slot22: ", uint64(uint256(results[2]) >> 64)); // Shifts out slot21, truncates slot23, outputs 3
        console2.log("slot23: ", uint128(uint256(results[2]) >> 128)); // Shifts out both, outputs 4
    }

    /// @notice Test 3: Arbitrary slot array read -> extsload(bytes32[])
    function testReadArbitrarySlotsAndUnpack() external view {
        // Prepare specific slots to read (Skipping slot 1 completely)
        bytes32[] memory slotsToRead = new bytes32[](2);
        slotsToRead[0] = bytes32(uint256(0)); // slot0
        slotsToRead[1] = bytes32(uint256(2)); // slot2 (packed slot)

        // Execute the calldata array iteration version of your contract
        bytes32[] memory results = poolManager.extsload(slotsToRead);

        // Verify slot 0
        assertEq(uint256(results[0]), 100);

        // Unpack packed variables from slot 2 (results[1])
        bytes32 packedSlot = results[1];
        uint64 extractedSlot21 = uint64(uint256(packedSlot));
        uint64 extractedSlot22 = uint64(uint256(packedSlot) >> 64);
        uint128 extractedSlot23 = uint128(uint256(packedSlot) >> 128);

        assertEq(extractedSlot21, 2);
        assertEq(extractedSlot22, 3);
        assertEq(extractedSlot23, 4);

        console2.log("Unpacked slot21:", extractedSlot21);
        console2.log("Unpacked slot22:", extractedSlot22);
        console2.log("Unpacked slot23:", extractedSlot23);
    }
}
