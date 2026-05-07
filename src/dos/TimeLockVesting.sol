// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Permissionless Lock Pushes Brick Victim Redemptions

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TimeLockVesting
contract TimeLockVesting {
    struct Lock {
        uint256 amount;
        uint256 unlockTime;
    }

    IERC20 public token;

    mapping(address => Lock[]) public userLocks;

    constructor(address _token) {
        token = IERC20(_token);
    }

    /// @notice Create a new entry or position
    /// @param beneficiary Beneficiary value
    /// @param amount Token amount
    /// @param duration Time duration in seconds
    function createLock(address beneficiary, uint256 amount, uint256 duration) external {
        require(amount > 0, "Amount must be > 0");
        require(duration > 0, "Duration must be > 0");

        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        userLocks[beneficiary].push(Lock(amount, block.timestamp + duration));
    }

    /// @notice Redeem shares for underlying tokens
    function redeemAll() external {
        Lock[] storage locks = userLocks[msg.sender];
        uint256 totalRedeemable = 0;
        uint256 remaining = 0;

        Lock[] memory newLocks = new Lock[](locks.length);
        uint256 newCount = 0;
        for (uint256 i = 0; i < locks.length; i++) {
            if (block.timestamp >= locks[i].unlockTime) {
                totalRedeemable += locks[i].amount;
            } else {
                newLocks[newCount] = locks[i];
                newCount++;
            }
        }

        delete userLocks[msg.sender];

        for (uint256 i = 0; i < newCount; i++) {
            userLocks[msg.sender].push(newLocks[i]);
        }

        require(totalRedeemable > 0, "Nothing to redeem");
        require(token.transfer(msg.sender, totalRedeemable), "Transfer failed");
    }

    /// @notice Get lock count
    function getLockCount(address user) external view returns (uint256) {
        return userLocks[user].length;
    }
}

// INVARIANT
// A user's redeemAll function must remain callable regardless of actions by other users

// WHAT BREAKS
// An attacker calls createLock(victim, 1, 1) thousands of times with dust amounts. The victim's userLocks array grows
// unboundedly. When the victim calls redeemAll(), the for-loop at line 33 iterates over all entries, exceeding the block gas
// limit. The victim's tokens are permanently locked.

// EXPLOIT PATH
// 1. Attacker approves 10,000 wei of token to the contract
// 2. Attacker calls createLock(victim, 1, 1) in a loop 10,000 times (1 wei per lock, 1 second duration)
// 3. userLocks[victim].length == 10,000
// 4. Victim calls redeemAll(). The loop at line 33 iterates 10,000 entries, consuming ~20,000 gas per iteration (2 SLOAD per Lock struct)
// 5. Total gas: 10,000 * 20,000 = 200,000,000, exceeding the 30M block gas limit
// 6. redeemAll() permanently reverts. Victim's legitimately locked tokens are unrecoverable.

// WHY MISSED
// The beneficiary parameter in createLock looks like a useful feature for gifting vesting locks. Auditors may treat it as a
// benign UX feature without realizing it gives attackers write access to arbitrary users' storage arrays.
