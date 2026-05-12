// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title TWAPOracle
contract TWAPOracle {
    struct Observation {
        uint256 timestamp;
        uint256 price;
        uint256 cumulativePrice;
    }

    Observation[] public observations;
    address public feeder;
    uint256 public constant WINDOW = 1800;

    constructor(address _feeder) {
        feeder = _feeder;
    }

    /// @notice Record observation
    function recordObservation(uint256 price) external {
        require(msg.sender == feeder, "Not feeder");

        uint256 cumulative =
            observations.length == 0 ? price : observations[observations.length - 1].cumulativePrice + price;

        observations.push(Observation(block.timestamp, price, cumulative));
    }

    /// @notice Get twap
    function getTWAP() external view returns (uint256) {
        require(observations.length >= 2, "Not enough data");
        // len = 5

        // latest = 5 - 1 = 4
        uint256 latest = observations.length - 1;
        // windowStart = 20000 - 1800 = 18200
        uint256 windowStart = block.timestamp - WINDOW;
        // startIdx = 4
        uint256 startIdx = latest;

        // i = 4, i > 0, i--
        for (uint256 i = latest; i > 0; i--) {
            if (observations[i].timestamp <= windowStart) {
                startIdx = i;
                break;
            }
        }
        require(startIdx < latest, "Window too short");

        uint256 priceDelta = observations[latest].cumulativePrice - observations[startIdx].cumulativePrice;
        uint256 count = latest - startIdx;
        return priceDelta / count;
    }

    /// @notice Get latest price
    function getLatestPrice() external view returns (uint256) {
        return observations[observations.length - 1].price;
    }

    /// @notice Observation count
    function observationCount() external view returns (uint256) {
        return observations.length;
    }
}

// BUG
// The TWAP accumulation simply adds price values (line 23) without weighting by time duration. getTWAP() divides by observation
// COUNT (line 41) instead of time elapsed. This produces a simple average of price snapshots, not a time-weighted average.
// Observations spaced 1 second apart count equally to observations spaced 1 hour apart.

// IMPACT
// An attacker can submit many rapid observations at a manipulated price to skew the 'TWAP' because each observation has equal
// weight regardless of duration. 100 observations at a fake price in 1 second outweigh 10 legitimate observations over 30
// minutes.

// INVARIANT
// A TWAP must weight each price observation by its time duration, not count each observation equally.

// WHAT BREAKS
// recordObservation() accumulates raw prices (line 23) without multiplying by time elapsed since the last observation.
// getTWAP() divides by count instead of time delta. This produces a simple average, not a time-weighted average.

// EXPLOIT PATH
// 1. Over 30 minutes, 10 legitimate observations record price = $2,000 each
// 2. Attacker (if feeder is compromised or public) submits 100 observations in 1 block at price = $4,000
// 3. cumulativeDelta = (10 * 2000 + 100 * 4000) = 420,000. count = 110
// 4. Fake TWAP = 420,000 / 110 = $3,818. Real TWAP should be close to $2,000 (30 min at $2K vs seconds at $4K)
// 5. Any protocol consuming this TWAP values assets at 1.9x the true price.

// WHY MISSED
// The contract has the structure of a TWAP oracle (cumulative prices, observation windows, start/end indexing). The variable
// names suggest correct implementation. The subtle error is in the accumulation formula -- adding price instead of
// price * timeDelta -- which requires careful math review to catch.
