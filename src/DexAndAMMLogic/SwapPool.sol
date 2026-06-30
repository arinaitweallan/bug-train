// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SwapPool
/// @notice Automated market maker contract that provides on-chain liquidity and swap routing.
contract SwapPool {
    using SafeERC20 for IERC20;

    IERC20 public tokenA;
    IERC20 public tokenB;

    uint256 public reserveA;
    uint256 public reserveB;

    uint256 public constant FEE_BPS = 30;

    constructor(address _a, address _b, uint256 _resA, uint256 _resB) {
        tokenA = IERC20(_a);
        tokenB = IERC20(_b);
        reserveA = _resA;
        reserveB = _resB;
    }

    /// @notice Exchange one token for another
    /// @param tokenIn Token in value
    /// @param amountIn Input token amount
    /// @param minAmountOut Min amount out value

    // q The swap has minAmountOut but no deadline. How long can this transaction wait before executing?
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        require(tokenIn == address(tokenA) || tokenIn == address(tokenB), "Invalid");
        require(amountIn > 0, "Zero input");

        bool isA = tokenIn == address(tokenA);
        uint256 amountInAfterFee = (amountIn * (10000 - FEE_BPS)) / 10000;
        if (isA) {
            amountOut = (amountInAfterFee * reserveB) / (reserveA + amountInAfterFee);
            require(amountOut >= minAmountOut, "Slippage");
            tokenA.safeTransferFrom(msg.sender, address(this), amountIn);
            tokenB.safeTransfer(msg.sender, amountOut);
            reserveA += amountIn;
            reserveB -= amountOut;
        } else {
            amountOut = (amountInAfterFee * reserveA) / (reserveB + amountInAfterFee);
            require(amountOut >= minAmountOut, "Slippage");
            tokenB.safeTransferFrom(msg.sender, address(this), amountIn);
            tokenA.safeTransfer(msg.sender, amountOut);
            reserveB += amountIn;
            reserveA -= amountOut;
        }
    }

    /// @notice Get amount out
    /// @param tokenIn Token in value
    /// @param amountIn Input token amount
    function getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256) {
        bool isA = tokenIn == address(tokenA);
        uint256 afterFee = (amountIn * (10000 - FEE_BPS)) / 10000;
        if (isA) return (afterFee * reserveB) / (reserveA + afterFee);
        return (afterFee * reserveA) / (reserveB + afterFee);
    }

    /// @notice Get reserves
    function getReserves() external view returns (uint256, uint256) {
        return (reserveA, reserveB);
    }
}

// // BUG
// The swap function has a minAmountOut parameter (slippage protection) but no deadline parameter. A transaction can sit in the
// mempool indefinitely and execute at any future block when conditions happen to satisfy the minAmountOut check.

// IMPACT
// A user sets minAmountOut based on current market conditions. The tx is pending for hours/days. Market moves significantly. The
// tx eventually executes at a rate that technically meets the stale minAmountOut but is far worse than the user would accept at
// the time of execution.

// INVARIANT
// Swap transactions must have a time-bound expiry (deadline) to prevent execution at stale conditions after prolonged mempool
// delays.

// WHAT BREAKS
// Transactions without deadlines can be delayed by validators or network congestion and executed at any future time. The
// minAmountOut provides a floor but not timeliness — users may trade at rates they would never accept given current market
// conditions.

// EXPLOIT PATH
// 1. User wants to swap 10 ETH for USDC when ETH=$2000. Sets minAmountOut=19,000 USDC (5% slippage from $20,000 expected)
// 2. Transaction sits in mempool. Validator does not include it immediately
// 3. One week later, ETH rises to $3000. User's swap is still valid (no deadline)
// 4. Validator includes the transaction. Pool rate reflects $3000 ETH. The 10 ETH is now worth $30,000, but user gets only 19,000 USDC (their stale minAmountOut)
// 5. The $11,000 difference is captured by the validator or arbitrageurs who rebalance the pool
// 6. With a deadline parameter, the transaction would have expired, and the user could resubmit at the current price.

// WHY MISSED
// The swap function already has slippage protection via minAmountOut, which creates a false sense of completeness. Auditors may
// check that slippage is protected and move on. The missing deadline is a separate temporal dimension of protection that is
// easy to overlook when the price dimension appears covered.
