// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StakingLock
contract StakingLock {
    using SafeERC20 for IERC20;

    IERC20 public stakingToken;
    uint256 public constant LOCK_DURATION = 30 days;

    struct LockInfo {
        uint256 amount;
        uint256 unlockTime;
    }

    mapping(address => LockInfo) public locks;

    constructor(address _token) {
        stakingToken = IERC20(_token);
    }

    /// @notice Stake tokens to earn rewards
    function stake(uint256 amount) external {
        require(amount > 0, "Zero amount");

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        locks[msg.sender].amount += amount;
        locks[msg.sender].unlockTime = block.timestamp + LOCK_DURATION;
    }

    /// @notice Stake tokens to earn rewards
    /// @param beneficiary Beneficiary value
    /// @param amount Token amount
    function stakeFor(address beneficiary, uint256 amount) external {
        require(amount > 0, "Zero amount");
        require(beneficiary != address(0), "Zero address");
        
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        locks[beneficiary].amount += amount;
        locks[beneficiary].unlockTime = block.timestamp + LOCK_DURATION;
    }

    /// @notice Unstake and reclaim tokens
    function unstake() external {
        LockInfo storage lock = locks[msg.sender];
        require(lock.amount > 0, "Nothing staked");
        require(block.timestamp >= lock.unlockTime, "Still locked");

        uint256 amount = lock.amount;
        lock.amount = 0;
        lock.unlockTime = 0;
        stakingToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Get time remaining
    function getTimeRemaining(address user) external view returns (uint256) {
        if (block.timestamp >= locks[user].unlockTime) return 0;
        return locks[user].unlockTime - block.timestamp;
    }
}

// IMPACT
// Each call to stakeFor resets the beneficiary's unlockTime to block.timestamp + LOCK_DURATION. An attacker can repeatedly 
// call stakeFor with 1 wei to indefinitely extend a victim's lock, preventing them from ever unstaking.

// BUG
// stakeFor accepts any beneficiary address without verifying the beneficiary has consented. This allows forcing state changes 
// on arbitrary users.

// INVARIANT
// A user's lock expiry can only be extended by their own actions or with their explicit consent.

// WHAT BREAKS
// stakeFor has no consent mechanism. An attacker can call stakeFor(victim, 1) with 1 wei of tokens to reset the victim's 
// unlockTime to 30 days in the future. Repeating this daily permanently prevents the victim from unstaking their entire 
// position.

// EXPLOIT PATH
// 1. Alice stakes 100,000 tokens. locks[Alice] = {amount: 100000e18, unlockTime: now + 30 days}
// 2. After 29 days, Alice is about to unstake
// 3. Attacker calls stakeFor(Alice, 1) spending 1 wei of stakingToken
// 4. locks[Alice].unlockTime is reset to now + 30 days. locks[Alice].amount = 100000e18 + 1
// 5. Attacker repeats step 3 every 29 days, each time costing 1 wei
// 6. Alice's 100,000 tokens are permanently locked. Attack cost: negligible.

// WHY MISSED
// The stakeFor function appears benevolent since the attacker must spend their own tokens. Auditors focus on whether the 
// function can steal funds and overlook that the lock-time reset side effect can be weaponized as a griefing vector with 
// negligible cost.