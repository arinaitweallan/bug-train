// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Gauge Weight Underflow Blocks All Voting

/// @title GaugeVoting
contract GaugeVoting {
    mapping(address => uint256) public gaugeWeights;
    mapping(address => mapping(address => uint256)) public userVotes;
    mapping(address => uint256) public votingPower;

    uint256 public totalWeight;
    address public owner;
    address[] public gauges;

    event GaugeAdded(address indexed gauge);
    event GaugeRemoved(address indexed gauge);
    event Voted(address indexed user, address indexed gauge, uint256 weight);

    constructor() {
        owner = msg.sender;
    }

    /// @notice Add a new entry or allocation
    function addGauge(address gauge) external {
        require(msg.sender == owner, "Not owner");

        gauges.push(gauge);
        emit GaugeAdded(gauge);
    }

    /// @notice Configure a contract parameter
    /// @param user User address
    /// @param power Power value
    function setVotingPower(address user, uint256 power) external {
        require(msg.sender == owner, "Not owner");

        votingPower[user] = power;
    }

    /// @notice Cast a vote on a proposal
    /// @param gauge Gauge value
    /// @param weight Weight value
    function vote(address gauge, uint256 weight) external {
        require(weight <= votingPower[msg.sender], "Exceeds power");
        // q what if user enters weight == 0?

        uint256 oldVote = userVotes[msg.sender][gauge];
        gaugeWeights[gauge] = gaugeWeights[gauge] - oldVote + weight;
        totalWeight = totalWeight - oldVote + weight;
        userVotes[msg.sender][gauge] = weight;
        emit Voted(msg.sender, gauge, weight);
    }

    /// @notice Remove an existing entry
    function removeGauge(address gauge) external {
        require(msg.sender == owner, "Not owner");
        totalWeight -= gaugeWeights[gauge];
        gaugeWeights[gauge] = 0;
        emit GaugeRemoved(gauge);
    }

    /// @notice Get relative weight
    function getRelativeWeight(address gauge) external view returns (uint256) {
        if (totalWeight == 0) return 0;
        return (gaugeWeights[gauge] * 1e18) / totalWeight;
    }
}

// INVARIANT
// totalWeight must never underflow: the sum of all gauge weights must always be representable as a uint256

// WHAT BREAKS
// After removeGauge zeros gaugeWeights[gauge] and subtracts from totalWeight, users who voted on that gauge still have
// userVotes[user][gauge] = oldVote. When they call vote() for any gauge, line 33 computes totalWeight - oldVote, but
// totalWeight was already reduced by removeGauge. This underflows and reverts. The user is permanently unable to vote or
// change their votes.

// EXPLOIT PATH
// 1. User votes 100e18 on gaugeA: gaugeWeights[gaugeA] = 100e18, totalWeight = 100e18, userVotes[user][gaugeA] = 100e18
// 2. Owner calls removeGauge(gaugeA): totalWeight = 100e18 - 100e18 = 0, gaugeWeights[gaugeA] = 0
// 3. User calls vote(gaugeB, 50e18)
// 4. Line 31: gaugeWeights[gaugeB] = 0 - 0 + 50e18 = 50e18 (OK, oldVote for gaugeB is 0)
// 5. User calls vote(gaugeA, 0) to clear old vote
// 6. Line 33: totalWeight = 50e18 - 100e18 + 0. Underflow! 50e18 - 100e18 reverts
// 7. User can never clear their old gaugeA vote. Any interaction touching gaugeA's old vote reverts.

// WHY MISSED
// The vote formula looks correct for the normal add/remove weight case. The desync between totalWeight (reduced by removeGauge)
// and userVotes (not cleared by removeGauge) only manifests when a user interacts with a removed gauge, which is an uncommon
// operational sequence.
