// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Front-Run Proposal ID Occupation Blocks Governance

/// @title GovernorSimple
contract GovernorSimple {
    struct Proposal {
        address proposer;
        string description;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 deadline;
        bool executed;
    }

    mapping(bytes32 => Proposal) public proposals;
    mapping(address => uint256) public votingPower;
    mapping(bytes32 => mapping(address => bool)) public hasVoted;

    uint256 public constant VOTING_PERIOD = 3 days;
    uint256 public constant MIN_POWER = 100e18;

    /// @notice Delegate voting power
    function delegate(address to) external payable {
        votingPower[to] += msg.value;
    }

    /// @notice Create a new governance proposal
    function propose(string calldata description) external returns (bytes32) {
        require(votingPower[msg.sender] >= MIN_POWER, "Insufficient power");

        bytes32 proposalId = keccak256(abi.encodePacked(description));
        require(proposals[proposalId].deadline == 0, "Proposal exists");

        proposals[proposalId] = Proposal(msg.sender, description, 0, 0, block.timestamp + VOTING_PERIOD, false);
        return proposalId;
    }

    /// @notice Cast a vote on a proposal
    /// @param proposalId Governance proposal identifier
    /// @param support Vote direction
    function vote(bytes32 proposalId, bool support) external {
        Proposal storage p = proposals[proposalId];
        require(p.deadline > 0, "No proposal");
        require(block.timestamp < p.deadline, "Voting ended");
        require(!hasVoted[proposalId][msg.sender], "Already voted");

        uint256 power = votingPower[msg.sender];
        require(power > 0, "No voting power");

        hasVoted[proposalId][msg.sender] = true;
        if (support) p.forVotes += power;
        else p.againstVotes += power;
    }

    /// @notice Execute an approved proposal
    function execute(bytes32 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp >= p.deadline, "Voting not ended");
        require(!p.executed, "Already executed");
        require(p.forVotes > p.againstVotes, "Not passed");

        p.executed = true;
    }
}

// INVARIANT
// Legitimate proposers must be able to create proposals without interference from front-runners

// WHAT BREAKS
// An attacker monitors the mempool for propose() transactions. When they see one, they extract the description from calldata,
// compute the same proposalId, and submit their own propose() with higher gas. The attacker's transaction lands first,
// occupying the proposalId slot. The legitimate proposer's transaction reverts at line 26 because
// proposals[proposalId].deadline != 0.

// EXPLOIT PATH
// 1. Legitimate proposer submits propose('Increase treasury allocation to 5%') to mempool
// 2. Attacker sees the pending tx, extracts the description string from calldata
// 3. Attacker computes proposalId = keccak256('Increase treasury allocation to 5%')
// 4. Attacker sends propose('Increase treasury allocation to 5%') with higher gas price
// 5. Attacker's tx lands in block first. proposals[proposalId].deadline is now set
// 6. Legitimate proposer's tx executes: require(proposals[proposalId].deadline == 0) at line 26 fails
// 7. Proposer must change description text each attempt. Attacker repeats indefinitely at minimal cost (100 ETH staked once).

// WHY MISSED
// The keccak256(description) derivation looks deterministic and clean. Auditors may focus on voting logic and execution rather
// than the proposal creation path, missing that the predictable ID enables mempool-based front-running.
