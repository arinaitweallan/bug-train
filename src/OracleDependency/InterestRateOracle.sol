// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Interest Rate Oracle Consumer

interface AggregatorV3Interface {
    /// @notice Performs the latestRoundData operation for the protocol.
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
    /// @notice Returns the number of decimals used.
    function decimals() external view returns (uint8);
}

/// @title InterestRateOracle
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract InterestRateOracle {
    AggregatorV3Interface public immutable priceFeed;

    uint8 public immutable feedDecimals;
    uint256 public immutable heartbeat;
    uint256 public baseRate;

    address public admin;

    constructor(address _feed, uint256 _heartbeat) {
        priceFeed = AggregatorV3Interface(_feed);
        // feed decimals is set as immutable
        feedDecimals = priceFeed.decimals();
        heartbeat = _heartbeat;
        baseRate = 500; // 5% in basis points
        admin = msg.sender;
    }

    /// @notice Get price
    function getPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid price");
        require(block.timestamp - updatedAt <= heartbeat, "Stale");
        // q what if the decimals are greator than 18?
        return uint256(answer) * (10 ** (18 - feedDecimals));
    }

    /// @notice Calculate borrow rate given current utilization (in basis points)
    function calculateBorrowRate(uint256 utilization) external view returns (uint256) {
        uint256 price = getPrice();

        // say utilisation is 60%
        uint256 priceMultiplier = (price > 2000e18) ? 200 : 100;
        // = 100 + (6000 / 100) = 160
        uint256 utilizationMultiplier = 100 + (utilization / 100); // 1% per 100bps utilization
        // 500 * 100 * 160 / 1e4 = 800
        return (baseRate * priceMultiplier * utilizationMultiplier) / 10000;
    }

    /// @notice Configure a contract parameter
    function setBaseRate(uint256 _rate) external {
        require(msg.sender == admin, "Not admin");
        require(_rate <= 5000, "Max 50%");
        baseRate = _rate;
    }
}

// BUG
// feedDecimals is set as immutable in the constructor from priceFeed.decimals(). Chainlink feeds use a proxy pattern where the
// underlying aggregator can be upgraded. If the new aggregator changes its decimal precision, the immutable feedDecimals becomes
// stale, and the normalization on line 33 produces incorrect prices.

// IMPACT
// If the aggregator upgrades from 8 to 18 decimals, 10^(18-8) = 1e10 extra scaling is applied. The price is inflated by 1e10,
// breaking interest rate calculations and any downstream collateral valuations.

// INVARIANT
// Feed metadata (decimals, heartbeat) must be queried dynamically when the feed uses an upgradeable proxy, not cached at
// deployment time.

// WHAT BREAKS
// The contract stores feedDecimals as immutable at deployment. Chainlink's aggregator proxy can be upgraded (phaseId changes).
// If the new aggregator returns a different decimals() value, the normalization formula 10^(18 - feedDecimals) uses the old
// decimals, producing wildly incorrect prices.

// EXPLOIT PATH
// 1. At deployment, Chainlink ETH/USD feed returns decimals()=8. feedDecimals is stored as 8
// 2. Chainlink upgrades the aggregator proxy. New aggregator returns decimals()=18
// 3. New aggregator returns answer=3000e18 (18 decimals) for ETH at $3,000
// 4. getPrice(): uint256(3000e18) * 10^(18-8) = 3000e18 * 1e10 = 3000e28
// 5. Expected: 3000e18. Actual: 3000e28 -- price is 1e10 too high
// 6. calculateBorrowRate sees price > 2000e18 (true because 3000e28 >> 2000e18), and any collateral valuation using this price
//    is inflated by 10 billion.

// WHY MISSED
// Caching immutable values in the constructor is a standard gas optimization pattern. Auditors may not consider that Chainlink
// proxies can be upgraded after the consumer contract is deployed, especially since aggregator upgrades are infrequent and
// typically maintain the same decimals.
