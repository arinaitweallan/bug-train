// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Hardcoded Gas Stipend Fails on Cold Storage Callback

/// @title SafeCallRelay
contract SafeCallRelay {
    address public operator;

    mapping(bytes32 => bool) public executed;
    mapping(address => uint256) public balances;

    uint256 public totalRelayed;
    uint256 public constant CALLBACK_GAS = 50_000;

    event Relayed(bytes32 indexed taskId, address target, bool success);
    event DepositReceived(address indexed user, uint256 amount);
    event BalanceWithdrawn(address indexed user, uint256 amount);

    constructor() {
        operator = msg.sender;
    }

    /// @notice Deposit tokens into the contract
    function depositFor(address user) external payable {
        require(msg.value > 0, "Must send ETH");

        balances[user] += msg.value;

        emit DepositReceived(user, msg.value);
    }

    /// @notice Relay a cross-chain message
    /// @param taskId Task id value
    /// @param target Target address
    /// @param data Encoded call data
    /// @param value Ether or token value
    function relay(bytes32 taskId, address target, bytes calldata data, uint256 value) external {
        require(msg.sender == operator, "Not operator");
        require(!executed[taskId], "Already executed");
        require(address(this).balance >= value, "Insufficient balance");

        executed[taskId] = true;
        totalRelayed++;

        (bool success,) = target.call{value: value, gas: CALLBACK_GAS}(data);
        require(success, "Relay failed");
        // @check: when the gas stipend is limited, calculate the gas neede for the execution of
        // the transaction and check if the stipend is enough

        emit Relayed(taskId, target, success);
    }

    /// @notice Withdraw tokens from the contract
    function withdrawBalance() external {
        uint256 amount = balances[msg.sender];
        require(amount > 0, "No balance");

        balances[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "Transfer failed");
        emit BalanceWithdrawn(msg.sender, amount);
    }

    /// @notice Get balance
    function getBalance(address user) external view returns (uint256) {
        return balances[user];
    }

    /// @notice Is executed
    function isExecuted(bytes32 taskId) external view returns (bool) {
        return executed[taskId];
    }
}

// INVARIANT
// Relayed calls must be forwarded with sufficient gas to complete the target function's worst-case execution path

// WHAT BREAKS
// A target contract's callback function requires: 1 cold SSTORE (22,100) + 1 cold SLOAD (2,100) + 1 ETH transfer
// (2,300 + 9,000 for non-zero to non-zero) + base overhead (~5,000) = ~40,500 gas minimum. With calldata decoding and function
// dispatch overhead, the actual cost reaches ~55,000-60,000 gas. The 50,000 gas cap causes an out-of-gas revert inside the
// target. require(success) at line 30 reverts the entire relay. Since executed[taskId] is reverted too, the task can be
// retried -- but it will always fail with the same gas limit.

// EXPLOIT PATH
// 1. Operator relays taskId = 0x123 to target contract that processes a payment (1 SSTORE for balance update + 1 SSTORE for status + 1 ETH transfer)
// 2. relay(0x123, target, data, 1 ether) executes
// 3. target.call{value: 1 ether, gas: 50_000}(data) at line 29 forwards only 50,000 gas
// 4. Target executes: SSTORE #1 (22,100 cold) + SSTORE #2 (22,100 cold) = 44,200 for storage alone. With function dispatch (~2,600) and other opcodes, total exceeds 50,000
// 5. Target runs out of gas. success = false
// 6. require(success) reverts. executed[taskId] is rolled back
// 7. Every retry attempt fails identically. The task is permanently unexecutable. Funds allocated for this task are stuck.

// WHY MISSED
// The 50,000 gas constant looks reasonable for simple transfers. Auditors testing with warm storage (where SSTORE costs only
//     5,000) see the call succeed. In production with cold storage access, the actual cost is 4x higher, but this is only
//     observable in fresh-state deployments.
