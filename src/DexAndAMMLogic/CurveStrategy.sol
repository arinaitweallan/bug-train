// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICurvePool {
    /// @notice Performs the remove_liquidity_one_coin operation for the protocol.
    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 _min_amount) external returns (uint256);
    /// @notice Performs the add_liquidity operation for the protocol.
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external returns (uint256);
}

/// @title CurveStrategy
/// @notice Automated market maker contract that provides on-chain liquidity and swap routing.
contract CurveStrategy {
    using SafeERC20 for IERC20;

    IERC20 public lpToken;
    IERC20 public want;

    ICurvePool public pool;
    address public vault;

    uint256 public totalDeposited;

    constructor(address _lp, address _want, address _pool, address _vault) {
        lpToken = IERC20(_lp);
        want = IERC20(_want);
        pool = ICurvePool(_pool);
        vault = _vault;
    }
    modifier onlyVault() {
        require(msg.sender == vault, "Not vault");
        _;
    }

    /// @notice Withdraw tokens from the contract

    // q After remove_liquidity_one_coin, what does want.balanceOf(address(this)) include?
    // Is it only the tokens from this removal?
    function withdraw(uint256 lpAmount) external onlyVault {
        lpToken.safeApprove(address(pool), lpAmount);
        pool.remove_liquidity_one_coin(lpAmount, 0, 0); // return token amount removed, is it want? [yes]

        uint256 wantBal = want.balanceOf(address(this));
        // wantBal includes tokens other tokens
        totalDeposited -= wantBal;
        want.safeTransfer(vault, wantBal);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external onlyVault {
        want.safeTransferFrom(vault, address(this), amount);
        want.safeApprove(address(pool), amount);

        uint256[2] memory amounts;
        amounts[0] = amount;
        pool.add_liquidity(amounts, 0);
        totalDeposited += amount;
    }

    /// @notice Balance of pool
    function balanceOfPool() external view returns (uint256) {
        return lpToken.balanceOf(address(this));
    }

    /// @notice Balance of want
    function balanceOfWant() external view returns (uint256) {
        return want.balanceOf(address(this));
    }
}

// BUG
// After remove_liquidity_one_coin, the code uses want.balanceOf(address(this)) to determine the withdrawal amount. This captures
// ALL want tokens in the contract, not just those received from the current removal. Pre-existing dust, prior partial operations,
// or donations are included.

// IMPACT
// totalDeposited is decremented by the full want balance (which may exceed the actual removal output). This over-decrements
// totalDeposited, permanently corrupting the accounting. Additionally, the return value of remove_liquidity_one_coin is ignored
// (line 37), so there is no way to know how much was actually received vs pre-existing balance.

// INVARIANT
// totalDeposited must track the actual value managed by the strategy. Withdrawals must decrement totalDeposited by exactly the
// amount received from the pool removal, not by the contract's total want token balance.

// WHAT BREAKS
// withdraw() uses want.balanceOf(address(this)) to determine how much to subtract from totalDeposited and transfer to the vault.
// This captures the ENTIRE want token balance including pre-existing tokens from previous operations, donations, or partial
// withdrawals. totalDeposited is over-decremented, corrupting the strategy's accounting permanently.

// EXPLOIT PATH
// 1. Strategy has 100 LP tokens, totalDeposited=100. Strategy also holds 20 want tokens from a previous partial operation (dust)
// 2. Vault calls withdraw(50). remove_liquidity_one_coin(50, 0, 0) returns 45 want tokens
// 3. wantBal = want.balanceOf(address(this)) = 45 + 20 = 65 (includes pre-existing balance)
// 4. totalDeposited -= 65. New totalDeposited = 100 - 65 = 35. But only 50 LP tokens worth of value was withdrawn. totalDeposited should be ~50, not 35
// 5. Vault receives 65 want tokens (more than the 45 from the removal), including the 20 that belonged to the strategy
// 6. totalDeposited is now 35 but the strategy still holds 50 LP tokens. The 15-unit discrepancy means future withdrawals will undercount available value, and the strategy reports less value than it actually manages.

// WHY MISSED
// The balanceOf pattern for determining withdrawal amounts is common in yield strategies. Auditors may focus on verifying that
// the Curve pool interaction works correctly without considering what happens when the contract has pre-existing want token
// balance from previous operations, donations, or failed partial withdrawals.
