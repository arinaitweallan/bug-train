// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IUniswapV3Pool {
    /// @notice Performs the observe operation for the protocol.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice External library that implements the real Uniswap V3 tick->sqrtPriceX96 conversion.
/// Assumed to match the canonical implementation at
/// https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/TickMath.sol
interface ITickMath {
    /// @notice Performs the getSqrtRatioAtTick operation for the protocol.
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160 sqrtPriceX96);
}

// q How long is the TWAP window? Is 10 seconds sufficient to resist price manipulation by a well-funded attacker?

/// @title TWAPOracle
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract TWAPOracle {
    IUniswapV3Pool public immutable pool;
    ITickMath public immutable tickMath;
    // q isnt the twap window too small?
    uint32 public constant TWAP_WINDOW = 10;
    uint256 public constant PRICE_PRECISION = 1e18;

    constructor(address _pool, address _tickMath) {
        pool = IUniswapV3Pool(_pool);
        tickMath = ITickMath(_tickMath);
    }

    /// @notice Get twapprice
    function getTWAPPrice() public view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        int56 tickDiff = tickCumulatives[1] - tickCumulatives[0];
        int24 avgTick = int24(tickDiff / int56(int32(TWAP_WINDOW)));
        uint160 sqrtPriceX96 = tickMath.getSqrtRatioAtTick(avgTick);
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return (priceX192 * PRICE_PRECISION) >> 192;
    }

    /// @notice Get collateral value
    function getCollateralValue(uint256 amount) external view returns (uint256) {
        uint256 price = getTWAPPrice();
        return (amount * price) / PRICE_PRECISION;
    }
}

// BUG
// TWAP_WINDOW is 10 seconds. A 10-second TWAP provides virtually no manipulation resistance because an attacker only needs to
// sustain a distorted price for 10 seconds (a few blocks) to fully corrupt the average.

// IMPACT
// Any protocol using getCollateralValue() for lending, margin, or liquidation decisions can be exploited because the 10-second
// TWAP is trivially manipulable via flash loans or multi-block MEV.

// INVARIANT
// A TWAP oracle must use an observation window long enough that the cost of sustaining a manipulated price for the entire
// window exceeds the attacker's potential profit.

// WHAT BREAKS
// TWAP_WINDOW = 10 means the time-weighted average only spans 10 seconds. An attacker can execute a large swap, wait 10 seconds
// (1-2 Ethereum blocks), and the entire TWAP window reflects their manipulated price.

// EXPLOIT PATH
// 1. Attacker flash-loans 50,000 ETH and swaps into the Uni V3 pool at block N, pushing tick from 200000 to 250000
// 2. At block N+1 (12 seconds later), the 10-second TWAP fully reflects the manipulated tick of ~250000
// 3. getTWAPPrice() returns the inflated price. Attacker calls the lending protocol to borrow against inflated collateral (getCollateralValue returns the inflated amount)
// 4. Attacker swaps back at block N+2, returning the price to normal, and repays the flash loan
// 5. With a 25% price inflation sustained for just 10s, attacker extracts 25% more borrowing power than their collateral warrants.

// WHY MISSED
// The code correctly implements the Uniswap V3 TWAP pattern (observe with two timestamps, compute tick difference). Auditors
// focused on correctness of the TWAP calculation may not evaluate whether the window duration provides adequate economic
// security.
