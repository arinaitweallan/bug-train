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
