// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title MarketRegistry
contract MarketRegistry {
    struct Market {
        address creator;
        address tokenA;
        address tokenB;
        uint256 liquidity;
        bool active;
    }

    uint16 public nextMarketId;

    mapping(uint16 => Market) public markets;
    mapping(bytes32 => uint16) public pairToMarket;

    event MarketCreated(uint16 indexed marketId, address tokenA, address tokenB);

    /// @notice Create a new entry or position
    /// @param tokenA Token a value
    /// @param tokenB Token b value
    function createMarket(address tokenA, address tokenB) external returns (uint16) {
        require(tokenA != tokenB, "Same token");

        bytes32 pairKey = keccak256(abi.encodePacked(tokenA, tokenB));
        require(pairToMarket[pairKey] == 0, "Market exists");

        uint16 marketId;
        unchecked {
            marketId = nextMarketId++;
        }

        markets[marketId] = Market(msg.sender, tokenA, tokenB, 0, true);
        pairToMarket[pairKey] = marketId;

        emit MarketCreated(marketId, tokenA, tokenB);
        return marketId;
    }

    /// @notice Add liquidity to the pool
    /// @param marketId Market id value
    /// @param amount Token amount
    function addLiquidity(uint16 marketId, uint256 amount) external {
        require(markets[marketId].active, "Inactive");
        markets[marketId].liquidity += amount;
    }

    /// @notice Get market
    function getMarket(uint16 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    /// @notice Deactivate market
    function deactivateMarket(uint16 marketId) external {
        require(msg.sender == markets[marketId].creator, "Not creator");
        markets[marketId].active = false;
    }

    /// @notice Get active market count
    function getActiveMarketCount() external view returns (uint256 count) {
        for (uint16 i = 0; i < nextMarketId; i++) {
            if (markets[i].active) count++;
        }
    }

    /// @notice Get market pair
    function getMarketPair(uint16 marketId) external view returns (address, address) {
        require(markets[marketId].creator != address(0), "Nonexistent");
        return (markets[marketId].tokenA, markets[marketId].tokenB);
    }

    /// @notice Get total liquidity
    function getTotalLiquidity() external view returns (uint256 total) {
        for (uint16 i = 0; i < nextMarketId; i++) {
            total += markets[i].liquidity;
        }
    }
}

// BUG
// nextMarketId is uint16 and incremented inside unchecked{}. After 65535 markets are created, the counter wraps to 0. New 
// markets overwrite market ID 0's data in the markets mapping, destroying the original market's state including its liquidity.

// IMPACT
// When marketId wraps to 0, the Market struct at markets[0] is overwritten. The original market 0's liquidity is lost, and the 
// pairToMarket mapping for the old pair still points to ID 0 but now returns the wrong market data.

// INVARIANT
// Each market ID must be unique and must never be reused. Once a market is created at an ID, that ID must not be reassigned.

// WHAT BREAKS
// The uint16 counter wraps to 0 after 65535 markets due to the unchecked increment. New markets overwrite existing market data 
// in the mapping. The pairToMarket check only prevents the same pair from being re-registered, but the ID collision overwrites 
// a different pair's market data.

// EXPLOIT PATH
// 1. Market 0 is created for WETH/USDC with 1M in liquidity
// 2. Over time, 65535 more markets are created. nextMarketId = 65535
// 3. Attacker creates market 65536. unchecked: marketId = 65535, nextMarketId wraps to 0
// 4. Attacker creates market 65537. unchecked: marketId = 0, nextMarketId = 1
// 5. markets[0] is overwritten -- WETH/USDC market data (including 1M liquidity reference) is destroyed
// 6. Original WETH/USDC liquidity providers can no longer interact with their market.

// WHY MISSED
// Using uint16 for market IDs looks like a reasonable gas optimization (packs with other storage). The unchecked increment 
// is a common gas-saving pattern for loop counters. Auditors may not consider that 65535 markets is reachable over a protocol's 
// lifetime.
