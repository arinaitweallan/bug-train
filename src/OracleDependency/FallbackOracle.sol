// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface AggregatorV3Interface {
    /// @notice Performs the latestRoundData operation for the protocol.
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// @title FallbackOracle
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract FallbackOracle {
    AggregatorV3Interface public immutable primaryFeed;
    AggregatorV3Interface public immutable backupFeed;

    uint256 public lastGoodPrice;
    uint256 public lastUpdateTime;
    uint256 public constant MAX_STALENESS = 3600;

    constructor(address _primary, address _backup) {
        primaryFeed = AggregatorV3Interface(_primary);
        backupFeed = AggregatorV3Interface(_backup);
    }

    /// @notice Refresh cached price from primary or backup feeds
    function refreshPrice() public {
        (, int256 answer1,, uint256 updatedAt1,) = primaryFeed.latestRoundData();
        if (answer1 > 0 && block.timestamp - updatedAt1 <= MAX_STALENESS) {
            lastGoodPrice = uint256(answer1);
            lastUpdateTime = block.timestamp;
            return;
        }

        (, int256 answer2,, uint256 updatedAt2,) = backupFeed.latestRoundData();
        if (answer2 > 0 && block.timestamp - updatedAt2 <= MAX_STALENESS) {
            lastGoodPrice = uint256(answer2);
            lastUpdateTime = block.timestamp;
            return;
        }
    }

    /// @notice Get price (reads cached value, falls back if both feeds fail)
    function getPrice() public view returns (uint256) {
        (, int256 answer1,, uint256 updatedAt1,) = primaryFeed.latestRoundData();
        if (answer1 > 0 && block.timestamp - updatedAt1 <= MAX_STALENESS) {
            return uint256(answer1);
        }

        (, int256 answer2,, uint256 updatedAt2,) = backupFeed.latestRoundData();
        if (answer2 > 0 && block.timestamp - updatedAt2 <= MAX_STALENESS) {
            return uint256(answer2);
        }
        require(lastGoodPrice > 0, "No price available");
        return lastGoodPrice;
    }
}

// BUG
// When both primary and backup feeds fail validation, getPrice() returns lastGoodPrice without any staleness check on
// lastUpdateTime. lastGoodPrice could be hours or days old, but it is returned unconditionally as long as it is non-zero.

// IMPACT
// During extended oracle outages, all protocol operations proceed using an arbitrarily stale cached price, enabling borrowing
// against outdated collateral values or unfair liquidations of positions whose real value has drifted.

// INVARIANT
// Fallback/cached prices must have their own staleness validation. A price that is too old to use from the primary feed is also
// too old to use from a cache.

// WHAT BREAKS
// The fallback branch returns lastGoodPrice without checking when it was last set. If both feeds go stale for 24 hours, the
// protocol uses yesterday's price for all financial operations.

// EXPLOIT PATH
// 1. At time T, refreshPrice() is called and lastGoodPrice is set to $3,000/ETH
// 2. Both Chainlink feeds go offline (L1 congestion, aggregator migration). 24 hours pass
// 3. ETH market price crashes to $1,500 during the outage
// 4. At T+24h, a lending protocol calls getPrice(). Both feed branches fail validation
// 5. getPrice() returns lastGoodPrice = $3,000 (24 hours stale). User borrows $2,250 against 1 ETH ($1,500 real value)
// 6. When feeds recover, the position is underwater. Protocol absorbs $750 in bad debt per ETH of collateral.

// WHY MISSED
// The fallback pattern (primary -> backup -> cache) appears defense-in-depth. The primary and backup feeds have proper
// staleness checks, creating a sense of thorough validation. Auditors may not trace the fallback path far enough to notice that
// the cache itself has no expiration.
