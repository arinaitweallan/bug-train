// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory);
    function token0() external view returns (address);
}

library TickMath {
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        return uint160(uint256(1 << 96) * 1e9 / (uint256(int256(tick) + 1e6)));
    }
}

/// @title FixedRateLending
contract FixedRateLending {
    IUniswapV3Pool public immutable oracle;
    IERC20 public immutable collateralToken;
    IERC20 public immutable loanToken;

    uint32 public constant TWAP_WINDOW = 120;
    uint256 public constant LTV = 75;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public loans;

    constructor(address _oracle, address _collateral, address _loan) {
        oracle = IUniswapV3Pool(_oracle);
        collateralToken = IERC20(_collateral);
        loanToken = IERC20(_loan);
    }

    /// @notice Get twapprice
    function getTWAPPrice() public view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = oracle.observe(secondsAgos);
        int24 avgTick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(TWAP_WINDOW)));
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(avgTick);
        return (uint256(sqrtPrice) * uint256(sqrtPrice) * 1e18) >> 192;
    }

    /// @notice Deposit tokens into the contract
    function depositCollateral(uint256 amount) external {
        require(collateralToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        collateral[msg.sender] += amount;
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        uint256 price = getTWAPPrice();
        uint256 maxLoan = (collateral[msg.sender] * price / 1e18) * LTV / 100;
        require(loans[msg.sender] + amount <= maxLoan, "Over LTV");

        loans[msg.sender] += amount;
        require(loanToken.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(address user) external {
        uint256 price = getTWAPPrice();
        uint256 collValue = collateral[user] * price / 1e18;
        require(loans[user] > collValue * 85 / 100, "Not liquidatable");

        collateral[user] = 0;
        loans[user] = 0;

        require(collateralToken.transfer(msg.sender, collateral[user]), "Transfer failed");
    }
}

// BUG
// TWAP_WINDOW is set to 120 seconds (2 minutes). This is far too short -- an attacker with moderate capital can sustain price
// manipulation across 10-15 blocks to skew a 2-minute TWAP, especially on low-liquidity pools.

// IMPACT
// A manipulated TWAP lets the attacker borrow more than their collateral is worth, creating bad debt for the lending pool.

// INVARIANT
// The TWAP observation window must be long enough that the cost of sustaining price manipulation exceeds the potential profit
// from exploiting the manipulated price.

// WHAT BREAKS
// TWAP_WINDOW = 120 (2 minutes) means only ~10 Ethereum blocks of price history are averaged. On a pool with $500K liquidity,
// sustaining a 2x price deviation for 10 blocks costs roughly $50K in arbitrage losses, but the lending pool may secure $5M in
// loans.

// EXPLOIT PATH
// 1. Pool has $500K liquidity. Attacker targets the 2-minute TWAP
// 2. Attacker swaps $250K to push price 2x for 10 consecutive blocks (~$50K arb cost from others correcting)
// 3. After 2 min, TWAP reflects ~1.8x the true price
// 4. Attacker deposits 1000 collateral, borrows at 1.8x valuation: 1000 * 1.8 * 75% = 1350 loan tokens
// 5. Fair borrow limit: 1000 * 1.0 * 75% = 750. Excess: 600 loan tokens. Net profit: 600 - 50K arb cost
// 6. For $5M pool securing $50M in loans, the ratio is far more profitable.

// WHY MISSED
// The code correctly implements TWAP using Uniswap V3's observe() function with proper tick cumulative math. The vulnerability
// is in the parameter value (120 seconds), not the implementation. Auditors reviewing the TWAP logic may validate the math
// without questioning the window length.

