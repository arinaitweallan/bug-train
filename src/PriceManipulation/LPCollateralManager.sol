// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// @title LPCollateralManager
contract LPCollateralManager {
    IUniswapV2Pair public immutable lpToken;
    AggregatorV3Interface public immutable token0Feed;
    AggregatorV3Interface public immutable token1Feed;
    IERC20 public immutable stablecoin;

    uint256 public constant LTV = 70;

    mapping(address => uint256) public lpDeposits;
    mapping(address => uint256) public debt;

    constructor(address _lp, address _feed0, address _feed1, address _stable) {
        lpToken = IUniswapV2Pair(_lp);
        token0Feed = AggregatorV3Interface(_feed0);
        token1Feed = AggregatorV3Interface(_feed1);
        stablecoin = IERC20(_stable);
    }

    /// @notice Get lpprice
    function getLPPrice() public view returns (uint256) {
        (uint112 r0, uint112 r1,) = lpToken.getReserves();
        (, int256 p0,,,) = token0Feed.latestRoundData();
        (, int256 p1,,,) = token1Feed.latestRoundData();

        // totalValue = ((1000e18 * 1e8) + (1000e18 * 1e8)) / 1e8
        uint256 totalValue = (uint256(r0) * uint256(p0) + uint256(r1) * uint256(p1)) / 1e8;
        return totalValue / lpToken.totalSupply();
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(IERC20(address(lpToken)).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        lpDeposits[msg.sender] += amount;
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        uint256 lpPrice = getLPPrice();
        uint256 collateralValue = lpDeposits[msg.sender] * lpPrice;
        uint256 maxBorrow = collateralValue * LTV / 100;
        require(debt[msg.sender] + amount <= maxBorrow, "Exceeds LTV");

        debt[msg.sender] += amount;
        require(stablecoin.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(address user) external {
        uint256 lpPrice = getLPPrice();
        uint256 collateralValue = lpDeposits[user] * lpPrice;
        require(debt[user] > collateralValue * 80 / 100, "Healthy");

        uint256 seized = lpDeposits[user];
        lpDeposits[user] = 0;
        debt[user] = 0;
        require(IERC20(address(lpToken)).transfer(msg.sender, seized), "Transfer failed");
    }
}

// BUG
// getLPPrice() reads reserves directly via getReserves(). These reserves can be inflated by flash-loaning tokens and depositing
// them into the pair before this call, making LP tokens appear far more valuable than they are.

// IMPACT
// Inflated LP price lets the attacker borrow far more stablecoins than their LP collateral is actually worth, creating bad debt
// for the protocol.

// INVARIANT
// LP token valuation must not be inflatable by manipulating pool reserves within a single transaction.

// WHAT BREAKS
// getLPPrice() computes LP value as (r0*p0 + r1*p1) / totalSupply using raw getReserves() data. Flash loan allows inflating r0
// or r1 by swapping large amounts into the pair before getLPPrice() is read.

// EXPLOIT PATH
// 1. Fair LP price is $10. Attacker deposits 100 LP tokens worth $1,000
// 2. Attacker flash-loans 1M tokenA, swaps into the pair. r0 inflates from 1M to 10M
// 3. getLPPrice() computes totalValue with inflated r0: LP price rises to ~$95
// 4. collateralValue = 100 * 95 = $9,500. maxBorrow = $6,650
// 5. Attacker borrows $6,650, swaps back in pool, repays flash loan. Protocol holds $1,000 collateral vs $6,650 debt = $5,650 bad debt.

// WHY MISSED
// The code correctly uses Chainlink oracles for individual token prices (p0, p1), creating a false sense of security. The
// vulnerability is in using raw reserves (r0, r1) for the weighting, not in the individual price sources.
