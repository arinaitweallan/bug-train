// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title PerpPositionManager
contract PerpPositionManager {
    struct Position {
        address trader;
        uint256 margin;
        uint256 size;
        uint256 entryPrice;
        bool isLong;
    }

    mapping(uint256 => Position) public positions;

    uint256 public nextPositionId;
    uint256 public currentPrice;
    address public oracle;

    constructor(address _oracle) {
        oracle = _oracle;
        currentPrice = 2000e18;
    }

    /// @notice Open a new position
    /// @param margin Margin value
    /// @param size Size value
    /// @param isLong Is long value
    function openPosition(uint256 margin, uint256 size, bool isLong) external returns (uint256) {
        uint256 id = nextPositionId++;
        positions[id] = Position(msg.sender, margin, size, currentPrice, isLong);
        return id;
    }

    /// @notice Configure a contract parameter
    function setPrice(uint256 price) external {
        require(msg.sender == oracle, "Not oracle");
        currentPrice = price;
    }

    /// @notice Calculate pn l
    function calculatePnL(uint256 positionId) public view returns (int256) {
        Position memory pos = positions[positionId];
        int256 priceDelta = int256(currentPrice) - int256(pos.entryPrice);
        if (!pos.isLong) priceDelta = -priceDelta;
        return priceDelta * int256(pos.size) / int256(pos.entryPrice);
    }

    /// @notice Close an existing position
    function closePosition(uint256 positionId) external {
        Position storage pos = positions[positionId];
        require(msg.sender == pos.trader, "Not trader");

        int256 pnl = calculatePnL(positionId);
        uint256 payout = uint256(int256(pos.margin) + pnl);
        pos.margin = 0;
        pos.size = 0;
        (bool ok,) = msg.sender.call{value: payout}("");
        require(ok, "Transfer failed");
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(uint256 positionId) external {
        int256 pnl = calculatePnL(positionId);
        require(int256(positions[positionId].margin) + pnl <= 0, "Not liquidatable");
        positions[positionId].margin = 0;
        positions[positionId].size = 0;
    }

    receive() external payable {}
}

// BUG
// The cast uint256(int256(pos.margin) + pnl) does NOT revert when the sum is negative. In Solidity 0.8+, casting a negative
// int256 to uint256 silently produces a huge positive number via two's complement. If pnl is -500e18 and margin is 100e18,
// the sum is -400e18, which becomes uint256(type(int256).min + ... ) = a value near 2^256.

// IMPACT
// The payout becomes an astronomically large uint256. The call on line 47 attempts to send this amount of ETH, draining the
// entire contract balance to the attacker.

// INVARIANT
// Payout must never exceed the trader's margin. If PnL is more negative than margin, payout must be zero (loss exceeds
//     collateral).

// WHAT BREAKS
// Casting a negative int256 to uint256 does not revert in Solidity 0.8 -- it produces a huge positive number via two's
// complement wrapping. A trader with negative PnL exceeding their margin gets an enormous payout instead of zero.

// EXPLOIT PATH
// 1. Attacker opens a long position: margin = 1e18, size = 100e18, entryPrice = 2000e18
// 2. Price drops to 1000e18. PnL = (1000e18 - 2000e18) * 100e18 / 2000e18 = -50e18
// 3. int256(1e18) + int256(-50e18) = -49e18
// 4. uint256(-49e18) = 2^256 - 49e18 = ~1.157e77
// 5. Attacker calls closePosition. payout = ~1.157e77. Contract sends its entire ETH balance
// 6. Liquidation check in liquidate() exists but attacker calls closePosition directly, bypassing it.

// WHY MISSED
// The liquidation function correctly checks margin + pnl <= 0, so auditors may assume the protocol handles negative PnL. But
// closePosition does not call liquidate -- it directly casts the sum, and the negative-to-unsigned cast is invisible in
// Solidity syntax.
