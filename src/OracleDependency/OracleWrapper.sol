// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface AggregatorV3Interface {
    /// @notice Performs the latestRoundData operation for the protocol.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// --- Rate Limiter Oracle Wrapper --- ///

/// @title OracleWrapper
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract OracleWrapper {
    AggregatorV3Interface public priceFeed;
    address public admin;
    uint256 public heartbeat;

    constructor(address _feed) {
        priceFeed = AggregatorV3Interface(_feed);
        admin = msg.sender;
    }

    /// @notice Configure a contract parameter
    function setHeartbeat(uint256 _heartbeat) external {
        require(msg.sender == admin, "Not admin");
        heartbeat = _heartbeat;
    }

    /// @notice Get price
    function getPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid price");
        require(block.timestamp - updatedAt <= heartbeat, "Stale");

        return uint256(answer);
    }

    /// @notice Configure a contract parameter
    function setFeed(address _feed) external {
        require(msg.sender == admin, "Not admin");
        priceFeed = AggregatorV3Interface(_feed);
    }
}

// BUG
// The heartbeat variable is declared with no initializer (defaults to 0) and the constructor never sets it. The staleness check
// on line 32 becomes block.timestamp - updatedAt <= 0, which reverts for any price that is even 1 second old, causing a
// permanent DoS on getPrice() until admin calls setHeartbeat().

// getPrice() reverts for any call until setHeartbeat() is invoked. If the admin then over-corrects by setting heartbeat to a
// huge value, the staleness check is effectively disabled, accepting arbitrarily old prices. Neither setHeartbeat nor the
// constructor enforce a sane bound.

// INVARIANT
// The heartbeat parameter must be initialized to a non-zero value in the constructor and bounded within a reasonable range
// matching the Chainlink feed's actual update frequency.

// WHAT BREAKS
// heartbeat is never set in the constructor (defaults to 0). The staleness check require(block.timestamp - updatedAt <= heartbeat)
// will always revert because updatedAt is always at least slightly in the past. getPrice() becomes permanently uncallable until
// admin explicitly calls setHeartbeat(). setHeartbeat also has no range validation, so admin can mis-set it either way.

// EXPLOIT PATH
// 1. Contract is deployed. heartbeat = 0 (default, never initialized in constructor)
// 2. Any protocol calling getPrice() reverts with 'Stale' because block.timestamp - updatedAt > 0 always
// 3. All borrowing, liquidation, and valuation functions that depend on getPrice() are bricked
// 4. Admin notices and sets heartbeat = type(uint256).max to 'fix' it. The staleness check is now effectively disabled, accepting prices from any time in history
// 5. During a subsequent feed outage, a 24-hour-old price passes validation, enabling stale-price exploits against the restored protocol.

// WHY MISSED
// The staleness check is correctly structured (block.timestamp - updatedAt <= heartbeat), so auditors may verify the check
// pattern and move on without tracing the initial value of heartbeat through the constructor. The setter exists, creating an
// assumption that configuration is handled at deployment.
