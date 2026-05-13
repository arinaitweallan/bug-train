// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title PerpFutures
contract PerpFutures {
    AggregatorV3Interface public immutable priceFeed;
    IERC20 public immutable collateral;
    uint256 public constant LEVERAGE_MAX = 10;

    struct Position {
        bool isLong;
        uint256 size;
        uint256 entryPrice;
        uint256 margin;
    }

    mapping(address => Position) public positions;

    constructor(address _feed, address _collateral) {
        priceFeed = AggregatorV3Interface(_feed);
        collateral = IERC20(_collateral);
    }

    /// @notice Get price
    function getPrice() public view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid price");
        require(answeredInRound >= roundId, "Stale round");
        return uint256(answer);
    }

    /// @notice Open a new position
    /// @param isLong Is long value
    /// @param margin Margin value
    /// @param leverage Leverage value
    function openPosition(bool isLong, uint256 margin, uint256 leverage) external {
        require(leverage <= LEVERAGE_MAX, "Over max leverage");
        require(positions[msg.sender].size == 0, "Position exists");
        require(collateral.transferFrom(msg.sender, address(this), margin), "Transfer failed");

        uint256 price = getPrice();
        positions[msg.sender] = Position(isLong, margin * leverage, price, margin);
    }

    /// @notice Close an existing position
    function closePosition() external {
        Position memory pos = positions[msg.sender];
        require(pos.size > 0, "No position");

        uint256 currentPrice = getPrice();
        int256 pnl = pos.isLong
            ? int256(pos.size) * (int256(currentPrice) - int256(pos.entryPrice)) / int256(pos.entryPrice)
            : int256(pos.size) * (int256(pos.entryPrice) - int256(currentPrice)) / int256(pos.entryPrice);
        uint256 payout = uint256(int256(pos.margin) + pnl);
        delete positions[msg.sender];
        if (payout > 0) collateral.transfer(msg.sender, payout);
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(address user) external {
        Position memory pos = positions[user];
        uint256 currentPrice = getPrice();
        int256 pnl = pos.isLong
            ? int256(pos.size) * (int256(currentPrice) - int256(pos.entryPrice)) / int256(pos.entryPrice)
            : int256(pos.size) * (int256(pos.entryPrice) - int256(currentPrice)) / int256(pos.entryPrice);
        require(int256(pos.margin) + pnl < int256(pos.margin) / 10, "Not liquidatable");
        delete positions[user];
        require(collateral.transfer(msg.sender, pos.margin / 20), "Transfer failed");
    }
}

// BUG
// getPrice() checks answeredInRound >= roundId but does NOT validate updatedAt against block.timestamp. The answeredInRound
// check only detects multi-round staleness, not time-based staleness. The price could be hours old and still pass this check.

// IMPACT
// A stale high price lets long positions close at inflated profits or avoid liquidation. A stale low price lets short positions
// profit or liquidates long positions unfairly.

// INVARIANT
// Oracle prices used for PnL calculations must be current within the feed's heartbeat interval.

// WHAT BREAKS
// getPrice() validates answeredInRound >= roundId (a Chainlink round-staleness check) but ignores updatedAt. During oracle
// downtime or L2 sequencer issues, the price could be hours or days old while still passing the round check.

// EXPLOIT PATH
// 1. ETH/USD was $3,000 when oracle last updated 8 hours ago. Current market price crashed to $2,000
// 2. getPrice() returns $3,000 (answeredInRound == roundId, so round check passes; updatedAt is 8 hours ago but not checked)
// 3. Attacker opens a 10x long position with $1,000 margin at $3,000 entry. Immediately closes
// 4. PnL = 0 (same price). But on the real market, the price is $2,000 -- if the oracle updates, the position would be deeply underwater
// 5. Meanwhile, existing short positions cannot be closed profitably because the oracle still shows $3,000 instead of $2,000.

// WHY MISSED
// The code includes the answeredInRound >= roundId check, which is a documented Chainlink best practice for detecting stale
// rounds. This partial validation creates a strong false sense of security, leading auditors to conclude the staleness issue is
// handled.
