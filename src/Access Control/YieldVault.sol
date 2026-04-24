// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title YieldVault
contract YieldVault {
    using SafeERC20 for IERC20;

    address public owner;
    IERC20 public asset;
    address public yieldStrategy;

    uint256 public totalDeposited;

    mapping(address => uint256) public deposits;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _asset, address _strategy) {
        owner = msg.sender;
        asset = IERC20(_asset);
        yieldStrategy = _strategy;
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(amount > 0, "Zero amount");
        asset.safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] += amount;
        totalDeposited += amount;
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 amount) external {
        require(deposits[msg.sender] >= amount, "Insufficient balance");

        deposits[msg.sender] -= amount;
        totalDeposited -= amount;
        asset.safeTransfer(msg.sender, amount);
    }

    /// @notice Configure a contract parameter
    function setYieldStrategy(address _newStrategy) external {
        // missing access control
        require(_newStrategy != address(0), "Zero address");
        yieldStrategy = _newStrategy;
    }

    /// @notice Harvest and compound rewards
    function harvestYield() external onlyOwner {
        uint256 balance = asset.balanceOf(address(this));
        uint256 surplus = balance - totalDeposited;
        if (surplus > 0) {
            asset.safeTransfer(yieldStrategy, surplus);
        }
    }

    /// @notice Get vault balance
    function getVaultBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}
