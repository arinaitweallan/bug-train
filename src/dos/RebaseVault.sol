// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// stETH Rounding Shortfall Reverts Vault Rebalance

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RebaseVault
contract RebaseVault {
    IERC20 public stETH;
    address public strategy;
    address public owner;

    uint256 public totalManaged;

    mapping(address => uint256) public userDeposits;

    event Deposited(address indexed user, uint256 amount);
    event Rebalanced(uint256 amount);
    event Harvested(uint256 profit);

    constructor(address _stETH, address _strategy) {
        stETH = IERC20(_stETH);
        strategy = _strategy;
        owner = msg.sender;
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(amount > 0, "Zero amount");
        require(stETH.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        userDeposits[msg.sender] += amount;
        totalManaged += amount;

        emit Deposited(msg.sender, amount);
    }

    /// @notice Rebalance portfolio allocations
    function rebalance(uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        require(amount <= totalManaged, "Exceeds managed");
        require(stETH.transfer(strategy, amount), "Transfer failed");

        uint256 strategyBalance = stETH.balanceOf(strategy);
        require(strategyBalance >= amount, "Strategy did not receive full amount");
        totalManaged -= amount;

        emit Rebalanced(amount);
    }

    /// @notice Harvest and compound rewards
    function harvest(uint256 profit) external {
        require(msg.sender == strategy, "Not strategy");
        require(stETH.transferFrom(strategy, address(this), profit), "Transfer failed");

        totalManaged += profit;
        emit Harvested(profit);
    }

    /// @notice Get vault balance
    function getVaultBalance() external view returns (uint256) {
        return stETH.balanceOf(address(this));
    }

    /// @notice Get strategy balance
    function getStrategyBalance() external view returns (uint256) {
        return stETH.balanceOf(strategy);
    }
}

// INVARIANT
// Rebalance must succeed when transferring rebasing tokens that have inherent rounding behavior

// WHAT BREAKS
// stETH uses an internal shares mechanism where balance = shares * totalPooledEther / totalShares. This means
// transfer(strategy, amount) may credit the strategy with amount - 1 or amount - 2 wei due to integer division rounding.
// The require(strategyBalance >= amount) at line 29 fails because strategyBalance == amount - 1. Rebalance reverts
// intermittently, blocking all strategy deployment.

// EXPLOIT PATH
// 1. Vault holds 1,000e18 stETH. Owner calls rebalance(500e18)
// 2. stETH.transfer(strategy, 500e18) executes internally as: shares = 500e18 * totalShares / totalPooledEther, then credits strategy with shares * totalPooledEther / totalShares = 499999999999999999999 (1 wei less due to rounding)
// 3. strategyBalance = 499999999999999999999
// 4. require(499999999999999999999 >= 500e18) fails
// 5. Rebalance permanently reverts for any amount where stETH rounding produces a shortfall
// 6. Funds are stuck in the vault and cannot be deployed to the strategy.

// WHY MISSED
// The rounding is 1-2 wei on an 18-decimal token, which seems insignificant. Auditors treating stETH as a standard ERC20 miss
// that the exact-amount check fails due to sub-wei rounding inherent to rebasing tokens.
