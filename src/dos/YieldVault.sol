// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Zero Total Supply Bricks Vault Deposits

/// @title YieldVault
contract YieldVault {
    IERC20 public asset;

    mapping(address => uint256) public shares;

    uint256 public totalShares;
    uint256 public totalDeposited;
    address public strategist;

    event Deposited(address indexed user, uint256 assets, uint256 sharesMinted);
    event Withdrawn(address indexed user, uint256 assets, uint256 sharesBurned);
    event YieldReported(uint256 profit);

    constructor(address _asset) {
        asset = IERC20(_asset);
        strategist = msg.sender;
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        require(asset.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        // q wwont this divide by zero on the first deposit?
        uint256 sharesToMint = (amount * totalShares) / totalDeposited;
        shares[msg.sender] += sharesToMint;
        totalShares += sharesToMint;
        totalDeposited += amount;
        emit Deposited(msg.sender, amount, sharesToMint);
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 shareAmount) external {
        require(shares[msg.sender] >= shareAmount, "Insufficient shares");
        uint256 assetAmount = (shareAmount * totalDeposited) / totalShares;
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalDeposited -= assetAmount;
        require(asset.transfer(msg.sender, assetAmount), "Transfer failed");
        emit Withdrawn(msg.sender, assetAmount, shareAmount);
    }

    /// @notice Report yield
    function reportYield(uint256 profit) external {
        require(msg.sender == strategist, "Not strategist");
        require(asset.transferFrom(msg.sender, address(this), profit), "Transfer failed");
        totalDeposited += profit;
        emit YieldReported(profit);
    }

    /// @notice Get share price
    function getSharePrice() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalDeposited * 1e18) / totalShares;
    }

    /// @notice Get user value
    function getUserValue(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares[user] * totalDeposited) / totalShares;
    }
}

// INVARIANT
// The deposit function must succeed for the first depositor when the vault is empty

// WHAT BREAKS
// The vault is deployed with totalDeposited = 0 and totalShares = 0. The very first deposit() call computes (amount * 0) / 0,
// which reverts with a division-by-zero panic. No user can ever deposit into the vault. All subsequent functionality is
// permanently bricked from deployment.

// EXPLOIT PATH
// 1. Vault is deployed. totalDeposited = 0, totalShares = 0
// 2. First user calls deposit(1000e18)
// 3. Line 23 computes: sharesToMint = (1000e18 * 0) / 0
// 4. Solidity 0.8.x panics on division by zero. Transaction reverts
// 5. Every subsequent deposit() call hits the same division by zero
// 6. The vault is permanently unusable from the moment of deployment.

// WHY MISSED
// Auditors often test deposit logic with non-zero states. The empty-state edge case at deployment is easily overlooked because
// the formula looks correct for the steady-state case where totalDeposited and totalShares are both positive.
