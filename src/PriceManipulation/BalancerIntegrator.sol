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
