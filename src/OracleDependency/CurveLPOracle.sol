// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICurvePool {
    /// @notice Performs the get_virtual_price operation for the protocol.
    function get_virtual_price() external view returns (uint256);
    /// @notice Performs the remove_liquidity operation for the protocol.
    function remove_liquidity(uint256 amount, uint256[2] calldata min_amounts) external returns (uint256[2] memory);
}

interface AggregatorV3Interface {
    /// @notice Performs the latestRoundData operation for the protocol.
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

// Is get_virtual_price() safe to call at any time, or can it return a temporarily incorrect value
// during certain Curve pool operations?

// @to-do: technical demonstration of curve read only reentrancy during remove liquidity

/// @title CurveLPOracle
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract CurveLPOracle {
    ICurvePool public immutable curvePool;
    AggregatorV3Interface public immutable ethUsdFeed;
    IERC20 public immutable lpToken;

    mapping(address => uint256) public deposits;

    constructor(address _pool, address _feed, address _lp) {
        curvePool = ICurvePool(_pool);
        ethUsdFeed = AggregatorV3Interface(_feed);
        lpToken = IERC20(_lp);
    }

    /// @notice Get lpprice
    function getLPPrice() public view returns (uint256) {
        uint256 virtualPrice = curvePool.get_virtual_price();
        // virtual price is not checked against anything

        (, int256 ethPrice,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        require(ethPrice > 0 && block.timestamp - updatedAt < 3600, "Bad");
        return (virtualPrice * uint256(ethPrice)) / 1e8;
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        uint256 value = (amount * getLPPrice()) / 1e18;
        require(lpToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        deposits[msg.sender] += value;
    }

    /// @notice Get account value
    function getAccountValue(address user) external view returns (uint256) {
        return deposits[user];
    }
}

// BUG
// getLPPrice() calls curvePool.get_virtual_price(). Curve ETH pools are vulnerable to read-only reentrancy: during
// remove_liquidity, ETH is sent to the caller before pool state is fully updated. If the callback re-enters a contract that
// get_virtual_price(), the virtual price is temporarily inconsistent because LP tokens were burned but the ETH balance was
// not yet reduced.

// IMPACT
// An attacker can deposit LP tokens during the reentrancy window when get_virtual_price() is inflated, receiving a higher
// credited value than their LP tokens are worth.

// INVARIANT
// Oracle price reads must not occur during a callback context where the underlying price source's state is temporarily
// inconsistent.

// WHAT BREAKS
// get_virtual_price() computes the LP token value from the pool's internal balances. During remove_liquidity on Curve ETH pools,
// ETH is transferred to the user via a raw call BEFORE the pool updates its internal accounting. If the receiver's receive()
// function re-enters a contract reading get_virtual_price(), the price is inflated because LP supply decreased but pool balances
// did not yet.

// EXPLOIT PATH
// 1. Curve stETH/ETH pool: get_virtual_price() = 1.05e18 normally
// 2. Attacker contract calls pool.remove_liquidity() with 1000 LP tokens
// 3. Pool burns 1000 LP tokens (totalSupply decreases), then sends ETH to attacker contract
// 4. In attacker's receive() fallback, get_virtual_price() = 1.12e18 (inflated: supply is down but balances are not yet decremented)
// 5. During the callback, attacker calls this contract's deposit() with 500 LP tokens. getLPPrice() returns the inflated 1.12e18 * ethUsdPrice
// 6. deposits[attacker] is credited at the inflated price. After reentrancy completes, get_virtual_price() returns to 1.05e18.
//    Attacker profited the 7% inflation on 500 LP tokens.

// WHY MISSED
// get_virtual_price() is a view function with no obvious reentrancy risk. Read-only reentrancy is counterintuitive because it
// does not modify state in the target contract. The vulnerability is in the Curve pool's execution order during a completely
// separate transaction path.
