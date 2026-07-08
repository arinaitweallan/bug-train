// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title ConcentratedFeeTracker
/// @notice Automated market maker contract that provides on-chain liquidity and swap routing.
contract ConcentratedFeeTracker {
    struct TickInfo {
        uint256 feeGrowthOutside0;
        uint256 feeGrowthOutside1;
        int128 liquidityNet;
        bool initialized;
    }

    struct Position {
        uint128 liquidity;
        uint256 feeGrowthInside0Last;
        uint256 feeGrowthInside1Last;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    uint256 public feeGrowthGlobal0;
    uint256 public feeGrowthGlobal1;
    int24 public currentTick;

    mapping(int24 => TickInfo) public ticks;
    mapping(bytes32 => Position) public positions;

    /// @notice Get fee growth inside
    /// @param tickLower Tick lower value
    /// @param tickUpper Tick upper value
    function getFeeGrowthInside(int24 tickLower, int24 tickUpper)
        public
        view
        returns (uint256 feeGrowthInside0, uint256 feeGrowthInside1)
    {
        TickInfo storage lower = ticks[tickLower];
        TickInfo storage upper = ticks[tickUpper];
        uint256 feeGrowthBelow0;
        uint256 feeGrowthBelow1;
        if (currentTick >= tickLower) {
            feeGrowthBelow0 = lower.feeGrowthOutside0;
            feeGrowthBelow1 = lower.feeGrowthOutside1;
        } else {
            feeGrowthBelow0 = feeGrowthGlobal0 - lower.feeGrowthOutside0;
            feeGrowthBelow1 = feeGrowthGlobal1 - lower.feeGrowthOutside1;
        }

        uint256 feeGrowthAbove0;
        uint256 feeGrowthAbove1;
        if (currentTick < tickUpper) {
            feeGrowthAbove0 = upper.feeGrowthOutside0;
            feeGrowthAbove1 = upper.feeGrowthOutside1;
        } else {
            feeGrowthAbove0 = feeGrowthGlobal0 - upper.feeGrowthOutside0;
            feeGrowthAbove1 = feeGrowthGlobal1 - upper.feeGrowthOutside1;
        }

        feeGrowthInside0 = feeGrowthGlobal0 - feeGrowthBelow0 - feeGrowthAbove0;
        feeGrowthInside1 = feeGrowthGlobal1 - feeGrowthBelow1 - feeGrowthAbove1;
    }

    /// @notice Cross tick
    /// @param tick Tick value
    /// @param leftToRight Left to right value
    function crossTick(int24 tick, bool leftToRight) external {
        TickInfo storage info = ticks[tick];
        require(info.initialized, "Not initialized");
        info.feeGrowthOutside0 = feeGrowthGlobal0 - info.feeGrowthOutside0;
        info.feeGrowthOutside1 = feeGrowthGlobal1 - info.feeGrowthOutside1;
    }

    /// @notice Collect accumulated fees or rewards
    /// @param tickLower Tick lower value
    /// @param tickUpper Tick upper value
    function collectFees(int24 tickLower, int24 tickUpper) external returns (uint128 amount0, uint128 amount1) {
        bytes32 key = keccak256(abi.encodePacked(msg.sender, tickLower, tickUpper));
        Position storage pos = positions[key];
        require(pos.liquidity > 0, "No position");
        (uint256 fg0, uint256 fg1) = getFeeGrowthInside(tickLower, tickUpper);
        amount0 = uint128(((fg0 - pos.feeGrowthInside0Last) * pos.liquidity) >> 128);
        amount1 = uint128(((fg1 - pos.feeGrowthInside1Last) * pos.liquidity) >> 128);
        pos.feeGrowthInside0Last = fg0;
        pos.feeGrowthInside1Last = fg1;
        pos.tokensOwed0 += amount0;
        pos.tokensOwed1 += amount1;
    }
}
