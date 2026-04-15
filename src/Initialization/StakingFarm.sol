// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StakingFarm
contract StakingFarm {
    using SafeERC20 for IERC20;

    // set during constructor
    address public owner;
    IERC20 public stakingToken;
    IERC20 public rewardToken;

    uint256 public startTime; //
    uint256 public rewardPerSecond; //
    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    uint256 public lastRewardTime; //

    mapping(address => uint256) public userStake;
    mapping(address => uint256) public rewardDebt;

    constructor(address _stakingToken, address _rewardToken) {
        owner = msg.sender;
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
    }

    /// @notice Configure a contract parameter
    function setStartTime(uint256 _startTime) external {
        require(msg.sender == owner, "Not owner");
        require(_startTime > block.timestamp, "Must be future");

        startTime = _startTime;
        lastRewardTime = _startTime;
        // rewardPerSecond is constant
        rewardPerSecond = 10e18;
    }

    /// @notice Deposit tokens into the contract
    // Can deposit() be called before startTime? [yes]
    // Is there any time-based guard on user entry? [not really]

    // user deposits before setting start time
    function deposit(uint256 amount) external {
        updatePool();

        if (userStake[msg.sender] > 0) {
            uint256 pending = (userStake[msg.sender] * accRewardPerShare) / 1e18 - rewardDebt[msg.sender];
            if (pending > 0) rewardToken.safeTransfer(msg.sender, pending);
        }

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        userStake[msg.sender] += amount;
        totalStaked += amount;
        rewardDebt[msg.sender] = (userStake[msg.sender] * accRewardPerShare) / 1e18;
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 amount) external {
        require(userStake[msg.sender] >= amount, "Insufficient");

        updatePool();

        // pending rewards
        uint256 pending = (userStake[msg.sender] * accRewardPerShare) / 1e18 - rewardDebt[msg.sender];
        if (pending > 0) rewardToken.safeTransfer(msg.sender, pending);

        userStake[msg.sender] -= amount;
        totalStaked -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        rewardDebt[msg.sender] = (userStake[msg.sender] * accRewardPerShare) / 1e18;
    }

    function updatePool() internal {
        if (block.timestamp <= lastRewardTime) return;

        // this is only set when the total staked == 0
        if (totalStaked == 0) lastRewardTime = block.timestamp;
        return;

        // deposit before start time can accrue rewards for 56 years
        uint256 elapsed = block.timestamp - lastRewardTime;
        uint256 reward = elapsed * rewardPerSecond;
        accRewardPerShare += (reward * 1e18) / totalStaked;
        lastRewardTime = block.timestamp;
    }

    /// @notice Pending reward
    function pendingReward(address user) external view returns (uint256) {
        uint256 acc = accRewardPerShare;

        if (block.timestamp > lastRewardTime && totalStaked > 0) {
            uint256 elapsed = block.timestamp - lastRewardTime;
            acc += (elapsed * rewardPerSecond * 1e18) / totalStaked;
        }

        return (userStake[user] * acc) / 1e18 - rewardDebt[user];
    }
}

// INVARIANT
// User deposits should not be accepted before the system start time to ensure fair reward distribution from the beginning.

// WHAT BREAKS
// Users can deposit before startTime. An attacker stakes a large amount before the farm starts. When rewards begin accruing
// at startTime, the attacker is the sole staker and captures 100% of rewardPerSecond. Even after other users join, the attacker
// has already accumulated disproportionate rewards from the early window.

// EXPLOIT PATH
// 1. Owner calls setStartTime(block.timestamp + 1 days). rewardPerSecond = 10e18
// 2. Attacker immediately calls deposit(1000e18) - 23 hours before startTime
// 3. updatePool sees block.timestamp <= lastRewardTime (which is startTime), so no rewards yet
// 4. At startTime, attacker is the only staker with 1000e18. totalStaked = 1000e18
// 5. 1 hour passes. updatePool: reward = 3600 * 10e18 = 36,000e18 tokens accrued entirely to attacker
// 6. Legitimate users start depositing, but attacker already captured 36,000 reward tokens (worth $36,000 at $1/token).

// WHY MISSED
// Auditors verify the reward math and the owner-only setStartTime function. The deposit function looks standard with proper
// accounting. The absence of a time guard is an omission, not a flaw in existing logic, making it easy to overlook.

