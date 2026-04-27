// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPriceFeed {
    function latestPrice() external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @title LendingPool
contract LendingPool {
    IPriceFeed public collateralOracle;
    IPriceFeed public debtOracle;

    uint256 public constant LTV_BPS = 7500;
    uint256 public constant BPS = 10000;
    uint256 public constant LIQUIDATION_THRESHOLD = 8500;

    struct Position {
        uint256 collateralAmount;
        uint256 debtAmount;
    }

    mapping(address => Position) public positions;

    constructor(address _collOracle, address _debtOracle) {
        collateralOracle = IPriceFeed(_collOracle);
        debtOracle = IPriceFeed(_debtOracle);
    }

    /// @notice Get collateral value
    function getCollateralValue(address user) public view returns (uint256) {
        uint256 price = collateralOracle.latestPrice();
        uint256 priceDec = collateralOracle.decimals();

        return positions[user].collateralAmount * price / (10 ** priceDec);
    }

    /// @notice Get debt value
    function getDebtValue(address user) public view returns (uint256) {
        uint256 price = debtOracle.latestPrice();
        uint256 priceDec = debtOracle.decimals();

        return positions[user].debtAmount * price / (10 ** priceDec);
    }

    /// @notice Is liquidatable
    function isLiquidatable(address user) public view returns (bool) {
        uint256 collValue = getCollateralValue(user);
        uint256 debtValue = getDebtValue(user);
        return collValue * LIQUIDATION_THRESHOLD / BPS < debtValue;
    }

    /// @notice Borrow tokens against collateral
    /// @param collateral Collateral token address
    /// @param debt Debt value
    function borrow(uint256 collateral, uint256 debt) external {
        positions[msg.sender].collateralAmount += collateral;
        positions[msg.sender].debtAmount += debt;

        uint256 collValue = getCollateralValue(msg.sender);
        uint256 debtValue = getDebtValue(msg.sender);
        require(collValue * LTV_BPS / BPS >= debtValue, "Undercollateralized");
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(address user) external {
        require(isLiquidatable(user), "Not liquidatable");
        delete positions[user];
    }
}

// BUG
// The multiplication collateralAmount * price can overflow uint256 when dealing with high-decimal tokens. If collateralAmount 
// is 1e27 (a token with 27 decimals) and the oracle price is 1e18 (18 decimal price feed), the product is 1e45 -- safe. But 
// for wrapped Bitcoin with 8 decimals and a price of ~30000e8 on an 8-decimal oracle, large collateral amounts 
// (e.g., 1e18 * 30000e8 = 3e30) are fine. However, if a token uses 36 decimals and price is 1e18, the product 1e36 * 1e18 = 1e54 
// -- still safe. The real danger: amount = 1e30, price = 1e50 (extreme oracle return) => product = 1e80 > 2^256.

// IMPACT
// When the multiplication overflows, getCollateralValue reverts. This means isLiquidatable also reverts, preventing liquidation 
// of undercollateralized positions. Borrowers with large positions become immune to liquidation during extreme price movements 
// -- exactly when liquidation is most needed.

// INVARIANT
// Collateral and debt value calculations must never revert due to overflow, especially during extreme market conditions when 
// liquidations are critical.

// WHAT BREAKS
// The multiplication of collateral amount by oracle price has no overflow protection beyond Solidity 0.8 revert. Under extreme 
// oracle prices (legitimate spikes or oracle manipulation), the multiplication overflows, causing getCollateralValue to revert. 
// This blocks all liquidation calls, leaving the protocol with bad debt.

// EXPLOIT PATH
// 1. Borrower deposits 1e24 units of a 18-decimal token as collateral
// 2. Oracle price spikes or is manipulated to return 1e55 (an extreme but technically possible value for some aggregator configurations)
// 3. getCollateralValue: 1e24 * 1e55 = 1e79. uint256 max = 1.15e77. OVERFLOW REVERT
// 4. isLiquidatable calls getCollateralValue -- reverts
// 5. No one can call liquidate() for this position
// 6. Price drops. Position is deeply undercollateralized but cannot be liquidated. Protocol accrues bad debt.
// WHY MISSED

// Auditors typically test oracle integration with realistic prices. The overflow only triggers with extreme values that are 
// rare but possible (oracle manipulation, L2 sequencer issues, or tokens with unusual decimal configurations).
