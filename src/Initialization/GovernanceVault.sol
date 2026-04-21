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

        // we do not check the proposal threshold? is it right?
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

// BUG
// GovernanceVault inherits Initializable but has no constructor calling _disableInitializers(). The implementation contract 
// behind the proxy can be initialized directly by anyone.


// IMPACT
// An attacker initializes the implementation directly, sets themselves as governor, and can call `executeProposal` with arbitrary 
// calldata to execute arbitrary external calls from the implementation's context.

// INVARIANT
// The implementation contract behind a proxy must never be initializable independently.

// WHAT BREAKS
// An attacker calls initialize() directly on the implementation contract (not via proxy), setting themselves as governor. They 
// can then call executeProposal with arbitrary target and calldata, executing any external call from the implementation's 
// address context.

// EXPLOIT PATH
// 1. GovernanceVault implementation is deployed at 0xImpl. Proxy at 0xProxy delegates to 0xImpl
// 2. Proxy is initialized via initialize(govMultisig, treasury, govToken, 100e18)
// 3. Attacker calls 0xImpl.initialize(attackerAddr, attackerAddr, govToken, 0) directly on the implementation
// 4. Attacker is now governor on the implementation's storage
// 5. Attacker calls 0xImpl.executeProposal(1, targetContract, maliciousCalldata)
// 6. Arbitrary code execution from 0xImpl's context.

// WHY MISSED
// Auditors verify the proxy's initialization is correct but forget that the implementation contract itself has separate storage.
// The proxy's initializer modifier protects the proxy's storage but not the implementation's own storage.