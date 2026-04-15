// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LiquidityPoolLauncher
contract LiquidityPoolLauncher {
    using SafeERC20 for IERC20;

    struct Pool {
        address token0;
        address token1;
        uint256 sqrtPriceX96;
        uint256 totalLiquidity;
        bool initialized;
    }

    mapping(bytes32 => Pool) public pools;
    address public admin;

    constructor() {
        admin = msg.sender;
    }

    /// @notice Create a new entry or position
    /// @param tokenA Token a value
    /// @param tokenB Token b value
    function createPool(address tokenA, address tokenB) external returns (bytes32 poolId) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // generate pool id
        // q what if t0 == t1?
        // q what id user intentionally sets token0 to zero address to dos the pools that use token0?
        poolId = keccak256(abi.encodePacked(t0, t1));
        require(!pools[poolId].initialized, "Pool exists");

        // only state changes
        // no poolId to Pool mapping state change
        pools[poolId].token0 = t0;
        pools[poolId].token1 = t1;
    }

    // q creating and initializing a pool, what should happen first?

    /// @notice Initialize contract state
    /// @param poolId Pool id value
    /// @param _sqrtPriceX96 Sqrt price x96 value
    function initializePool(bytes32 poolId, uint256 _sqrtPriceX96) external {
        Pool storage pool = pools[poolId];

        require(pool.token0 != address(0), "Pool not created");
        require(!pool.initialized, "Already initialized");
        require(_sqrtPriceX96 > 0, "Zero price");

        pool.sqrtPriceX96 = _sqrtPriceX96;
        pool.initialized = true;
    }

    /// @notice Add liquidity to the pool
    /// @param poolId Pool id value
    /// @param amount0 Amount0 value
    /// @param amount1 Amount1 value
    function addLiquidity(bytes32 poolId, uint256 amount0, uint256 amount1) external {
        Pool storage pool = pools[poolId];
        require(pool.initialized, "Not initialized");

        IERC20(pool.token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(pool.token1).safeTransferFrom(msg.sender, address(this), amount1);
        pool.totalLiquidity += amount0 + amount1;
    }

    /// @notice Get pool price
    function getPoolPrice(bytes32 poolId) external view returns (uint256) {
        return pools[poolId].sqrtPriceX96;
    }
}

// INVARIANT
// Pool initialization price must be validated against a trusted oracle or restricted to authorized callers to prevent
// manipulation.

// WHAT BREAKS
// Anyone can call initializePool with an arbitrary sqrtPriceX96. An attacker sets the initial price to 1000x the real market
// rate. When legitimate LPs add liquidity at the skewed price, they deposit the wrong token ratio. Arbitrageurs then correct
// the price, extracting value from the LP deposits.

// EXPLOIT PATH
// 1. Admin calls createPool(WETH, USDC). Pool is created but uninitialized
// 2. Real WETH price: $3,000. Correct sqrtPriceX96 = ~4.33e30
// 3. Attacker calls initializePool(poolId, 4.33e33) setting price to $3,000,000 per WETH (1000x inflated)
// 4. LP calls addLiquidity(poolId, 10e18, 30000000e6) depositing 10 WETH + 30M USDC at inflated rate
// 5. Arbitrageur buys cheap WETH from the pool, extracting millions in USDC
// 6. LP loses most of their 30M USDC deposit to the arbitrageur.
