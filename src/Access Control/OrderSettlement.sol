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

