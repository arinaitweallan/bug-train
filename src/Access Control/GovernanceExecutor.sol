// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title GovernanceExecutor
contract GovernanceExecutor {
    address public governor;
    address public guardian;

    mapping(bytes32 => bool) public executedProposals;
    mapping(address => bool) public approvedModules;

    modifier onlyGovernor() {
        require(msg.sender == governor, "Not governor");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "Not guardian");
        _;
    }

    constructor(address _guardian) {
        governor = msg.sender;
        guardian = _guardian;
    }

    /// @notice Approve spending allowance
    function approveModule(address module) external onlyGovernor {
        require(module != address(0), "Zero address");
        approvedModules[module] = true;
    }

    /// @notice Revoke a previous authorization
    function revokeModule(address module) external onlyGovernor {
        approvedModules[module] = false;
    }

    /// @notice Execute an approved proposal
    /// @param proposalId Governance proposal identifier
    /// @param target Target address
    /// @param data Encoded call data
    function executeProposal(bytes32 proposalId, address target, bytes calldata data) external onlyGovernor {
        require(!executedProposals[proposalId], "Already executed");

        executedProposals[proposalId] = true;
        (bool success,) = target.call(data);
        require(success, "Execution failed");
    }

    /// @notice Execute an approved proposal
    /// @param module Module value
    /// @param data Encoded call data
    function executeModuleAction(address module, bytes calldata data) external {
        require(approvedModules[module], "Module not approved");
        (bool success,) = module.delegatecall(data);
        require(success, "Module action failed");
    }

    /// @notice Execute emergency action
    function emergencyPause() external onlyGuardian {
        governor = address(0);
    }

    /// @notice Get module status
    function getModuleStatus(address module) external view returns (bool) {
        return approvedModules[module];
    }
}

// BUG
// executeModuleAction is callable by anyone (no access control modifier). While it checks approvedModules[module], the
// delegatecall itself executes arbitrary code in the executor's storage context.

// IMPACT
// An approved module can contain a function that overwrites governor or guardian via delegatecall. Since anyone can
// trigger this, an attacker who gets a module approved (or finds a fallback function in an existing one) can hijack
// governance by overwriting storage slot 0 (governor).

// INVARIANT
// Only the governor should be able to trigger execution of module actions, and delegatecall targets must not be able to
// modify critical governance state.

// WHAT BREAKS
// executeModuleAction has no access control and uses delegatecall, meaning the called module code runs in the executor's
// storage context. An attacker who can interact with an approved module (or get one approved via social engineering) can
// craft a call that overwrites the governor storage slot, taking full control of governance.

// EXPLOIT PATH
// 1. GovernanceExecutor has governor = 0xGov, guardian = 0xGuard. Module 0xApproved is approved
// 2. 0xApproved has a function updateConfig(address) that writes to storage slot 0
// 3. Attacker calls executeModuleAction(0xApproved, abi.encodeWithSignature('updateConfig(address)', attackerAddr))
// 4. delegatecall executes in executor's context. Storage slot 0 (governor) is overwritten with attackerAddr
// 5. Attacker is now governor. Calls executeProposal to drain any funds or change any state
// 6. Attack cost: one transaction, no special permissions needed.

// WHY MISSED
// The approvedModules check creates a false sense of safety. Auditors see that only pre-approved modules can be called and
// assume this is sufficient. The deeper issue is that delegatecall gives the module code unrestricted write access to the
// executor's storage, and the missing access control on executeModuleAction means anyone can trigger this.
