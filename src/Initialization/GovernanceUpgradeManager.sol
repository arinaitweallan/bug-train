// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title GovernanceUpgradeManager
contract GovernanceUpgradeManager is Initializable {
    address public admin;
    address public proposer;
    uint256 public votingDelay;
    uint256 public votingPeriod;
    uint256 public quorumThreshold;
    bool public emergencyMode;

    /// @notice Initialize contract state
    /// @param _admin Admin value
    /// @param _delay Delay value
    /// @param _period Period value
    function initialize(address _admin, uint256 _delay, uint256 _period) external initializer {
        // e with the initializer, it is initialized during deployment
        admin = _admin;
        votingDelay = _delay;
        votingPeriod = _period;
        quorumThreshold = 4000; // constant set during initialization
    }

    /// @notice Initialize contract state
    /// @param _proposer Proposer value
    /// @param _quorum Quorum value
    /// @param _emergency Emergency value
    function initializeV3(address _proposer, uint256 _quorum, bool _emergency) external reinitializer(3) {
        proposer = _proposer;
        quorumThreshold = _quorum;
        emergencyMode = _emergency;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    /// @notice Configure a contract parameter
    function setVotingDelay(uint256 _delay) external onlyAdmin {
        votingDelay = _delay;
    }

    /// @notice Configure a contract parameter
    function setVotingPeriod(uint256 _period) external onlyAdmin {
        votingPeriod = _period;
    }

    /// @notice Configure a contract parameter
    function setQuorum(uint256 _quorum) external onlyAdmin {
        require(_quorum > 0 && _quorum <= 10000, "Invalid");
        quorumThreshold = _quorum;
    }

    /// @notice Toggle emergency
    function toggleEmergency() external onlyAdmin {
        emergencyMode = !emergencyMode;
    }

    /// @notice Get governance params
    function getGovernanceParams() external view returns (uint256, uint256, uint256) {
        return (votingDelay, votingPeriod, quorumThreshold);
    }
}

// INVARIANT
// Reinitializer versions must increment sequentially (1, 2, 3...) with no gaps, ensuring every migration step executes 
// exactly once.

// WHAT BREAKS
// The contract jumps from reinitializer version 1 to version 3, skipping version 2. If a V2 migration was planned 
// (e.g., migrating from an old quorum format), it never runs. Additionally, the skipped version creates a gap that 
// could be exploited if a future implementation adds reinitializer(2) logic, which would unexpectedly be callable 
// since version 2 was never consumed.

// EXPLOIT PATH
// 1. GovernanceUpgradeManager deployed with initialize(admin, 1 days, 3 days). Version set to 1
// 2. Upgrade to V3 implementation. initializeV3(proposer, 5000, false) called. Version set to 3
// 3. V2 migration (intended to convert quorumThreshold from absolute to percentage) never ran
// 4. quorumThreshold was set to 4000 (absolute votes) in V1, then overwritten to 5000 in V3, but the system now interprets it as a percentage (50%)
// 5. Governance proposals require 50% quorum instead of the intended 5000 absolute votes
// 6. A small holder group passes malicious proposals that should not have met quorum.
