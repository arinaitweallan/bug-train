// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Flash-Loan Arbitrage Liquidator

interface ILendingPool {
    function flashLoan(address receiver, uint256 amount, bytes calldata data) external;
}

interface IPair {
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title CollateralPricer
contract CollateralPricer {
    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    IPair public immutable pair;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public borrowed;

    constructor(address _tokenA, address _tokenB, address _pair) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
        pair = IPair(_pair);
    }

    /// @notice Get price
    function getPrice() public view returns (uint256) {
        (uint112 reserveA, uint112 reserveB,) = pair.getReserves();
        return (uint256(reserveB) * 1e18) / uint256(reserveA);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(tokenA.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        deposits[msg.sender] += amount;
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        uint256 price = getPrice();
        uint256 maxBorrow = (deposits[msg.sender] * price * 75) / (1e18 * 100);
        require(borrowed[msg.sender] + amount <= maxBorrow, "Over LTV");

        borrowed[msg.sender] += amount;
        require(tokenB.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Repay borrowed tokens
    function repay(uint256 amount) external {
        require(tokenB.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        borrowed[msg.sender] -= amount;
    }
}

// INVARIANT
// Oracle price sources must not be alterable within the same transaction that consumes the price for financial decisions.

// WHAT BREAKS
// getPrice() computes price as reserveB/reserveA from the AMM pair. A flash loan can swap a large amount of tokenA into the pair,
// temporarily inflating reserveB/reserveA, then the attacker borrows against this inflated price in the same transaction.

// EXPLOIT PATH
// 1. Pair has reserves: 1000 tokenA, 3,000,000 tokenB. Price = 3,000,000/1000 = 3,000
// 2. Attacker flash-loans 9,000 tokenA and swaps into the pair. New reserves: ~10,000 tokenA, ~300,000 tokenB. Price drops to 30
// 3. Wait -- attacker wants to INFLATE price. Attacker flash-loans 2,700,000 tokenB and swaps into the pair. New reserves: ~100 tokenA, 5,700,000 tokenB. Price = 57,000
// 4. Attacker deposits 10 tokenA as collateral. maxBorrow = 10 * 57,000 * 75/100 = 427,500 tokenB
// 5. Attacker borrows 427,500 tokenB, swaps back to repay flash loan. True collateral value was only 30,000 tokenB. Protocol has 397,500 bad debt.

// WHY MISSED
// The pair.getReserves() call is a standard Uniswap V2 pattern that appears in many legitimate price reads. Auditors may verify
// the arithmetic is correct without evaluating whether the underlying reserves are manipulation-resistant in the context of
// flash loans.
