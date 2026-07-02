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

// BUG
// Deposit rounds UP shares minted: (amount * totalShares + totalDeposited - 1) / totalDeposited. This gives the depositor MORE
// shares than their fair proportion. Rounding should favor the pool (round down) on deposits.

// IMPACT
// Withdrawal also rounds UP assets returned: (shareAmount * totalDeposited + totalShares - 1) / totalShares. Combined, both
// deposit and withdrawal round in the user's favor. Each deposit-withdraw cycle extracts 1 wei of rounding profit from the pool.

// INVARIANT
// Share minting must round DOWN (fewer shares to depositor) and asset redemption must round DOWN (fewer assets to withdrawer)
// to prevent rounding profit extraction.

// WHAT BREAKS
// Both deposit and withdrawal round in the user's favor. An attacker can extract 1-2 wei of value per deposit-withdraw cycle.
// On L2s with cheap gas, thousands of cycles become economically profitable.

// EXPLOIT PATH
// 1. Pool state: totalDeposited=1000, totalShares=1000
// 2. Attacker deposits 1 wei. mintShares = (1 * 1000 + 1000 - 1) / 1000 = 1999 / 1000 = 1 (rounded up from 0.001). totalDeposited=1001, totalShares=1001
// 3. Attacker withdraws 1 share. assets = (1 * 1001 + 1001 - 1) / 1001 = 2001 / 1001 = 1 (rounded up from 0.999). totalDeposited=1000, totalShares=1000
// 4. Net: deposited 1, withdrew 1, no profit on this scale. BUT at different ratios:
// 5. Pool state: totalDeposited=1000, totalShares=999. Attacker deposits 1 wei. mintShares = (1 * 999 + 999) / 1000 = 1998/1000 = 1. Now totalDeposited=1001, totalShares=1000
// 6. Withdraw 1 share: assets = (1 * 1001 + 999) / 1000 = 2000/1000 = 2. Profit: 1 wei. Repeat 10,000 times on L2 for 10,000 wei.

// WHY MISSED
// Rounding direction errors are subtle — the '+ denominator - 1' pattern for ceiling division is correct syntax. The question
// is whether ceiling is the RIGHT choice for each operation. Auditors may verify the math is 'correct rounding' without
// checking whether the rounding direction favors the correct party.
