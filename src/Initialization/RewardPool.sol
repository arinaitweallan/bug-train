// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RewardPool
contract RewardPool {
    using SafeERC20 for IERC20;

    IERC20 public stakingToken;
    IERC20 public rewardToken;
    address public rewardDistributor;

    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalStaked;
    uint256 public constant DURATION = 7 days;
    // Can a user call stake() before notifyRewardAmount() has ever been called? What is rewardRate at that point?

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public balances;

    constructor(address _stakingToken, address _rewardToken, address _distributor) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        rewardDistributor = _distributor;
    }

    /// @notice Stake tokens to earn rewards
    function stake(uint256 amount) external updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");

        totalStaked += amount;
        balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 amount) external updateReward(msg.sender) {
        require(balances[msg.sender] >= amount, "Insufficient");

        totalStaked -= amount;
        balances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Get reward
    function getReward() external updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
        }
    }

    /// @notice Notify reward amount
    function notifyRewardAmount(uint256 reward) external {
        require(msg.sender == rewardDistributor, "Not distributor");

        rewardToken.safeTransferFrom(msg.sender, address(this), reward);
        rewardRate = reward / DURATION;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + DURATION;
    }

    /// @notice Reward per token
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18 / totalStaked);
    }

    /// @notice Last time reward applicable
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /// @notice Earned
    function earned(address account) public view returns (uint256) {
        return (balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }
}

// BUG
// stake() has no guard requiring notifyRewardAmount to have been called first. Users can stake before rewardRate is set,
// and their stake establishes a totalStaked denominator before any rewards are allocated.

// IMPACT
// When notifyRewardAmount is finally called, rewardRate is set but lastUpdateTime resets to now. The early staker's
// userRewardPerTokenPaid is 0, and they capture a disproportionate share of rewards because they were the sole staker
// when the reward period begins.

// INVARIANT
// Staking should not be possible before the reward distribution period begins, preventing disproportionate reward capture.

// WHAT BREAKS
// Users can stake before notifyRewardAmount is called. An attacker deposits a large amount just before the distributor calls
// notifyRewardAmount. The attacker's userRewardPerTokenPaid is 0, so they earn rewards from the start of the period as the
//  dominant staker, then withdraw immediately after accumulating disproportionate rewards.

// EXPLOIT PATH
// 1. RewardPool is deployed. rewardRate = 0, periodFinish = 0
// 2. Attacker stakes 1,000,000e18 tokens. totalStaked = 1,000,000e18. No other stakers
// 3. One block later, distributor calls notifyRewardAmount(700,000e18) for 7-day period. rewardRate = 100,000e18/day
// 4. After 1 day, attacker calls getReward(). earned = 1,000,000e18 * (rewardPerToken - 0) / 1e18 = ~100,000e18 tokens
// 5. Attacker withdraws all stake. Net profit: 100,000 reward tokens in 1 day (14.3% of total rewards)
// 6. Late stakers share the remaining 85.7% over 6 days.

// WHY MISSED
// The Synthetix reward pattern is well-known, and auditors verify the math is correct. But the pre-notification staking
// window is a deployment-time race condition that does not appear in the steady-state math review.
