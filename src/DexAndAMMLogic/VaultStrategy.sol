// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPool {
    /// @notice Performs the getReserves operation for the protocol.
    function getReserves() external view returns (uint256, uint256);
}

/// @title VaultStrategy
/// @notice Automated market maker contract that provides on-chain liquidity and swap routing.
contract VaultStrategy {
    using SafeERC20 for IERC20;

    IERC20 public tokenA;
    IERC20 public tokenB;
    IPool public pool;
    address public manager;

    uint256 public cachedPriceA; // price of A in terms of B, scaled 1e18
    uint256 public lastPriceUpdate;
    uint256 public totalValueManaged;

    mapping(address => uint256) public userDeposits;

    constructor(address _a, address _b, address _pool) {
        tokenA = IERC20(_a);
        tokenB = IERC20(_b);
        pool = IPool(_pool);
        manager = msg.sender;
        _refreshPrice();
    }

    function _refreshPrice() internal {
        (uint256 resA, uint256 resB) = pool.getReserves();
        cachedPriceA = (resB * 1e18) / resA;
        lastPriceUpdate = block.timestamp;
    }

    /// @notice Refresh price
    function refreshPrice() external {
        _refreshPrice();
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amountA) external {
        tokenA.safeTransferFrom(msg.sender, address(this), amountA);
        // q why are we using the cached price?
        uint256 valueInB = (amountA * cachedPriceA) / 1e18;
        userDeposits[msg.sender] += valueInB;
        totalValueManaged += valueInB;
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 valueInB) external {
        require(userDeposits[msg.sender] >= valueInB, "Insufficient");
        uint256 amountA = (valueInB * 1e18) / cachedPriceA;
        require(tokenA.balanceOf(address(this)) >= amountA, "Low balance");
        userDeposits[msg.sender] -= valueInB;
        totalValueManaged -= valueInB;
        tokenA.safeTransfer(msg.sender, amountA);
    }

    /// @notice Get total value
    function getTotalValue() external view returns (uint256) {
        return totalValueManaged;
    }

    /// @notice Get cached price
    function getCachedPrice() external view returns (uint256) {
        return cachedPriceA;
    }
}

// BUG
// deposit() uses cachedPriceA to value deposits. refreshPrice() is a separate permissionless call. deposit/withdraw do NOT
// refresh the price before using it. The cached price can be manipulated by calling refreshPrice() during a flash-loan pool
// manipulation.

// IMPACT
// An attacker manipulates pool reserves to inflate cachedPriceA (making tokenA appear expensive). Depositing at inflated price
// records a high valueInB. After price returns to normal, withdrawing that valueInB converts back to far more tokenA than
// originally deposited. totalValueManaged tracks value in B units, creating asymmetric deposit/withdraw rates.

// NVARIANT
// Prices used for deposit/withdrawal valuation must reflect current market state, not a cached snapshot that can diverge from
// reality.

// WHAT BREAKS
// An attacker caches an inflated price by calling refreshPrice() after manipulating pool reserves to make tokenA appear expensive
// in tokenB terms. Then deposits tokenA at the inflated valuation. After the price is refreshed back to normal, the attacker
// withdraws far more tokenA than deposited.

// EXPLOIT PATH
// 1. Pool reserves: resA=1,000,000, resB=1,000,000. cachedPriceA = 1e18 (1:1). Vault has 500,000 tokenA
// 2. Attacker flash-loans 9,000,000 tokenB, swaps into pool to buy tokenA. New reserves: resA = 1e12 / 10,000,000 = 100,000, resB = 10,000,000. Price of A in B = 10,000,000 * 1e18 / 100,000 = 100e18 (A is 100x expensive)
// 3. Attacker calls refreshPrice(). cachedPriceA = 100e18
// 4. Attacker swaps back to restore pool, repays flash loan
// 5. Attacker deposits 1,000 tokenA. valueInB = 1,000 * 100e18 / 1e18 = 100,000. userDeposits[attacker] = 100,000
// 6. Someone calls refreshPrice(). cachedPriceA returns to ~1e18
// 7. Attacker withdraws 100,000 valueInB. amountA = 100,000 * 1e18 / 1e18 = 100,000 tokenA
// 8. Net: deposited 1,000 tokenA, withdrew 100,000 tokenA. Profit: 99,000 tokenA stolen from vault.

// WHY MISSED
// The caching pattern is a common gas optimization. Auditors may check that refreshPrice exists and correctly reads reserves,
// without verifying that every function that reads the cache also refreshes it. The staleness window between refreshPrice()
// calls is the attack surface. Additionally, totalValueManaged tracks value in B units but withdraw converts back to A units
// using the cached price, creating asymmetric accounting that amplifies the manipulation.
