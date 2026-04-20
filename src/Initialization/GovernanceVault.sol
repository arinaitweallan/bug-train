// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GovernanceVault
contract GovernanceVault is Initializable {
    using SafeERC20 for IERC20;

    address public governor;
    address public treasury;
    IERC20 public govToken;

    uint256 public proposalThreshold;
    
    mapping(uint256 => bool) public executedProposals;
    uint256 public proposalCount;

    /// @notice Initialize contract state
    /// @param _governor Governor value
    /// @param _treasury Treasury value
    /// @param _token Token contract address
    /// @param _threshold Threshold value
    function initialize(address _governor, address _treasury, address _token, uint256 _threshold) external initializer {
        governor = _governor;
        treasury = _treasury;
        govToken = IERC20(_token);
        proposalThreshold = _threshold;
    }
    modifier onlyGovernor() {
        require(msg.sender == governor, "Not governor");
        _;
    }

    /// @notice Execute an approved proposal
    /// @param proposalId Governance proposal identifier
    /// @param target Target address
    /// @param data Encoded call data
    function executeProposal(uint256 proposalId, address target, bytes calldata data) external onlyGovernor {
        require(!executedProposals[proposalId], "Already executed");
        executedProposals[proposalId] = true;
        proposalCount++;
        (bool success,) = target.call(data);
        require(success, "Execution failed");
    }

    /// @notice Update contract parameters
    function updateGovernor(address _newGovernor) external onlyGovernor {
        require(_newGovernor != address(0), "Zero address");
        governor = _newGovernor;
    }

    /// @notice Update contract parameters
    function updateTreasury(address _newTreasury) external onlyGovernor {
        require(_newTreasury != address(0), "Zero address");
        treasury = _newTreasury;
    }

    /// @notice Withdraw tokens from the contract
    /// @param token Token contract address
    /// @param amount Token amount
    function withdrawTreasury(address token, uint256 amount) external onlyGovernor {
        IERC20(token).safeTransfer(treasury, amount);
    }

    /// @notice Get proposal count
    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }

    /// @notice Get treasury balance
    function getTreasuryBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
