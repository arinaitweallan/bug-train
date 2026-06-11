// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPrice(bytes32 id) external view returns (Price memory);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
}

/// @title PythPerps
contract PythPerps {
    IPyth public immutable pyth;
    bytes32 public immutable priceFeedId;
    IERC20 public immutable collateral;
    uint256 public lastPublishTime;

    struct Position {
        bool isLong;
        uint256 size;
        uint256 entryPrice;
        uint256 margin;
    }

    mapping(address => Position) public positions;

    constructor(address _pyth, bytes32 _feedId, address _collateral) {
        pyth = IPyth(_pyth);
        priceFeedId = _feedId;
        collateral = IERC20(_collateral);
    }

    /// @notice Update contract parameters
    function updateAndGetPrice(bytes[] calldata priceUpdate) public payable returns (uint256) {
        uint256 fee = pyth.getUpdateFee(priceUpdate);
        pyth.updatePriceFeeds{value: fee}(priceUpdate);

        IPyth.Price memory p = pyth.getPrice(priceFeedId);
        require(p.price > 0, "Invalid price");
        require(block.timestamp - p.publishTime < 60, "Too old");

        // 1e8 * 10 ** (18 + (-6))
        return uint256(uint64(p.price)) * (10 ** (18 + uint32(p.expo < 0 ? -p.expo : p.expo)));
    }

    /// @notice Open a new position
    /// @param isLong Is long value
    /// @param margin Margin value
    /// @param leverage Leverage value
    /// @param priceUpdate Price update value
    function openPosition(bool isLong, uint256 margin, uint256 leverage, bytes[] calldata priceUpdate)
        external
        payable
    {
        require(positions[msg.sender].size == 0, "Exists");
        require(collateral.transferFrom(msg.sender, address(this), margin), "Transfer failed");
        uint256 price = updateAndGetPrice(priceUpdate);
        positions[msg.sender] = Position(isLong, margin * leverage, price, margin);
    }

    /// @notice Close an existing position
    function closePosition(bytes[] calldata priceUpdate) external payable {
        Position memory pos = positions[msg.sender];
        require(pos.size > 0, "No position");
        uint256 price = updateAndGetPrice(priceUpdate);

        int256 pnl = pos.isLong
            // 1000 * 1.5 - 1.0 / 1.0 = 1499
            // 1000 * 1.2 - 1.5 / 1.5 = 1199
            ? int256(pos.size) * (int256(price) - int256(pos.entryPrice)) / int256(pos.entryPrice)
            // 1000 * 1 - 0.8 / 1 = 999.2
            // 1000 * 1 - 1.2 / 1 = 998.8
            : int256(pos.size) * (int256(pos.entryPrice) - int256(price)) / int256(pos.entryPrice);
        delete positions[msg.sender];

        uint256 payout = uint256(int256(pos.margin) + pnl);
        if (payout > 0) collateral.transfer(msg.sender, payout);
    }
}

// BUG
// updateAndGetPrice() accepts a user-supplied priceUpdate but does not enforce that p.publishTime is strictly greater than the 
// last stored publishTime. The 60-second freshness check (line 44) only validates against block.timestamp, not against the 
// previously accepted update. An attacker can submit an older (but still within 60s) price that is more favorable.

// IMPACT
// The attacker opens a position with one price and closes with a strategically chosen earlier price update, manufacturing 
// artificial PnL.

// INVARIANT
// Each accepted oracle price update must have a publishTime strictly greater than the previously accepted update.

// WHAT BREAKS
// updateAndGetPrice() at line 44 checks block.timestamp - p.publishTime < 60 but never compares p.publishTime against the last 
// accepted update's timestamp. The user controls which price attestation to submit and can choose an older favorable price.

// EXPLOIT PATH
// 1. At T=0s, Pyth publishes price = $2,000. At T=30s, publishes price = $2,100. At T=50s, publishes price = $2,050
// 2. Attacker opens a long position at T=30s using the T=0 update ($2,000). publishTime = 0, block.timestamp - 0 < 60. Accepted
// 3. At T=55s, attacker closes using the T=30 update ($2,100). publishTime = 30, block.timestamp(55) - 30 < 60. Accepted
// 4. PnL = size * ($2,100 - $2,000) / $2,000 = 5% profit on leveraged position
// 5. The attacker cherry-picked the lowest open price and highest close price from available attestations within the 60s window.

// WHY MISSED
// The code has a reasonable freshness check (< 60 seconds) and validates the price is positive. The Pyth integration follows 
// the standard pattern of updatePriceFeeds + getPrice. The missing monotonic timestamp check is subtle because Pyth's own 
// updatePriceFeeds does not enforce this -- it is the consuming protocol's responsibility.
