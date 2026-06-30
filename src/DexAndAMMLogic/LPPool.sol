// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LPPool
/// @notice Automated market maker contract that provides on-chain liquidity and swap routing.
contract LPPool {
    using SafeERC20 for IERC20;

    IERC20 public underlying;

    uint256 public totalShares;
    uint256 public totalDeposited;

    mapping(address => uint256) public shares;

    constructor(address _underlying) {
        underlying = IERC20(_underlying);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external returns (uint256 mintShares) {
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        if (totalShares == 0) {
            mintShares = amount;
        } else {
            // mintShares = 1e18 * 1 / 1
            mintShares = (amount * totalShares + totalDeposited - 1) / totalDeposited;
        }

        shares[msg.sender] += mintShares;
        totalShares += mintShares;
        totalDeposited += amount;
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 shareAmount) external returns (uint256 assets) {
        require(shares[msg.sender] >= shareAmount, "Insufficient shares");
        assets = (shareAmount * totalDeposited + totalShares - 1) / totalShares;
        require(assets <= totalDeposited, "Exceeds pool");
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalDeposited -= assets;
        underlying.safeTransfer(msg.sender, assets);
    }

    /// @notice Price per share
    function pricePerShare() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalDeposited * 1e18) / totalShares;
    }

    /// @notice Preview redeem
    function previewRedeem(uint256 shareAmount) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shareAmount * totalDeposited + totalShares - 1) / totalShares;
    }
}
