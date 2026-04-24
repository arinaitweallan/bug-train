// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LiquidityPool
contract LiquidityPool {
    using SafeERC20 for IERC20;

    IERC20 public tokenA;
    IERC20 public tokenB;
    address public rebalancer;

    uint256 public reserveA;
    uint256 public reserveB;

    bool public rebalancing;

    modifier onlyRebalancer() {
        require(msg.sender == rebalancer, "Not rebalancer");
        _;
    }

    constructor(address _tokenA, address _tokenB, address _rebalancer) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
        rebalancer = _rebalancer;
    }

    /// @notice Add liquidity to the pool
    /// @param amountA Amount a value
    /// @param amountB Amount b value
    function addLiquidity(uint256 amountA, uint256 amountB) external {
        tokenA.safeTransferFrom(msg.sender, address(this), amountA);
        tokenB.safeTransferFrom(msg.sender, address(this), amountB);
        reserveA += amountA;
        reserveB += amountB;
    }

    /// @notice Exchange one token for another
    /// @param tokenIn Token in value
    /// @param amountIn Input token amount
    function swap(address tokenIn, uint256 amountIn) external {
        require(!rebalancing, "Pool rebalancing");
        require(tokenIn == address(tokenA) || tokenIn == address(tokenB), "Invalid token");

        if (tokenIn == address(tokenA)) {
            uint256 amountOut = (amountIn * reserveB) / (reserveA + amountIn);
            tokenA.safeTransferFrom(msg.sender, address(this), amountIn);
            tokenB.safeTransfer(msg.sender, amountOut);
            reserveA += amountIn;
            reserveB -= amountOut;
        } else {
            uint256 amountOut = (amountIn * reserveA) / (reserveB + amountIn);
            tokenB.safeTransferFrom(msg.sender, address(this), amountIn);
            tokenA.safeTransfer(msg.sender, amountOut);
            reserveB += amountIn;
            reserveA -= amountOut;
        }
    }

    /// @notice Start rebalance
    function startRebalance() external onlyRebalancer {
        rebalancing = true;
    }

    /// @notice Rebalance portfolio allocations
    /// @param newReserveA New reserve a value
    /// @param newReserveB New reserve b value
    function rebalancePostHook(uint256 newReserveA, uint256 newReserveB) external {
        require(rebalancing, "Not rebalancing");

        reserveA = newReserveA;
        reserveB = newReserveB;
        rebalancing = false;
    }

    /// @notice Get reserves
    function getReserves() external view returns (uint256, uint256) {
        return (reserveA, reserveB);
    }
}

// INVARIANT
// Only the authorized rebalancer should be able to set reserve values during rebalancing.

// WHAT BREAKS
// rebalancePostHook is protected only by a require(rebalancing) state check, not by an onlyRebalancer modifier. When the 
// rebalancer calls startRebalance, any address can front-run or follow with rebalancePostHook, setting reserves to extreme 
// values. The attacker then swaps at the manipulated price to drain real tokens.

// EXPLOIT PATH
// 1. Pool has reserveA = 1,000,000 USDC, reserveB = 500 ETH (ETH = $2,000)
// 2. Rebalancer calls startRebalance(). rebalancing = true
// 3. Attacker calls rebalancePostHook(1, 500) setting reserveA = 1 USDC, reserveB = 500 ETH
// 4. rebalancing = false. Pool thinks 1 USDC = 500 ETH
// 5. Attacker calls swap(tokenA, 1_000_000e6) paying 1M USDC. amountOut = (1M * 500) / (1 + 1M) ~= 499.999 ETH
// 6. Attacker receives ~500 ETH ($1,000,000) for 1M USDC that buys them at par with real reserves, draining all ETH
// 7. Actual token balances are unchanged from the real state; only accounting (reserves) was manipulated.

// WHY MISSED
// startRebalance is correctly protected with onlyRebalancer, and rebalancePostHook has a require(rebalancing) guard that 
// makes it look like it can only be called during authorized rebalancing. Auditors see the two-phase pattern and assume 
// both phases share the same access control, but only the first phase checks the caller.
