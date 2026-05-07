// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Unbounded Calldata Payload Exhausts Bridge Verifier Memory

/// @title MessageVerifier
contract MessageVerifier {
    address public relayer;

    mapping(bytes32 => bool) public verified;

    uint256 public totalVerified;
    uint256 public totalExecuted;

    struct Message {
        address sender;
        address target;
        bytes payload;
        uint256 nonce;
    }

    event BatchVerified(uint256 count);
    event MessageExecuted(bytes32 indexed hash, address target, bool success);

    constructor(address _relayer) {
        relayer = _relayer;
    }

    /// @notice Verify a proof or signature
    /// @param messages Messages value
    /// @param signatures Signatures value
    function verifyBatch(Message[] calldata messages, bytes[] calldata signatures) external {
        require(msg.sender == relayer, "Not relayer");
        require(messages.length == signatures.length, "Length mismatch");
        bytes32[] memory hashes = new bytes32[](messages.length);
        for (uint256 i = 0; i < messages.length; i++) {
            hashes[i] =
                keccak256(abi.encode(messages[i].sender, messages[i].target, messages[i].payload, messages[i].nonce));
            verified[hashes[i]] = true;
        }
        totalVerified += messages.length;
        emit BatchVerified(messages.length);
    }

    /// @notice Execute an approved proposal
    /// @param messageHash Hash of the message
    /// @param target Target address
    /// @param data Encoded call data
    function executeVerified(bytes32 messageHash, address target, bytes calldata data) external {
        require(verified[messageHash], "Not verified");
        verified[messageHash] = false;
        totalExecuted++;
        (bool success,) = target.call(data);
        require(success, "Execution failed");
        emit MessageExecuted(messageHash, target, success);
    }

    /// @notice Is verified
    function isVerified(bytes32 hash) external view returns (bool) {
        return verified[hash];
    }
}

// INVARIANT
// Batch verification must enforce a maximum batch size to guarantee completion within gas limits

// WHAT BREAKS
// The relayer submits a batch with 1,000 messages, each containing a 10KB payload. The keccak256 of each large payload consumes
// significant gas (6 gas per word + memory expansion). The memory array hashes alone is 1,000 * 32 = 32KB. Total gas for
// hashing 1,000 * 10KB = 10MB of data far exceeds the block gas limit. The verifyBatch transaction always reverts for large
// batches, blocking all message verification.

// EXPLOIT PATH
// 1. Relayer key is compromised (or relayer is malicious)
// 2. Attacker calls verifyBatch with 500 messages, each with payload = bytes(50_000 random bytes)
// 3. Line 22: new bytes32[](500) allocates 16KB of memory
// 4. Loop hashes 500 * 50KB = 25MB of payload data. keccak256 gas: ~6 gas/word * 25MB/32 = ~4.7M gas just for hashing
// 5. Memory expansion for calldata decoding + hash array exceeds 30M gas limit
// 6. Transaction reverts. No messages are verified
// 7. Legitimate messages in the same batch are blocked. If the relayer always submits bloated batches, the bridge is permanently DoS'd.

// WHY MISSED
// Auditors focus on signature verification correctness rather than resource consumption. The batch processing pattern looks
// standard, and the unbounded nature of Message.payload is easy to overlook when reviewing the struct definition separately
// from the loop.
