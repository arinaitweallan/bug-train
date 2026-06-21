// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IUniswapV3Pool {
    /// @notice Performs the observe operation for the protocol.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    /// @notice Adds liquidity to the pool and mints LP units to the caller.
    function liquidity() external view returns (uint128);
}

/// @notice External library that implements the real Uniswap V3 tick->sqrtPriceX96 conversion.
/// Assumed to match the canonical implementation at
/// https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/TickMath.sol
interface ITickMath {
    /// @notice Performs the getSqrtRatioAtTick operation for the protocol.
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160 sqrtPriceX96);
}

/// --- Governance TWAP Voting Oracle --- ///

/// @title GovernancePricer
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract GovernancePricer {
    IUniswapV3Pool public immutable pool;
    ITickMath public immutable tickMath;
    uint32 public constant TWAP_WINDOW = 1800; // 30 minutes

    constructor(address _pool, address _tickMath) {
        pool = IUniswapV3Pool(_pool);
        tickMath = ITickMath(_tickMath);
    }

    /// @notice Get twapprice (price of token0 in terms of token1, scaled by 1e18)
    function getTWAPPrice() public view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        int56 tickDiff = tickCumulatives[1] - tickCumulatives[0];
        int24 avgTick = int24(tickDiff / int56(int32(TWAP_WINDOW)));

        uint160 sqrtPriceX96 = tickMath.getSqrtRatioAtTick(avgTick);
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return (priceX192 * 1e18) >> 192;
    }

    /// @notice Get voting power based on token balance valued at TWAP price
    function getVotingPower(uint256 tokenBalance) external view returns (uint256) {
        uint256 price = getTWAPPrice();
        return (tokenBalance * price) / 1e18;
    }

    /// @notice Get collateral value
    function getCollateralValue(uint256 amount) external view returns (uint256) {
        uint256 price = getTWAPPrice();
        return (amount * price) / 1e18;
    }
}

// BUG
// getTWAPPrice() reads from the pool without verifying minimum liquidity. If the pool has low liquidity, the cost to manipulate
// the TWAP for the entire 30-minute window can be less than the extractable value from the consuming protocol.
// The pool.liquidity() interface is available but unused.

// IMPACT
// An attacker with moderate capital can manipulate the TWAP of a low-liquidity pool to inflate their voting power or collateral
// value, enabling governance attacks or undercollateralized borrowing.

// INVARIANT
// A TWAP oracle source pool must have sufficient liquidity that the cost to sustain a manipulated price for the entire window
// exceeds the maximum extractable value.

// WHAT BREAKS
// The TWAP window is 30 minutes (adequate length), but there is no minimum liquidity check on the source pool. A pool with
// $50,000 in liquidity can have its price maintained at 2x for 30 minutes at a cost of ~$25,000 in arbitrage losses to the
// manipulator.

// EXPLOIT PATH
// 1. Token/ETH pool has $50,000 total liquidity. Protocol has $500,000 in deposits accepting this token as collateral
// 2. Attacker provides $100,000 of one-sided liquidity to control the tick range, and executes periodic swaps over 30 minutes to maintain 2x price
// 3. Arbitrageurs trade against the manipulated pool, costing the attacker ~$30,000 in losses over 30 minutes
// 4. After 30 minutes, TWAP fully reflects the 2x price. getTWAPPrice() returns 2x the real price
// 5. Attacker deposits tokens valued at 2x, borrows $300,000 against $150,000 real collateral. Net profit: $300,000 - $150,000 - $30,000 = $120,000.

// WHY MISSED
// The 30-minute TWAP window is the industry-recommended duration, creating confidence in the oracle design. The vulnerability
// is economic (cost-of-attack < profit) rather than algorithmic, requiring the auditor to evaluate the source pool's liquidity
// depth rather than the TWAP implementation itself.
