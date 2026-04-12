// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title WalletRegistry
contract WalletRegistry {
    using SafeERC20 for IERC20;

    struct UserWallet {
        address owner;
        address guardian;
        uint256 dailyLimit;
        uint256 spentToday;
        uint256 lastResetDay;
    }

    IERC20 public token;
    address public admin;

    mapping(address => UserWallet) public wallets;

    constructor(address _token) {
        token = IERC20(_token);
        admin = msg.sender;
    }

    /// @notice Init or reset wallet
    /// @param user User address
    /// @param guardian Guardian address
    /// @param limit Limit value
    function initOrResetWallet(address user, address guardian, uint256 limit) external {
        UserWallet storage w = wallets[user];

        w.owner = user;
        w.guardian = guardian;
        w.dailyLimit = limit; // this is the daily spending limit amount
        w.spentToday = 0;
        w.lastResetDay = block.timestamp / 1 days;
    }

    /// @notice Spend
    function spend(uint256 amount) external {
        UserWallet storage w = wallets[msg.sender];
        require(w.owner == msg.sender, "Not wallet owner");

        // today = 20_000
        // w.lastResetDay = 20_000 - 2
        uint256 today = block.timestamp / 1 days;
        if (today > w.lastResetDay) {
            w.spentToday = 0;
            w.lastResetDay = today;
        }

        require(w.spentToday + amount <= w.dailyLimit, "Exceeds limit");
        w.spentToday += amount;
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice Deposit tokens into the contract
    function depositToWallet(uint256 amount) external {
        require(wallets[msg.sender].owner == msg.sender, "No wallet");
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Get wallet info
    function getWalletInfo(address user) external view returns (address, address, uint256) {
        UserWallet storage w = wallets[user];
        return (w.owner, w.guardian, w.dailyLimit);
    }
}

// BUG
// initOrResetWallet has no access control and no check whether the wallet is already initialized. Any caller can
// overwrite any user's wallet data, including the guardian address and daily spending limit, and reset spentToday to 0.

// IMPACT
// An attacker calls initOrResetWallet for a victim's address, replacing the guardian with an attacker-controlled
// address and setting dailyLimit to type(uint256).max. The victim's wallet is now controlled by the attacker's
// guardian with unlimited spending.

// INVARIANT
// A wallet's configuration (owner, guardian, daily limit) must only be set during initial creation and never overwritten
// without proper authorization.

// WHAT BREAKS
// initOrResetWallet unconditionally overwrites all wallet fields including the guardian and daily limit without checking
// if the wallet already exists or if the caller is authorized. An attacker can reinitialize any user's wallet, replacing
// the guardian with their own address and setting an unlimited daily limit, then exploiting the guardian role to drain the wallet.
