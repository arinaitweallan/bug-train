// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title YieldVault
contract YieldVault {
    IERC20 public immutable asset;

    uint256 public totalDeposited;
    uint256 public yieldAccumulator;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public yieldSnapshot;

    // reward rate overflow
    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(amount > 0, "Zero");
        _claimYield(msg.sender);
        require(asset.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        deposits[msg.sender] += amount;
        totalDeposited += amount;
        yieldSnapshot[msg.sender] = yieldAccumulator;
    }

    /// @notice Distribute tokens to recipients
    function distributeYield() external {
        uint256 balance = asset.balanceOf(address(this));
        uint256 surplus = balance - totalDeposited;

        require(surplus > 0, "No yield");
        yieldAccumulator += surplus * 1e18 / totalDeposited;
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 amount) external {
        require(deposits[msg.sender] >= amount, "Insufficient");
        _claimYield(msg.sender);

        deposits[msg.sender] -= amount;
        totalDeposited -= amount;
        require(asset.transfer(msg.sender, amount), "Transfer failed");
    }

    function _claimYield(address user) internal {
        if (deposits[user] > 0) {
            uint256 owed = deposits[user] * (yieldAccumulator - yieldSnapshot[user]) / 1e18;
            yieldSnapshot[user] = yieldAccumulator;

            if (owed > 0) asset.transfer(user, owed);
        }
    }

    /// @notice Get claimable
    function getClaimable(address user) external view returns (uint256) {
        return deposits[user] * (yieldAccumulator - yieldSnapshot[user]) / 1e18;
    }
}

// BUG
// distributeYield is permissionless and calculates surplus as balanceOf(this) - totalDeposited. An attacker can donate tokens
// directly to inflate the surplus. When totalDeposited is very small (e.g., 1 wei), a large donation makes yieldAccumulator
// grow toward uint256 max. Subsequent calls to _claimYield overflow on the multiplication deposits[user] * yieldAccumulator.

// IMPACT
// When yieldAccumulator is inflated, deposits[user] * (yieldAccumulator - yieldSnapshot[user]) overflows uint256 in Solidity
// 0.8, causing a revert. All deposit, withdraw, and claim operations are permanently DoS'd for all users.

// INVARIANT
// yieldAccumulator * max_deposit must fit within uint256 to ensure _claimYield never overflows.

// WHAT BREAKS
// The permissionless distributeYield function allows an attacker to donate tokens directly to the vault, inflating the surplus.
// When totalDeposited is small, the yieldAccumulator grows astronomically. Subsequent multiplications in _claimYield overflow,
// reverting all user operations.

// EXPLOIT PATH
// 1. Attacker deposits 1 wei via deposit(1). totalDeposited = 1, deposits[attacker] = 1
// 2. Attacker sends 1e60 tokens directly to the contract (not via deposit). balanceOf = 1e60 + 1
// 3. Attacker calls distributeYield(). surplus = 1e60. yieldAccumulator += 1e60 * 1e18 / 1 = 1e78
// 4. uint256 max ~ 1.15e77. yieldAccumulator = 1e78 > uint256 max. The addition REVERTS
// 5. Even if accumulator did not overflow, any user calling withdraw triggers: deposits[user] * 1e78 which overflows
// 6. All deposits, withdrawals, and claims are permanently frozen.

// WHY MISSED
// The distributeYield function looks like a standard yield distribution mechanism. Auditors may focus on the accounting logic
// and miss that the function is permissionless and that direct token donations can manipulate the surplus.
