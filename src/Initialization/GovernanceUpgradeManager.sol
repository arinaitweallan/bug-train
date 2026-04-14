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
