// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Balancer Pool Integrator

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBalancerVault {
    function joinPool(bytes32 poolId, address sender, address recipient, JoinPoolRequest memory request)
        external
        payable;

    struct JoinPoolRequest {
        address[] assets;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }
}

interface IBalancerPool {
    function getRate() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title BalancerIntegrator
contract BalancerIntegrator {
    IBalancerVault public immutable vault;
    IBalancerPool public immutable bptPool;

    IERC20 public immutable bptToken;
    IERC20 public immutable stablecoin;

    mapping(address => uint256) public bptDeposits;
    mapping(address => uint256) public borrowed;

    constructor(address _vault, address _pool, address _bpt, address _stable) {
        vault = IBalancerVault(_vault);
        bptPool = IBalancerPool(_pool);
        bptToken = IERC20(_bpt);
        stablecoin = IERC20(_stable);
    }

    /// @notice Get bptvalue
    function getBPTValue(uint256 amount) public view returns (uint256) {
        uint256 rate = bptPool.getRate();
        return amount * rate / 1e18;
    }

    /// @notice Deposit tokens into the contract
    function depositBPT(uint256 amount) external {
        require(bptToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        bptDeposits[msg.sender] += amount;
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        uint256 value = getBPTValue(bptDeposits[msg.sender]);
        uint256 maxBorrow = value * 70 / 100;
        require(borrowed[msg.sender] + amount <= maxBorrow, "Over LTV");
        borrowed[msg.sender] += amount;
        require(stablecoin.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(address user) external {
        uint256 value = getBPTValue(bptDeposits[user]);
        require(borrowed[user] > value * 85 / 100, "Healthy");
        uint256 seized = bptDeposits[user];
        bptDeposits[user] = 0;
        borrowed[user] = 0;
        require(bptToken.transfer(msg.sender, seized), "Transfer failed");
    }

    receive() external payable {}
}

// BUG
// getBPTValue() reads bptPool.getRate() which computes the BPT rate from current pool invariant and total supply. During a
// Balancer pool join/exit with ETH, the pool sends ETH before updating its internal state. In the ETH receive callback,
// getRate() returns a temporarily inflated value.

// IMPACT
// During the read-only reentrancy window, the attacker calls borrow() which reads the inflated getRate(), allowing them to
// borrow more than their BPT collateral is actually worth.

// INVARIANT
// Pool rate functions must not be readable in an inconsistent state during pool operations that trigger ETH callbacks.

// WHAT BREAKS
// getBPTValue() trusts getRate() at all times. During a Balancer pool join/exit with native ETH, the vault sends ETH before
// updating pool accounting. If this contract's receive() is called during that window, getRate() returns an inflated rate.

// EXPLOIT PATH
// 1. Attacker deposits 100 BPT (fair rate: 1.05). bptDeposits = 100. Value = 105
// 2. Attacker initiates a large Balancer pool exit with ETH as one of the assets
// 3. During the ETH transfer to the attacker's contract, pool balances are reduced but invariant hasn't been recalculated. getRate() returns 1.50 (temporarily inflated)
// 4. In the receive() callback, attacker calls borrow(). value = 100 * 1.50 = 150. maxBorrow = 105
// 5. Attacker borrows 105 stablecoins against 100 BPT actually worth 105. 0% overcollateralized instead of 30%
// 6. If rate inflation is higher (e.g., 2.0), attacker borrows 140 against 105 collateral = 35 bad debt.

// WHY MISSED
// Read-only reentrancy is a non-obvious attack vector because getRate() is a view function and the vulnerability occurs in a
// contract that is NOT being directly called -- it is a passive recipient of an ETH callback from a different operation.
// Traditional reentrancy analysis focuses on state-modifying callbacks.
