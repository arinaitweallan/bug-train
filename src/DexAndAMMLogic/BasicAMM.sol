// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Test, console2} from "forge-std/Test.sol";
import {Token} from "test/mocks/Token.sol";

/// @title BasicAMM
/// @notice Automated market maker contract that provides on-chain liquidity and swap routing.
contract BasicAMM {
    using SafeERC20 for IERC20;

    IERC20 public token0;
    IERC20 public token1;

    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public totalLP;

    mapping(address => uint256) public lp;

    constructor(address _t0, address _t1) {
        token0 = IERC20(_t0);
        token1 = IERC20(_t1);
    }

    /// @notice Add liquidity to the pool
    /// @param amount0 Amount0 value
    /// @param amount1 Amount1 value
    function addLiquidity(uint256 amount0, uint256 amount1) external returns (uint256 lpMint) {
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        if (totalLP == 0) {
            lpMint = amount0 + amount1;
        } else {
            uint256 lp0 = (amount0 * totalLP) / reserve0;
            uint256 lp1 = (amount1 * totalLP) / reserve1;
            lpMint = lp0 < lp1 ? lp0 : lp1;
        }

        reserve0 += amount0;
        reserve1 += amount1;
        lp[msg.sender] += lpMint;
        totalLP += lpMint;
    }

    /// @notice Exchange one token for another
    /// @param tokenIn Token in value
    /// @param amountIn Input token amount
    function swap(address tokenIn, uint256 amountIn) external returns (uint256 amountOut) {
        require(tokenIn == address(token0) || tokenIn == address(token1), "Bad token");

        bool isToken0 = tokenIn == address(token0);
        IERC20 inToken = isToken0 ? token0 : token1;
        inToken.safeTransferFrom(msg.sender, address(this), amountIn);

        if (isToken0) {
            amountOut = (amountIn * reserve1) / (reserve0 + amountIn);
            reserve0 += amountIn;
            reserve1 -= amountOut;
            token1.safeTransfer(msg.sender, amountOut);
        } else {
            amountOut = (amountIn * reserve0) / (reserve1 + amountIn);
            reserve1 += amountIn;
            reserve0 -= amountOut;
            token0.safeTransfer(msg.sender, amountOut);
        }
    }

    /// @notice Remove liquidity from the pool
    function removeLiquidity(uint256 lpAmount) external {
        uint256 out0 = (lpAmount * reserve0) / totalLP;
        uint256 out1 = (lpAmount * reserve1) / totalLP;

        lp[msg.sender] -= lpAmount;
        totalLP -= lpAmount;
        reserve0 -= out0;
        reserve1 -= out1;

        token0.safeTransfer(msg.sender, out0);
        token1.safeTransfer(msg.sender, out1);
    }
}

contract AMMTest is Test {
    BasicAMM amm;
    Token token0;
    Token token1;

    function setUp() external {
        token0 = new Token("Token0", "tk0");
        token1 = new Token("Token1", "tk1");
        amm = new BasicAMM(address(token0), address(token1));
    }

    function testFirstAddLiquidity() external {
        address user = address(0x234);

        uint256 amount = 10_000_000 ether;
        token0.mint(user, amount);
        token1.mint(user, amount);

        vm.startPrank(user);
        uint256 useAmount = 1;
        token0.approve(address(amm), type(uint128).max);
        token1.approve(address(amm), type(uint128).max);
        amm.addLiquidity(useAmount, useAmount);
        vm.stopPrank();

        // check accounting
        uint256 _reserve0 = amm.reserve0();
        uint256 _reserve1 = amm.reserve1();
        uint256 _totalLp = amm.totalLP();

        // user now inflates reserves without increasing LP
        vm.startPrank(user);
        uint256 useAmount1 = 1e10;
        token0.approve(address(amm), type(uint128).max);
        token1.approve(address(amm), type(uint128).max);
        amm.addLiquidity(0, useAmount1);
        vm.stopPrank();

        // check accounting
        uint256 __reserve0 = amm.reserve0();
        uint256 __reserve1 = amm.reserve1();
        uint256 __totalLp = amm.totalLP();

        console2.log("Reserve 0: ", _reserve0);
        console2.log("Reserve 1: ", _reserve1);
        console2.log("Total LP: ", _totalLp);

        console2.log("Reserve 0: ", __reserve0);
        console2.log("Reserve 1: ", __reserve1);
        console2.log("Total LP: ", __totalLp);
    }
}

// BUG
// addLiquidity uses the input parameters amount0 and amount1 to update reserves instead of measuring actual received amounts.
// For fee-on-transfer tokens, the contract receives less than amount0/amount1 but credits the full amount to reserves.

// IMPACT
// swap also uses amountIn to update reserves. If token0 has a transfer tax, the pool receives less than amountIn but reserves
// track the full amount. Over time, reserve tracking diverges from actual balance, and LP withdrawals will fail or drain real
// tokens disproportionately.

// INVARIANT
// Internal reserve tracking must equal actual token balances. For fee-on-transfer tokens, the credited amount must reflect
// actual tokens received, not the requested transfer amount.

// WHAT BREAKS
// Reserves overstate actual token balances by the cumulative fee-on-transfer amount. Eventually, reserve-based calculations
// output more tokens than the contract holds, allowing last withdrawers to drain all remaining real tokens or causing reverts.

// EXPLOIT PATH
// 1. token0 has 5% transfer fee. Pool starts empty
// 2. Alice adds liquidity: amount0=1000, amount1=1000. Contract receives 950 token0 (50 burned as fee) and 1000 token1. But reserve0=1000, reserve1=1000
// 3. Bob swaps 100 token1 for token0. amountOut = 100 * 1000 / (1000 + 100) = 90.9 token0. reserve0 becomes 909.1, but actual balance is 950 - 90.9 = 859
// 1. Gap: 50
// 4. Charlie adds liquidity: 500 token0 (receives 475). reserve0 += 500 = 1409
// 1. Actual balance: 859.1 + 475 = 1334
// 1. Gap: 75
// 5. When Alice removes liquidity, she gets proportional to reserve0=1409, but actual balance is only 1334. Eventually a withdrawal will revert when reserve0 exceeds actual balance.

// WHY MISSED
// The pattern of using the input amount to update reserves is standard in Uniswap V2 for normal ERC20 tokens. Auditors familiar
// with the Uniswap pattern may not consider that some tokens deduct fees during transfer, creating a divergence between the
// credited and actual amounts.
