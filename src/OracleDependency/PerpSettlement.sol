// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface AggregatorV3Interface {
    /// @notice Performs the latestRoundData operation for the protocol.
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// --- Perpetual Futures Settlement --- ///

/// @title PerpSettlement
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract PerpSettlement {
    AggregatorV3Interface public immutable priceFeed;

    struct PendingOrder {
        address trader;
        int256 size;
        uint256 cachedPrice;
        uint256 submittedAt;
        bool isSettled;
    }
    mapping(uint256 => PendingOrder) public orders;
    mapping(address => int256) public pnl;

    uint256 public nextOrderId;
    uint256 public constant SETTLEMENT_DELAY = 300;

    constructor(address _feed) {
        priceFeed = AggregatorV3Interface(_feed);
    }

    /// @notice Returns the current price used by the contract.
    function getPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(answer > 0 && block.timestamp - updatedAt < 3600, "Bad price");
        return uint256(answer);
    }

    /// @notice Submit a request or transaction
    function submitOrder(int256 size) external returns (uint256 orderId) {
        uint256 price = getPrice();
        orderId = nextOrderId++;
        orders[orderId] = PendingOrder(msg.sender, size, price, block.timestamp, false);
    }

    /// @notice Settle a pending transaction (trader-only)
    function settleOrder(uint256 orderId) external {
        PendingOrder storage order = orders[orderId];
        require(msg.sender == order.trader, "Not order owner");
        require(!order.isSettled, "Already settled");
        require(block.timestamp >= order.submittedAt + SETTLEMENT_DELAY, "Too early");

        order.isSettled = true;
        uint256 entryPrice = order.cachedPrice;
        uint256 markPrice = getPrice();

        _processSettlement(order.trader, order.size, entryPrice, markPrice);
    }

    function _processSettlement(address trader, int256 size, uint256 entryPrice, uint256 markPrice) internal {
        // P&L = size * (markPrice - entryPrice) / entryPrice
        int256 priceDelta = int256(markPrice) - int256(entryPrice);
        int256 delta = (size * priceDelta) / int256(entryPrice);
        pnl[trader] += delta;
    }
}

// BUG
// The oracle price is cached at order submission time and stored in cachedPrice, then used as entryPrice at settlement.
// Because the trader controls when to call settleOrder() and knows the cached entry price in advance, the cached-vs-mark delta
// creates a free option: after waiting SETTLEMENT_DELAY, the trader chooses to settle only if the realized move is favorable.

// IMPACT
// _processSettlement() computes P&L from (markPrice - entryPrice), with entryPrice locked in 5 minutes earlier. A trader who sees price
// rise waits the delay and settles for guaranteed positive P&L. If price falls, they simply never call settleOrder(), so the
// protocol has no mechanism to realize their loss

// INVARIANT
// In multi-step operations with time delays, the oracle price used for P&L reference (entry price) must be re-fetched at the
// consumption point and settlement must be mandatory or expire after a short window, not optional on the trader's initiative.

// WHAT BREAKS
// submitOrder() caches the current oracle price. settleOrder() uses this cached price as entryPrice after a mandatory 300-second
// delay, and only the order owner can call settleOrder(). The trader knows the entry price at submission and can wait to see
// if the market moves favorably before calling settle; if not, they leave the order unsettled indefinitely.

// EXPLOIT PATH
// 1. Oracle price at time T = $3,000/ETH. Trader calls submitOrder(+10 ETH), locking cachedPrice = $3,000
// 2. Over the next 5 minutes, ETH rises to $3,200 on the live market
// 3. At T+300s, trader calls settleOrder(). entryPrice = $3,000 (cached), markPrice = $3,200 (current)
// 4. _processSettlement computes pnl += 10 * (3200 - 3000) / 3000 ~= +0.666 (positive P&L credited)
// 5. This is risk-free because only the trader can settle (msg.sender == order.trader), so if ETH had dropped instead they would simply never call settleOrder() and the order would remain pending forever, realizing no loss.

// WHY MISSED
// Caching prices in pending-order structures is a common pattern for gas efficiency and user experience. Auditors may focus on
// whether the price is valid at submission time without considering that the 5-minute delay combined with trader-controlled
// settlement turns the entry price into a free option.
