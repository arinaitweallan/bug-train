// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title OrderSettlement
contract OrderSettlement {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    address public operator;

    mapping(address => uint256) public nonces;
    mapping(address => uint256) public balances;
    IERC20 public settlementToken;

    constructor(address _operator, address _token) {
        operator = _operator;
        settlementToken = IERC20(_token);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        settlementToken.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }

    /// @notice Settle a pending transaction
    /// @param user User address
    /// @param amount Token amount
    /// @param nonce Replay protection nonce
    /// @param signature Cryptographic signature
    function settleOrder(address user, uint256 amount, uint256 nonce, bytes memory signature) external {
        require(nonce == nonces[user], "Invalid nonce");
        bytes32 hash = keccak256(abi.encodePacked(user, amount, nonce));
        bytes32 ethHash = hash.toEthSignedMessageHash();
        require(ethHash.recover(signature) == user, "Bad sig");

        nonces[user]++;
        balances[user] -= amount;
        settlementToken.safeTransfer(operator, amount);
    }

    /// @notice Invalidate nonce
    function invalidateNonce(address user) external {
        nonces[user]++;
    }

    /// @notice Get user balance
    function getUserBalance(address user) external view returns (uint256) {
        return balances[user];
    }

    /// @notice Get user nonce
    function getUserNonce(address user) external view returns (uint256) {
        return nonces[user];
    }
}

// IMPACT
// settleOrder requires nonce == nonces[user]. By incrementing a victim's nonce, the attacker causes all of the victim's 
// pre-signed orders to fail with 'Invalid nonce'. This is a DoS on any user's pending settlements.

// BUG
// invalidateNonce is callable by anyone -- it takes an arbitrary user address and increments their nonce without any access 
// control. This allows an attacker to increment any user's nonce, invalidating all their pending signed orders.

// INVARIANT
// Only the nonce owner can invalidate their own nonce to cancel pending orders.

// WHAT BREAKS
// invalidateNonce accepts any user address and increments their nonce without verifying msg.sender == user. An attacker can 
// call invalidateNonce(victim) to advance the nonce, causing all of the victim's pre-signed orders (which reference the 
// previous nonce) to become invalid.

// EXPLOIT PATH
// 1. Alice deposits 50,000 USDC and signs 5 settlement orders with nonces 0-4
// 2. Operator begins processing: settles nonce 0 (succeeds, nonces[Alice] = 1)
// 3. Attacker calls invalidateNonce(Alice) -- nonces[Alice] becomes 2
// 4. Operator tries to settle Alice's order at nonce 1 -- reverts: 'Invalid nonce' (expected 2, got 1)
// 5. Alice's orders 1, 2, 3, 4 are all now misaligned. Order 2 would need nonce=2 but was signed with nonce=2, which might work, but orders 1, 3, 4 are permanently invalid
// 6. Attacker repeatedly calls invalidateNonce(Alice) to keep advancing the nonce beyond all signed orders
// 7. Alice must re-sign all orders, but attacker can grief again. Permanent DoS.

// WHY MISSED
// Auditors recognize invalidateNonce as a cancel mechanism and verify it correctly increments the nonce. The missing access 
// control check is subtle because the function name implies it is a user action, and the pattern of 'nonce invalidation for 
// cancellation' is well-known. The oversight is that the function does not restrict WHO can cancel WHOSE nonces.
