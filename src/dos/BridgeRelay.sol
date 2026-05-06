// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Return Data Bomb OOGs Cross-Chain Bridge Relay

/// @title BridgeRelay
contract BridgeRelay {
    address public admin;

    mapping(bytes32 => bool) public processedMessages;
    mapping(address => uint256) public deposits;

    uint256 public totalRelayed;

    event MessageRelayed(bytes32 indexed messageId, address target, bool success);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    constructor() {
        admin = msg.sender;
    }

    /// @notice Deposit tokens into the contract
    function deposit() external payable {
        require(msg.value > 0, "Must deposit > 0");

        deposits[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Relay a cross-chain message
    /// @param messageId Message id value
    /// @param target Target address
    /// @param value Ether or token value
    /// @param data Encoded call data
    function relayMessage(bytes32 messageId, address target, uint256 value, bytes calldata data) external {
        require(msg.sender == admin, "Not admin");
        require(!processedMessages[messageId], "Already processed");
        require(address(this).balance >= value, "Insufficient balance");

        processedMessages[messageId] = true;
        totalRelayed++;

        (bool success, bytes memory returnData) = target.call{value: value}(data);

        emit MessageRelayed(messageId, target, success);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    /// @notice Withdraw tokens from the contract
    /// @param to Recipient address
    /// @param amount Token amount
    function withdrawDeposits(address to, uint256 amount) external {
        require(msg.sender == admin, "Not admin");
        require(deposits[to] >= amount, "Insufficient");

        deposits[to] -= amount;
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "Transfer failed");

        emit Withdrawn(to, amount);
    }

    /// @notice Is processed
    function isProcessed(bytes32 messageId) external view returns (bool) {
        return processedMessages[messageId];
    }
}

// INVARIANT
// Bridge message relay must succeed regardless of the target contract's return behavior

// WHAT BREAKS
// A malicious target contract returns a massive payload (e.g., 100KB). Solidity copies the entire returnData into memory at
// line 30. Memory expansion from 0 to 100KB costs approximately 10 million gas. The relay transaction runs out of gas and
// reverts. The messageId is not marked processed (state reverted), but the relay admin's gas budget is wasted. Repeated
// attempts all fail.

// EXPLOIT PATH
// 1. Attacker deploys a contract at targetAddr whose fallback returns 100,000 bytes of data
// 2. A cross-chain message arrives with target = targetAddr
// 3. Admin calls relayMessage(msgId, targetAddr, 1 ether, '0x')
// 4. Line 30: target.call returns (true, 100KB_of_data)
// 5. Solidity copies 100KB into memory. Memory expansion cost: ~10M gas
// 6. Transaction runs out of gas (relay typically given 500K-1M gas)
// 7. Entire transaction reverts, processedMessages[messageId] is not set
// 8. Message cannot be relayed; bridged funds are stuck.

// WHY MISSED
// Auditors focus on whether the call succeeds or fails, not on the size of the return data. The returndata bomb attack is a
// gas-level exploit that does not appear in the control flow, making it invisible to high-level logic review.
