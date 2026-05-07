// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Dust Deposit Front-Run Extends Escrow Expiry Indefinitely

/// @title PaymentEscrow
contract PaymentEscrow {
    struct Escrow {
        address depositor;
        address recipient;
        uint256 amount;
        uint256 expiry;
        bool claimed;
    }

    mapping(uint256 => Escrow) public escrows;

    uint256 public nextId;
    uint256 public constant LOCK_PERIOD = 7 days;

    /// @notice Create a new entry or position
    function createEscrow(address recipient) external payable {
        require(msg.value > 0, "Must deposit ETH");

        escrows[nextId] = Escrow(msg.sender, recipient, msg.value, block.timestamp + LOCK_PERIOD, false);
        nextId++;
    }

    /// @notice Top up
    function topUp(uint256 escrowId) external payable {
        Escrow storage e = escrows[escrowId];
        require(!e.claimed, "Already claimed");
        require(msg.value > 0, "Must send ETH");

        e.amount += msg.value;
        e.expiry = block.timestamp + LOCK_PERIOD;
    }

    /// @notice Claim accumulated rewards
    function claim(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        require(msg.sender == e.recipient, "Not recipient");
        require(block.timestamp >= e.expiry, "Not expired");
        require(!e.claimed, "Already claimed");

        e.claimed = true;
        (bool ok,) = payable(e.recipient).call{value: e.amount}("");
        require(ok, "Transfer failed");
    }

    /// @notice Refund
    function refund(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        require(msg.sender == e.depositor, "Not depositor");
        require(block.timestamp >= e.expiry + 30 days, "Refund period not reached");
        require(!e.claimed, "Already claimed");

        e.claimed = true;
        (bool ok,) = payable(e.depositor).call{value: e.amount}("");
        require(ok, "Transfer failed");
    }
}

// INVARIANT
// A recipient must be able to claim their escrow within a bounded time after the original deposit

// WHAT BREAKS
// Any third party can call topUp(escrowId) with 1 wei to reset the escrow's expiry to block.timestamp + 7 days. By calling
// topUp once every 6 days, the attacker keeps the expiry perpetually in the future. The recipient can never satisfy the
// block.timestamp >= e.expiry check in claim().

// EXPLOIT PATH
// 1. Depositor creates escrow #0 with 10 ETH for recipient, expiry = now + 7 days
// 2. At day 6, attacker calls topUp(0) with msg.value = 1 wei
// 3. Line 27: e.expiry = block.timestamp + 7 days (reset to day 13)
// 4. Attacker repeats every 6 days: topUp(0) with 1 wei
// 5. Cost to attacker: 1 wei per week (~0.000000000000000001 ETH)
// 6. Recipient's claim() always reverts at line 33 because expiry is perpetually 7 days in the future
// 7. 10 ETH is locked indefinitely for negligible attacker cost.

// WHY MISSED
// topUp looks like a helpful feature to add funds. The expiry reset seems natural for a top-up operation. Auditors may not
// consider that the lack of access control on topUp turns the expiry reset into a griefing weapon.
