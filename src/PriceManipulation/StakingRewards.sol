// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title StakingRewards
contract StakingRewards is ERC20 {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    address public rewarder;
    uint256 public rewardPerShare;
    uint256 public totalDistributed;

    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public claimedRewards;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardDistributed(uint256 amount, uint256 newRewardPerShare);
    event RewardClaimed(address indexed user, uint256 amount);

    constructor(address _staking, address _reward) ERC20("sToken", "sTKN") {
        stakingToken = IERC20(_staking);
        rewardToken = IERC20(_reward);
        rewarder = msg.sender;
    }

    /// @notice Stake tokens to earn rewards
    function stake(uint256 amount) external {
        require(amount > 0, "Cannot stake 0");
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        _mint(msg.sender, amount);
        // rewardDebt[0x11] = 10e18 * 0 / 1e18 (first deposit)
        rewardDebt[msg.sender] = balanceOf(msg.sender) * rewardPerShare / 1e18;
        emit Staked(msg.sender, amount);
    }

    /// @notice Unstake and reclaim tokens
    function unstake(uint256 amount) external {
        require(amount > 0, "Cannot unstake 0");
        require(balanceOf(msg.sender) >= amount, "Insufficient stake");

        _claimReward(msg.sender);
        _burn(msg.sender, amount);

        require(stakingToken.transfer(msg.sender, amount), "Transfer failed");
        rewardDebt[msg.sender] = balanceOf(msg.sender) * rewardPerShare / 1e18;
        emit Unstaked(msg.sender, amount);
    }

    // Can someone stake right before distributeReward() is called and unstake right after? Is there any minimum
    // staking duration?

    /// @notice Distribute tokens to recipients
    function distributeReward(uint256 amount) external {
        require(msg.sender == rewarder, "Not rewarder");
        require(totalSupply() > 0, "No stakers");
        require(amount > 0, "Zero reward");
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        rewardPerShare += amount * 1e18 / totalSupply();
        totalDistributed += amount;
        emit RewardDistributed(amount, rewardPerShare);
    }

    function _claimReward(address user) internal {
        uint256 pending = balanceOf(user) * rewardPerShare / 1e18 - rewardDebt[user];

        if (pending > 0) {
            require(rewardToken.transfer(user, pending), "Transfer failed");

            claimedRewards[user] += pending;
            emit RewardClaimed(user, pending);
        }
    }

    /// @notice Claim accumulated rewards
    function claimReward() external {
        _claimReward(msg.sender);
        rewardDebt[msg.sender] = balanceOf(msg.sender) * rewardPerShare / 1e18;
    }

    /// @notice Pending reward
    function pendingReward(address user) external view returns (uint256) {
        return balanceOf(user) * rewardPerShare / 1e18 - rewardDebt[user];
    }

    /// @notice Configure a contract parameter
    function setRewarder(address _rewarder) external {
        require(msg.sender == rewarder, "Not rewarder");
        rewarder = _rewarder;
    }
}

// BUG
// stake() at line 29 has no time lock or cooldown. distributeReward() at line 48 increases rewardPerShare instantly based on
// current totalSupply(). An attacker can stake a large amount just before distributeReward() is called, diluting existing
// stakers' rewards, then unstake immediately after claiming.

// IMPACT
// The attacker captures a share of rewards proportional to their stake percentage despite staking for only one block. Long-term
// stakers receive proportionally less.

// INVARIANT
// Reward distribution must be proportional to the duration of stake, not just the point-in-time balance at distribution.

// WHAT BREAKS
// stake() at line 21 allows instant staking with no lockup. distributeReward() at line 35-36 distributes based on current
// totalSupply(). An attacker front-runs the reward distribution transaction to capture an outsized share of rewards.

// EXPLOIT PATH
// 1. Pool has 1,000 sTKN staked by honest users. Rewarder is about to distribute 100 reward tokens
// 2. Attacker sees distributeReward(100) in mempool. Front-runs: stakes 9,000 tokens (totalSupply = 10,000)
// 3. distributeReward executes: rewardPerShare += 100e18 / 10,000 = 0.01e18
// 4. Attacker claims: pending = 9,000 * 0.01e18 / 1e18 = 90 reward tokens
// 5. Attacker unstakes 9,000 tokens in next block. Net: 90 reward tokens for 1 block of staking
// 6. Honest stakers who staked for months share only 10 reward tokens.

// WHY MISSED
// The MasterChef-style reward distribution pattern is widely used and considered standard. The rewardDebt mechanism correctly
// tracks per-user entitlements. The vulnerability is in the absence of a lockup, which is a protocol design decision, not a
// code bug in the math.
