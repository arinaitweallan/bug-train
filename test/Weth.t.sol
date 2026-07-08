// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

// Minimal interface for WETH
interface IWETH {
    function transferFrom(address src, address dst, uint256 wad) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract WethQuirksTest is Test {
    // The actual WETH9 contract address on Ethereum Mainnet
    IWETH constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {
        // Fork Ethereum mainnet to interact with the real WETH contract
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("wss://eth.drpc.org"));
        vm.createSelectFork(rpcUrl);
    }

    // =========================================================================
    // PROOF 1: The Calldata Short-Pading ("Cripple") Edge Case
    // =========================================================================
    function test_weth_short_calldata_padding() public {
        // 4-byte selector for transferFrom(address,address,uint256)
        bytes memory shortCalldata = hex"23b872dd";

        // We make a low-level call with ONLY the 4-byte selector
        (bool success, bytes memory data) = address(weth).call(shortCalldata);

        // The old compiler doesn't revert! It pads with zeros and executes successfully.
        assertTrue(success, "WETH should not revert on truncated calldata");

        // It returns 'true' (encoded as 32 bytes) indicating a successful transfer of 0 tokens
        bool returnedValue = abi.decode(data, (bool));
        assertTrue(returnedValue, "WETH should return true for transferFrom(0,0,0)");
    }

    // =========================================================================
    // PROOF 2: The Gas Stipend Edge Case (0 gas vs 2300 gas)
    // =========================================================================
    function test_gas_stipend_quirk() public {
        GasReceiver receiver = new GasReceiver();

        // SCENARIO A: Call with 0 value, specifying exactly 2000 gas.
        // It will fail because 2000 gas isn't enough for the receiver's operations.
        (bool successNoValue,) = address(receiver).call{gas: 2000, value: 0}("");
        assertFalse(successNoValue, "Should fail: 2000 gas is not enough");

        // SCENARIO B: Call with 1 wei value, specifying the exact same 2000 gas.
        // It succeeds! Why? Because the EVM secretly injected 2300 extra gas,
        // bringing the total relayed gas to 4300.
        (bool successWithValue,) = address(receiver).call{gas: 2000, value: 1 wei}("");
        assertTrue(successWithValue, "Should succeed: EVM added 2300 gas stipend!");
        assertEq(receiver.dummy(), 1);
    }
}

// A simple contract used to measure incoming gas limits
contract GasReceiver {
    uint256 public dummy;

    // This fallback runs when the contract receives a call/value
    fallback() external payable {
        // We do just enough work to consume more than 2000 gas,
        // but less than 4300 gas.
        dummy = 1;
    }
}
