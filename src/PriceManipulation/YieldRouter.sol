// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IRouter {
    function getAmountOut(uint256 amountIn, address tokenIn, address tokenOut) external view returns (uint256);
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) external returns (uint256);
}

/// @title YieldRouter
contract YieldRouter is ERC20 {
    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    IRouter public immutable router;

    constructor(address _a, address _b, address _router) ERC20("YieldLP", "yLP") {
        tokenA = IERC20(_a);
        tokenB = IERC20(_b);
        router = IRouter(_router);
    }

    /// @notice Get exchange rate
    function getExchangeRate() public view returns (uint256) {
        return router.getAmountOut(1e18, address(tokenA), address(tokenB));
    }

    /// @notice Total value
    function totalValue() public view returns (uint256) {
        uint256 rate = getExchangeRate();
        uint256 balA = tokenA.balanceOf(address(this));
        uint256 balB = tokenB.balanceOf(address(this));
        return balA * rate / 1e18 + balB;
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amountB) external returns (uint256 shares) {
        uint256 valueBefore = totalValue();
        require(tokenB.transferFrom(msg.sender, address(this), amountB), "Transfer failed");
        shares = totalSupply() == 0 ? amountB : amountB * totalSupply() / valueBefore;
        _mint(msg.sender, shares);
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 shares) external returns (uint256 amountB) {
        amountB = shares * totalValue() / totalSupply();
        _burn(msg.sender, shares);
        require(tokenB.transfer(msg.sender, amountB), "Transfer failed");
    }

    /// @notice Rebalance portfolio allocations
    function rebalance(uint256 amountA) external {
        tokenA.approve(address(router), amountA);
        router.swap(address(tokenA), address(tokenB), amountA, 0);
    }
}

// BUG
// getExchangeRate() uses router.getAmountOut() which reflects current pool state (reserves/liquidity). This is a spot quote, 
// not a manipulation-resistant oracle. It can be skewed by manipulating the underlying pool.

// IMPACT
// totalValue() uses the manipulable rate to value tokenA holdings. An inflated rate inflates totalValue(), letting existing 
// shareholders withdraw more tokenB than they deposited.

// INVARIANT
// Asset valuation must use a manipulation-resistant price source, not a DEX quote function that reflects current pool state.

// WHAT BREAKS
// getExchangeRate() calls router.getAmountOut() which reads from pool reserves. The returned rate feeds into totalValue() which 
// determines share prices for deposit() and withdraw(). Manipulating the pool changes the perceived total value.

// EXPLOIT PATH
// 1. Vault holds 1000 tokenA and 1000 tokenB. Fair rate: 1 A = 1 B. totalValue = 2000. TotalSupply = 2000 shares
// 2. Attacker holds 100 shares. Fair withdrawal: 100 tokenB
// 3. Attacker flash-loans tokenA, swaps into pool. getAmountOut(1e18) now returns 3e18 (3:1 rate)
// 4. totalValue = 1000 * 3 + 1000 = 4000. Attacker's 100 shares worth: 100 * 4000 / 2000 = 200 tokenB
// 5. Attacker withdraws 200 tokenB instead of 100. Profit: 100 tokenB.

// WHY MISSED
// Using a router's getAmountOut() looks like a standard way to get a price. The function name suggests it returns a fair 
// exchange rate. Auditors may not trace the implementation to realize it reads spot reserves.
