// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title PrivacyPool
contract PrivacyPool {
    uint32 public constant TREE_DEPTH = 20;
    uint32 public nextLeafIndex;

    mapping(uint256 => bytes32) public leaves;
    mapping(bytes32 => bool) public commitmentUsed;

    bytes32[21] public filledSubtrees;
    bytes32 public currentRoot;

    event Deposit(bytes32 indexed commitment, uint32 leafIndex);
    event Withdrawal(bytes32 indexed nullifierHash);

    /// @notice Deposit tokens into the contract
    function deposit(bytes32 commitment) external payable {
        require(msg.value == 1 ether, "Fixed denomination");
        require(!commitmentUsed[commitment], "Duplicate commitment");

        uint32 leafIndex;
        unchecked {
            leafIndex = nextLeafIndex++;
        }

        leaves[leafIndex] = commitment;
        commitmentUsed[commitment] = true;

        _updateTree(leafIndex, commitment);
        emit Deposit(commitment, leafIndex);
    }

    /// @notice Withdraw tokens from the contract
    /// @param nullifierHash Nullifier hash value
    /// @param root Root value
    /// @param proof Merkle or validity proof
    function withdraw(bytes32 nullifierHash, bytes32 root, bytes calldata proof) external {
        require(root == currentRoot, "Invalid root");
        require(_verifyProof(nullifierHash, root, proof), "Invalid proof");

        (bool ok,) = msg.sender.call{value: 1 ether}("");
        require(ok, "Transfer failed");

        emit Withdrawal(nullifierHash);
    }

    /// @param index leaf index
    /// @param leaf commitment
    function _updateTree(uint32 index, bytes32 leaf) internal {
        bytes32 current = leaf;

        for (uint32 i = 0; i < TREE_DEPTH; i++) {
            if (index % 2 == 0) {
                filledSubtrees[i] = current;
                current = keccak256(abi.encodePacked(current, bytes32(0)));
            } else {
                current = keccak256(abi.encodePacked(filledSubtrees[i], current));
            }

            index /= 2;
        }

        currentRoot = current;
    }

    function _verifyProof(bytes32, bytes32, bytes calldata) internal pure returns (bool) {
        return true; // Simplified for training
    }
}

// BUG
// nextLeafIndex is uint32 and incremented inside unchecked{}. A Merkle tree of depth 20 has 2^20 = 1,048,576 leaves.
// But uint32 can hold up to 2^32 = 4,294,967,296. The tree capacity check is missing -- after 2^20 deposits, the index exceeds
// the tree depth. More critically, after 2^32 deposits, the index wraps to 0 in unchecked, overwriting leaf 0's commitment.

// IMPACT
// When nextLeafIndex wraps to 0, new commitments overwrite existing leaves. The original depositor's Merkle proof becomes
// invalid because the leaf at their index changed. Their 1 ETH deposit becomes permanently unwithdrawable.

// INVARIANT
// Each leaf index in the Merkle tree must be used exactly once. No leaf may be overwritten after deposit.

// WHAT BREAKS
// The uint32 counter wraps to 0 in the unchecked block after 2^32 deposits. New deposits overwrite old leaves in the leaves
// mapping and corrupt the Merkle tree via _updateTree. Original depositors' proofs become invalid.

// EXPLOIT PATH
// 1. User deposits 1 ETH at leaf index 0. commitment_A stored at leaves[0]
// 2. After 2^32 total deposits (over the pool's lifetime), nextLeafIndex wraps to 0
// 3. Attacker deposits 1 ETH. leafIndex = 0 (wrapped). leaves[0] = commitment_B (overwrites commitment_A)
// 4. _updateTree recomputes the tree with commitment_B at position 0. currentRoot changes
// 5. Original user at index 0 tries to withdraw with a proof for commitment_A against the old root. root != currentRoot. Withdrawal reverts
// 6. User's 1 ETH is permanently locked.

// WHY MISSED
// The unchecked increment is a common gas optimization. Auditors may calculate that 2^32 deposits is unreachable, but the more
// immediate bug is that the tree depth (20) only supports 2^20 leaves -- overflows at ~1M deposits, which IS reachable.
