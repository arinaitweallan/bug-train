// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// test purposes
import {Test, console2} from "forge-std/Test.sol";

/// @title SimpleLiquidityPool
/// @notice Automated market maker contract that provides on-chain liquidity and swap routing.
contract SimpleLiquidityPool {
    using SafeERC20 for IERC20;

    IERC20 public token0;
    IERC20 public token1;

    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public totalShares;

    mapping(address => uint256) public shares;
    bool public initialized;

    /// @notice Initialize contract state
    /// @param _token0 Token0 value
    /// @param _token1 Token1 value
    function initialize(address _token0, address _token1) external {
        require(!initialized, "Already initialized");

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        initialized = true;
        // assume its initialized during deployment
    }

    /// @notice Add initial liquidity (first deposit)
    /// @param amount0 Amount0 value
    /// @param amount1 Amount1 value

    // @check: user mints liquidity with unproportional amounts
    function addInitialLiquidity(uint256 amount0, uint256 amount1) external {
        require(initialized, "Not initialized");
        require(totalShares == 0, "Use addLiquidity");
        require(amount0 > 0 && amount1 > 0, "Zero amounts");

        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);
        reserve0 = amount0; // 1
        reserve1 = amount1; // 1e35

        // q can this return zero as an answer?
        uint256 liquidity = sqrt(amount0 * amount1);
        shares[msg.sender] = liquidity; // 5e34
        totalShares = liquidity; // 5e34
    }

    /// @notice Add liquidity to the pool
    /// @param amount0Max Amount0 max value
    /// @param amount1Max Amount1 max value
    function addLiquidity(uint256 amount0Max, uint256 amount1Max) external {
        require(totalShares > 0, "Use addInitialLiquidity");
        uint256 amount1Optimal = (amount0Max * reserve1) / reserve0;
        require(amount1Optimal <= amount1Max, "Exceeds amount1Max");
        uint256 mintShares = (amount0Max * totalShares) / reserve0;

        token0.safeTransferFrom(msg.sender, address(this), amount0Max);
        token1.safeTransferFrom(msg.sender, address(this), amount1Optimal);
        reserve0 += amount0Max;
        reserve1 += amount1Optimal;
        shares[msg.sender] += mintShares;
        totalShares += mintShares;
    }

    /// @notice Get price
    function getPrice() external view returns (uint256) {
        require(reserve0 > 0, "Empty pool");
        return (reserve1 * 1e18) / reserve0;
    }

    function sqrt(uint256 x)
        /**
         * internal
         */
        public
        pure
        returns (uint256 y)
    {
        if (x == 0) return 0;
        // x = 1e18
        // y = 1e18
        // z = (1e18 + 1) / 2 = 5e17
        // while (5e17 < 1e18) y = 5e17
        // z = (1e18 / 5e17 + 5e17) / 2 = 250000000000000001

        // while (250000000000000001 < 5e17) y = 250000000000000001
        // z = (1e18 / 250000000000000001 + 250000000000000001) / 2 = 1.25e17
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) y = z;
        z = (x / z + z) / 2;
    }
}

contract TestSqrt is Test {
    SimpleLiquidityPool pool;

    function setUp() public {
        pool = new SimpleLiquidityPool();
    }

    function testSqrt( /*uint256 a, uint256 b*/ ) public view {
        uint256 a = 1;
        uint256 b = 1e35;
        // vm.assume(a < 1e27 && b < 1e27);
        // vm.assume(a > 0 && b > 0);
        uint256 x = a * b;
        uint256 y = pool.sqrt(x);

        require(y != 0, "y is equal to zero");

        console2.log("y is: ", y);
    }
}

// BUG
// initialize() is permissionless — anyone can call it. An attacker can front-run the intended deployer's initialize transaction
// to set token addresses, or front-run addInitialLiquidity to set an arbitrary price ratio.

// IMPACT
// addInitialLiquidity sets the price ratio (reserve0:reserve1). An attacker who front-runs with a skewed ratio (e.g., 1 wei : 1M tokens)
// forces the legitimate depositor to add liquidity at a bad ratio or lose value to arbitrage.

// INVARIANT
// Pool initialization and initial liquidity provision must be atomic or access-restricted so only the intended deployer sets the
// initial price ratio.

// WHAT BREAKS
// Anyone can front-run the deployment sequence to set an arbitrary initial price ratio, causing the legitimate deployer to
// deposit at a manipulated rate and lose funds to immediate arbitrage.

// EXPLOIT PATH
// 1. Deployer creates pool contract. Plans to initialize with token0=WETH (18 dec), token1=USDC (6 dec) at ratio 1 WETH = 2000 USDC
// 2. Deployer sends tx1: initialize(WETH, USDC). Attacker sees this in mempool
// 3. Attacker front-runs: calls initialize (or waits) then immediately sends addInitialLiquidity(1, 1) setting the pool ratio to 1:1 in raw units
// 4. Deployer's addInitialLiquidity(10e18 WETH, 20000e6 USDC) reverts because totalShares != 0. Deployer must use addLiquidity instead
// 5. Deployer calls addLiquidity(10e18, ...). amount1Optimal = 10e18 * 1 / 1 = 10e18. But USDC has 6 decimals, so 10e18 raw USDC = 10 trillion USDC. The require(amount1Optimal <= amount1Max) would revert unless deployer passes a huge amount1Max
// 6. If deployer sets amount1Max high enough (not realizing the ratio is wrong), they deposit 10e18 raw USDC at a 1:1 ratio with WETH. Attacker removes their LP and arbitrages the mispriced pool, extracting the excess.

// WHY MISSED
// Auditors may verify that the pool math is correct once initialized but fail to consider the initialization sequence as an
// attack surface. The two-step deploy-then-initialize pattern is common and the front-running window between the transactions
// is easy to overlook.
