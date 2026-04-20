// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VaultShareManager
contract VaultShareManager {
    using SafeERC20 for IERC20;

    address public owner;
    IERC20 public asset;

    uint256 public depositCap;
    uint256 public totalShares;

    mapping(address => uint256) public shares;
    bool private _initialized;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /// @notice Initialize contract state
    /// @param _asset Asset value
    /// @param _depositCap Deposit cap value
    // @audit: owner never initialized
    function initialize(address _asset, uint256 _depositCap) external {
        require(!_initialized, "Already init");
        _initialized = true;
        asset = IERC20(_asset);
        depositCap = _depositCap;
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(totalShares + amount <= depositCap, "Cap exceeded");

        asset.safeTransferFrom(msg.sender, address(this), amount);
        shares[msg.sender] += amount;
        totalShares += amount;
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 amount) external {
        require(shares[msg.sender] >= amount, "Insufficient");
        shares[msg.sender] -= amount;
        totalShares -= amount;
        asset.safeTransfer(msg.sender, amount);
    }

    /// @notice Configure a contract parameter
    function setDepositCap(uint256 _newCap) external onlyOwner {
        require(_newCap > 0, "Zero cap");
        depositCap = _newCap;
    }

    /// @notice Execute emergency action
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner, bal);
    }

    /// @notice Get total shares
    function getTotalShares() external view returns (uint256) {
        return totalShares;
    }
}

// BUG
// The initialize function sets _initialized, asset, and depositCap but never sets the owner variable.
// Owner remains address(0).

// IMPACT
// setDepositCap and emergencyWithdraw require onlyOwner but owner is address(0). No one can ever call these
// functions, permanently locking emergency withdrawal capability and deposit cap management.

// INVARIANT
// The deployer must be set as owner during initialization so that admin functions are accessible.

// WHAT BREAKS
// Owner remains address(0) after initialization. No one can call setDepositCap to adjust limits or emergencyWithdraw
// to rescue stuck tokens. If a vulnerability is discovered, funds cannot be emergency-rescued because the admin function
//  is permanently bricked.

// EXPLOIT PATH
// 1. VaultShareManager is deployed behind a proxy. Deployer calls initialize(USDC, 1000000e6)
// 2. Owner remains address(0) because initialize never sets it
// 3. Users deposit 800,000 USDC into the vault
// 4. Deployer discovers a need to lower the deposit cap, calls setDepositCap(500000e6), which reverts with 'Not owner'
// 5. A token exploit is discovered. Deployer calls emergencyWithdraw(USDC), which reverts with 'Not owner'
// 6. 800,000 USDC is permanently inaccessible to admin functions.

// WHY MISSED
// The onlyOwner modifier and owner state variable create the appearance of a complete access control setup. Auditors check
// that protected functions use onlyOwner but do not verify that owner is actually assigned during initialization.
