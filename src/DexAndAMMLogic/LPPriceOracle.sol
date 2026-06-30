// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IUniswapV2Pair {
    /// @notice Performs the getReserves operation for the protocol.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    /// @notice Returns the total supply of outstanding shares.
    function totalSupply() external view returns (uint256);
    /// @notice Performs the token0 operation for the protocol.
    function token0() external view returns (address);
    /// @notice Performs the token1 operation for the protocol.
    function token1() external view returns (address);
}

interface IERC20 {
    /// @notice Returns the number of decimals used.
    function decimals() external view returns (uint8);
    /// @notice Returns the balance of a given account.
    function balanceOf(address) external view returns (uint256);
}

/// @title LPPriceOracle
/// @notice Automated market maker contract that provides on-chain liquidity and swap routing.
contract LPPriceOracle {
    IUniswapV2Pair public pair;
    uint256 public constant PRICE_PRECISION = 1e18;

    constructor(address _pair) {
        pair = IUniswapV2Pair(_pair);
    }

    /// @notice Get lptoken price
    function getLPTokenPrice() public view returns (uint256) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 totalValue = (uint256(reserve0) + uint256(reserve1)) * PRICE_PRECISION;
        uint256 lpSupply = pair.totalSupply();
        return totalValue / lpSupply;
    }

    /// @notice Get collateral value
    /// @param user User address
    /// @param lpAmount Lp amount value
    // user parameter not used
    function getCollateralValue(address user, uint256 lpAmount) external view returns (uint256) {
        uint256 pricePerLP = getLPTokenPrice();
        return (lpAmount * pricePerLP) / PRICE_PRECISION;
    }

    /// @notice Is liquidatable
    /// @param user User address
    /// @param lpCollateral Lp collateral value
    /// @param debt Debt value

    // q Where does the price data come from? Can getReserves() be influenced within the same transaction?
    function isLiquidatable(address user, uint256 lpCollateral, uint256 debt) external view returns (bool) {
        uint256 collateralValue = this.getCollateralValue(user, lpCollateral);
        return collateralValue < (debt * 125) / 100;
    }

    /// @notice Get reserve ratio
    function getReserveRatio() external view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        return (uint256(r0) * PRICE_PRECISION) / uint256(r1);
    }
}

// BUG
// getLPTokenPrice reads current reserves via getReserves() as a spot price. These reserves can be manipulated within a single
// transaction using a flash loan, making the LP price artificially high or low.

// IMPACT
// isLiquidatable uses the manipulable LP price to determine liquidation eligibility. An attacker can flash-loan-manipulate
// reserves to make healthy positions appear liquidatable, or inflate their own collateral value to overborrow.

// INVARIANT
// LP token price used for collateral valuation must be resistant to single-transaction manipulation.

// WHAT BREAKS
// An attacker can use a flash loan to temporarily inflate or deflate LP token price, enabling artificial liquidations of
// healthy positions or over-borrowing against inflated collateral.

// EXPLOIT PATH
// 1. Pool has reserve0=1,000,000 USDC, reserve1=1,000,000 DAI, totalSupply=1,000,000 LP. Fair LP price = (1M + 1M) * 1e18 / 1M = 2e18
// 2. Attacker takes flash loan of 9,000,000 USDC, swaps into pool. New reserves: reserve0=10,000,000 USDC, reserve1=100,000 DAI (x*y=k: 10M * 100K = 1e12)
// 3. Manipulated LP price = (10M + 100K) * 1e18 / 1M = 10.1e18 (5x inflated)
// 4. Attacker deposits 100 LP as collateral, borrows against the inflated value of 1,010 instead of fair value 200
// 5. Attacker repays flash loan, pool reserves revert. Attacker keeps ~800 in excess borrowing
// 6. Alternatively: attacker deflates reserves to trigger liquidation of a victim's position at a discount.

// WHY MISSED
// Auditors may verify that the formula (reserve0 + reserve1)/totalSupply is mathematically correct for fair-value pricing. The
// primary bug is not in the formula but in the data source - getReserves() is a spot read that reflects flash-loan-manipulable
// state. A secondary issue: getLPTokenPrice adds reserve0 + reserve1 without considering token decimals. If the pair has tokens
// with different decimals (e.g., USDC/DAI), the sum is meaningless.
