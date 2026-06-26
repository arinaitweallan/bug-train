// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface AggregatorV3Interface {
    /// @notice Performs the latestRoundData operation for the protocol.
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
    /// @notice Returns the number of decimals used.
    function decimals() external view returns (uint8);
}

/// @title CompositeOracle
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract CompositeOracle {
    // q The two feeds have different decimal counts (18 and 8). When you multiply them,
    // what is the resulting decimal precision?
    AggregatorV3Interface public immutable tokenEthFeed; // TOKEN/ETH, 18 decimals
    AggregatorV3Interface public immutable ethUsdFeed; // ETH/USD, 8 decimals

    uint256 public constant MAX_STALENESS = 3600;

    constructor(address _tokenEth, address _ethUsd) {
        // token is BTC
        // tokenEthPrice = (58_000/1500) * 1e18
        // ethUsdfeed = 1500e8
        // (58_000/1500) * 1e18 * 1500e8 = 5.8e30 / 1e18 = 5800000000000.0
        tokenEthFeed = AggregatorV3Interface(_tokenEth);
        ethUsdFeed = AggregatorV3Interface(_ethUsd);
    }

    /// @notice Get token usd price
    function getTokenUsdPrice() public view returns (uint256) {
        (, int256 tokenEthPrice,, uint256 updatedAt1,) = tokenEthFeed.latestRoundData();
        require(tokenEthPrice > 0 && block.timestamp - updatedAt1 < MAX_STALENESS, "Bad");

        (, int256 ethUsdPrice,, uint256 updatedAt2,) = ethUsdFeed.latestRoundData();
        require(ethUsdPrice > 0 && block.timestamp - updatedAt2 < MAX_STALENESS, "Bad");
        // TOKEN/ETH * ETH/USD = TOKEN/USD
        uint256 tokenUsd = (uint256(tokenEthPrice) * uint256(ethUsdPrice)) / 1e18;
        return tokenUsd;
    }

    /// @notice Get collateral value
    /// @param amount Token amount
    /// @param tokenDecimals Token decimals value
    function getCollateralValue(uint256 amount, uint8 tokenDecimals) external view returns (uint256) {
        uint256 price = getTokenUsdPrice();
        return (amount * price) / (10 ** tokenDecimals);
    }
}

// BUG
// TOKEN/ETH feed has 18 decimals and ETH/USD feed has 8 decimals. The multiplication produces a result with 26 decimals (18+8),
// but the code divides by 1e18 assuming both feeds share the same decimal scale. The result has 8 residual decimals instead of
// the expected 18, causing a 1e10 deflation of the composite price.

// IMPACT
// getCollateralValue() returns values 10 billion times too small, making all collateral appear worthless and triggering mass
// liquidations.

// INVARIANT
// In composite oracle paths, intermediate price decimal counts must be tracked and normalized at each multiplication boundary
// to prevent compounding precision errors.

// WHAT BREAKS
// The TOKEN/ETH feed returns 18-decimal values, the ETH/USD feed returns 8-decimal values. Multiplying gives a 26-decimal number. Dividing by 1e18 leaves an 8-decimal result, but getCollateralValue() treats the returned price as if it were in the 18-decimal scale expected for downstream normalization. The mismatch causes a 1e10 error in valuation.
// EXPLOIT PATH
// 1. TOKEN/ETH = 0.5 (reported as 5e17 with 18 decimals). ETH/USD = $3,000 (reported as 3000e8 with 8 decimals)
// 2. Correct TOKEN/USD = 0.5 * $3,000 = $1,500, expected as 1500e18 (1.5e21) in 18-decimal representation
// 3. getTokenUsdPrice() computes: (5e17 * 3000e8) / 1e18 = (5e17 * 3e11) / 1e18 = 1.5e29 / 1e18 = 1.5e11
// 4. Actual result is 1.5e11; expected result is 1.5e21 -- a factor of 1e10 too small
// 5. All collateral passing through getCollateralValue() is undervalued by 10 billion times, effectively worth zero for lending purposes.

// WHY MISSED
// The formula TOKEN/ETH * ETH/USD / normalization is algebraically correct. Auditors may verify the multiplication logic
// without computing the actual decimal propagation through each hop. The comments document the feed decimals, but the
// normalization divisor does not match.
