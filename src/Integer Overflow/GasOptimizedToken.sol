// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title GasOptimizedToken
contract GasOptimizedToken {
    string public name = "GasToken";
    string public symbol = "GAS";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(uint256 initialSupply) {
        balanceOf[msg.sender] = initialSupply;
        totalSupply = initialSupply;
    }

    /// @notice Transfer tokens to recipient
    /// @param to Recipient address
    /// @param amount Token amount
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");

        assembly {
            let fromSlot := keccak256(0x00, 0x40)
            mstore(0x00, to)

            let toSlot := keccak256(0x00, 0x40)
            let fromBal := sload(fromSlot)
            let toBal := sload(toSlot)

            sstore(fromSlot, sub(fromBal, amount))
            sstore(toSlot, add(toBal, amount))
        }

        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Approve spending allowance
    /// @param spender Approved spender address
    /// @param amount Token amount
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @notice Transfer tokens to recipient
    /// @param from Source address
    /// @param to Recipient address
    /// @param amount Token amount
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Allowance");
        require(balanceOf[from] >= amount, "Insufficient");
        allowance[from][msg.sender] -= amount;

        assembly {
            mstore(0x00, from)
            let fromSlot := keccak256(0x00, 0x40)

            mstore(0x00, to)

            let toSlot := keccak256(0x00, 0x40)
            let fromBal := sload(fromSlot)
            let toBal := sload(toSlot)

            sstore(fromSlot, sub(fromBal, amount))
            sstore(toSlot, add(toBal, amount))
        }

        emit Transfer(from, to, amount);
        return true;
    }
}

// IMPACT
// The add(toBal, amount) in assembly has no overflow check. If toBal + amount exceeds 2^256, it wraps silently. An attacker
// with 2^255 tokens can receive another 2^255 tokens, wrapping their balance to 0 or an arbitrary value. Even without wrap,
// incorrect slot computation means balances are written to wrong storage, corrupting contract state.

// BUG
// The assembly block computes storage slots manually via keccak256, but the slot computation is WRONG. The Solidity mapping
// layout uses keccak256(key . slot_number), but the assembly block does not correctly set up the memory layout for the mapping
// key and slot number. The computed fromSlot and toSlot may not correspond to the actual balanceOf mapping slots, causing
// reads/writes to incorrect storage locations.

// INVARIANT
// The sum of all balances must equal totalSupply. No balance should wrap around during transfers.

// WHAT BREAKS
// Assembly add() and sub() do not have overflow/underflow checks. While the Solidity require on line 21 checks the sender's
// balance, the actual storage operations in assembly may compute incorrect slots and perform unchecked arithmetic that wraps
// on overflow.

// EXPLOIT PATH
// 1. The assembly slot computation is incorrect -- it does not match Solidity's mapping layout
// 2. Even if slots were correct: user A has balance = type(uint256).max - 10
// 3. User B transfers 20 tokens to A. Solidity check passes (B has >= 20)
// 4. Assembly: add(type(uint256).max - 10, 20) = 9 (wrapped). A's balance drops from near-max to 9
// 5. 20 tokens vanished from the total supply accounting
// 6. Alternatively: incorrect slot means transfers write to arbitrary storage, corrupting other state variables.

// WHY MISSED
// Gas-optimized assembly implementations are common in production tokens. Auditors may trust that the balance check before the
// assembly block is sufficient, not realizing that assembly arithmetic bypasses Solidity 0.8 overflow protection.

