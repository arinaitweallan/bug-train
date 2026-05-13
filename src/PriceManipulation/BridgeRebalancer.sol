// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @title BridgeRebalancer
contract BridgeRebalancer {
    IUniswapV3Pool public immutable pool;
    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    
    address public admin;
    uint256 public constant REBALANCE_THRESHOLD = 110;

    constructor(address _pool, address _tokenA, address _tokenB) {
        pool = IUniswapV3Pool(_pool);
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
        admin = msg.sender;
    }

    /// @notice Get price
    function getPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
        return price;
    }

    /// @notice Rebalance portfolio allocations
    function rebalance(uint256 amountIn) external {
        // price = 1e18
        uint256 price = getPrice();
        // valueA = 1000e18 * 1e18 / 1e18 = 1000e18
        uint256 valueA = tokenA.balanceOf(address(this)) * price / 1e18;
        // valueB = 1050e18
        uint256 valueB = tokenB.balanceOf(address(this));

        // 1000e18 * 100 / 1050e18 > 110 || 1050e18 * 100 / 1000e18 > 110
        // 95 > 110 || 105 > 110
        require(valueA * 100 / valueB > REBALANCE_THRESHOLD || valueB * 100 / valueA > REBALANCE_THRESHOLD, "Balanced");

        uint256 amountOut = amountIn * price / 1e18;
        require(tokenA.transferFrom(msg.sender, address(this), amountIn), "Transfer failed");
        require(tokenB.transfer(msg.sender, amountOut), "Transfer failed");
    }

    /// @notice Deposit tokens into the contract
    /// @param token Token contract address
    /// @param amount Token amount
    function deposit(address token, uint256 amount) external {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
    }

    /// @notice Admin withdraw
    /// @param token Token contract address
    /// @param amount Token amount
    function adminWithdraw(address token, uint256 amount) external {
        require(msg.sender == admin, "Not admin");
        require(IERC20(token).transfer(admin, amount), "Transfer failed");
    }
}

// BUG
// getPrice() reads sqrtPriceX96 directly from pool.slot0(). This is the instantaneous spot price that reflects the last trade. 
// An attacker can manipulate it within a single transaction via a flash-loan-funded swap.

// IMPACT
// The manipulated price feeds into rebalance(), allowing the attacker to swap tokenA for tokenB at an artificially favorable 
// rate, draining protocol funds.

// INVARIANT
// Price used in rebalance operations must not be manipulable within a single transaction.

// WHAT BREAKS
// getPrice() reads the instantaneous sqrtPriceX96 from slot0() which can be moved to any value by swapping a large amount in 
// the Uniswap pool. The rebalance() function trusts this price to compute exchange rates.

// EXPLOIT PATH
// 1. Pool has 100 tokenA and 100 tokenB. Fair price is 1:1
// 2. Attacker flash-loans 10,000 tokenA and swaps into the Uniswap pool, moving slot0 price to 10:1 (tokenA appears 10x more valuable)
// 3. Attacker calls rebalance(10) with 10 tokenA. amountOut = 10 * 10 = 100 tokenB
// 4. Attacker receives 100 tokenB for 10 tokenA (actual fair value: 10 tokenB)
// 5. Attacker swaps back in the pool, repays flash loan. Net profit: ~90 tokenB.

// WHY MISSED
// The code structure looks clean with a separate getPrice() function and proper threshold checks. The slot0() call returns many 
// fields, masking the fact that sqrtPriceX96 is trivially manipulable. Auditors may focus on the rebalance logic rather than 
// questioning the price source.