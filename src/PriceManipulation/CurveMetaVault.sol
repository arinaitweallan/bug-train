// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICurvePool {
    function get_virtual_price() external view returns (uint256);
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external payable;
    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 _min_amount) external;
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title CurveMetaVault
contract CurveMetaVault {
    ICurvePool public immutable curvePool;
    IERC20 public immutable lpToken;
    IERC20 public immutable stablecoin;
    AggregatorV3Interface public immutable priceFeed;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public borrowed;

    constructor(address _pool, address _lp, address _stable, address _feed) {
        curvePool = ICurvePool(_pool);
        lpToken = IERC20(_lp);
        stablecoin = IERC20(_stable);
        priceFeed = AggregatorV3Interface(_feed);
    }

    /// @notice Get lpvalue
    function getLPValue(uint256 lpAmount) public view returns (uint256) {
        uint256 virtualPrice = curvePool.get_virtual_price();
        return lpAmount * virtualPrice / 1e18;
    }

    /// @notice Deposit tokens into the contract
    function depositLP(uint256 amount) external {
        require(lpToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        deposits[msg.sender] += amount;
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        uint256 collateralValue = getLPValue(deposits[msg.sender]);
        uint256 maxBorrow = collateralValue * 70 / 100;

        require(borrowed[msg.sender] + amount <= maxBorrow, "Over limit");
        borrowed[msg.sender] += amount;
        require(stablecoin.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(address user) external {
        uint256 value = getLPValue(deposits[user]);
        require(borrowed[user] > value * 85 / 100, "Not liquidatable");

        uint256 seized = deposits[user];
        deposits[user] = 0;
        borrowed[user] = 0;
        require(lpToken.transfer(msg.sender, seized), "Transfer failed");
    }
}

// BUG
// getLPValue() uses curvePool.get_virtual_price() which reads from pool balances. For ETH-based Curve pools, during
// add_liquidity/remove_liquidity callbacks, the virtual_price can be read in a mid-update state via read-only reentrancy,
// returning an inflated value.

// IMPACT
// An inflated virtual_price makes collateralValue higher than reality, allowing the attacker to borrow more stablecoins than
// their LP tokens are actually worth.

// INVARIANT
// The virtual price used for collateral valuation must not be readable in an inconsistent state during pool operations.

// WHAT BREAKS
// get_virtual_price() reads pool balances that are mid-update during ETH-based add/remove liquidity. The attacker triggers
// add_liquidity with ETH, and during the ETH transfer callback, calls borrow() which reads the inflated virtual_price.

// EXPLOIT PATH
// 1. Curve pool has $10M TVL. Normal virtual_price = 1.05e18
// 2. Attacker calls add_liquidity with 5M ETH. Pool sends ETH back (remove_liquidity callback path)
// 3. During the callback, pool balances include the 5M but internal accounting hasn't updated. get_virtual_price() returns 1.55e18
// 4. Attacker calls borrow() in the callback. collateralValue = deposits * 1.55 instead of 1.05 (47% inflation)
// 5. Attacker borrows 47% more stablecoins than their LP is worth. After callback completes, virtual_price normalizes.

// WHY MISSED
// get_virtual_price() is a view function that appears safe. The read-only reentrancy attack vector is non-obvious because the
// vulnerability is in a VIEW function being called during a WRITE operation's callback, which traditional reentrancy guards
// do not cover.
