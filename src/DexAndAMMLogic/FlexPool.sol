// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// addLiquiditySingleSided values the deposit using totalValue = reserveA + reserveB. Does it account for the fact that a
// single-sided deposit effectively swaps half the amount?

// Deposit 1000 tokenA single-sided, get LP shares based on pre-deposit ratio. Immediately remove liquidity: receive proportional
// tokenA AND tokenB. Net: swapped tokenA for tokenB without paying any swap fee.

/// @title FlexPool
/// @notice Automated market maker contract that provides on-chain liquidity and swap routing.
contract FlexPool {
    using SafeERC20 for IERC20;

    IERC20 public tokenA;
    IERC20 public tokenB;

    uint256 public reserveA;
    uint256 public reserveB;
    uint256 public totalLP;

    mapping(address => uint256) public lpBalance;

    uint256 public constant FEE_BPS = 30;

    constructor(address _a, address _b) {
        tokenA = IERC20(_a);
        tokenB = IERC20(_b);
    }

    /// @notice Init pool
    /// @param a The a
    /// @param b The b
    function initPool(uint256 a, uint256 b) external {
        require(totalLP == 0, "Already init");

        tokenA.safeTransferFrom(msg.sender, address(this), a);
        tokenB.safeTransferFrom(msg.sender, address(this), b);
        reserveA = a;
        reserveB = b;
        totalLP = a + b;
        lpBalance[msg.sender] = totalLP;
    }

    /// @notice Add liquidity to the pool
    /// @param token Token contract address
    /// @param amount Token amount
    function addLiquiditySingleSided(address token, uint256 amount) external returns (uint256 lp) {
        require(token == address(tokenA) || token == address(tokenB), "Invalid");

        bool isA = token == address(tokenA);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 totalValue = reserveA + reserveB;
        lp = (amount * totalLP) / totalValue;
        if (isA) {
            reserveA += amount;
        } else {
            reserveB += amount;
        }
        lpBalance[msg.sender] += lp;
        totalLP += lp;
    }

    /// @notice Remove liquidity from the pool
    function removeLiquidity(uint256 lpAmount) external {
        require(lpBalance[msg.sender] >= lpAmount, "Insufficient");
        uint256 outA = (lpAmount * reserveA) / totalLP;
        uint256 outB = (lpAmount * reserveB) / totalLP;

        lpBalance[msg.sender] -= lpAmount;
        totalLP -= lpAmount;
        reserveA -= outA;
        reserveB -= outB;

        tokenA.safeTransfer(msg.sender, outA);
        tokenB.safeTransfer(msg.sender, outB);
    }

    /// @notice Get pool value
    function getPoolValue() external view returns (uint256) {
        return reserveA + reserveB;
    }
}

// BUG
// Single-sided deposit values the contribution at the current pool ratio without accounting for the price impact the deposit
// itself creates. No implicit swap fee is charged, allowing the depositor to get LP shares as if they deposited at the pre-impact
// price.

// IMPACT
// An attacker deposits only tokenA, getting overvalued LP shares. On withdrawal via removeLiquidity, they receive both tokenA
// AND tokenB proportionally. The net effect is a free swap from tokenA to tokenB without paying any fee, extracting value from
// existing LPs.

// INVARIANT
// Single-sided deposits must be valued after accounting for the implicit swap and its associated fee. LP shares must reflect
// the post-impact contribution, not the pre-impact valuation.

// WHAT BREAKS
// Single-sided deposits effectively perform a free swap, bypassing the pool's fee mechanism. An attacker repeatedly deposits
// one side and withdraws both sides, extracting the fee amount from existing LPs on each cycle.

// EXPLOIT PATH
// 1. Pool: reserveA=10,000, reserveB=10,000, totalLP=20,000. Fee=0.3% but not applied on single-sided deposits
// 2. Attacker deposits 10,000 tokenA single-sided. totalValue=20,000. lp = 10,000 * 20,000 / 20,000 = 10,000. New state: reserveA=20,000, reserveB=10,000, totalLP=30,000
// 3. Attacker holds 10,000 / 30,000 = 33.3% of pool
// 4. Attacker removes 10,000 LP: outA = 10,000 * 20,000 / 30,000 = 6,666. outB = 10,000 * 10,000 / 30,000 = 3,333
// 5. Net: deposited 10,000 tokenA, received 6,666 tokenA + 3,333 tokenB. Effectively swapped 3,334 tokenA for 3,333 tokenB at 1:1 with zero fee
// 6. If the swap fee is 0.3%, each cycle steals 0.3% * 3,334 = ~10 tokens from the pool. Repeated 100 times = ~1,000 tokens extracted.

// WHY MISSED
// The LP minting math (amount * totalLP / totalValue) appears correct as a standard proportional formula. Auditors may verify
// the formula without recognizing that single-sided deposits contain an implicit swap component that should be fee-charged.
// The FEE_BPS constant (line 17) is declared but never used, reinforcing that a fee was intended but not implemented.
// Additionally, initPool() has no access control and can be frontrun to set an unfavorable initial ratio.

