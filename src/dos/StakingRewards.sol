// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title StakingRewards
contract StakingRewards {
    IERC20 public rewardToken;
    IERC20 public stakingToken;

    address[] public stakers;

    mapping(address => uint256) public stakedBalance;
    mapping(address => bool) public isStaker;

    uint256 public totalStaked;
    address public owner;

    constructor(address _rewardToken, address _stakingToken) {
        rewardToken = IERC20(_rewardToken);
        stakingToken = IERC20(_stakingToken);
        owner = msg.sender;
    }

    /// @notice Stake tokens to earn rewards
    function stake(uint256 amount) external {
        require(amount > 0, "Cannot stake 0");
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        if (!isStaker[msg.sender]) {
            stakers.push(msg.sender);
            isStaker[msg.sender] = true;
        }
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;
    }

    /// @notice Unstake and reclaim tokens
    function unstake(uint256 amount) external {
        require(stakedBalance[msg.sender] >= amount, "Insufficient balance");
        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;
        require(stakingToken.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Distribute tokens to recipients
    function distributeRewards(uint256 totalReward) external {
        require(msg.sender == owner, "Not owner");
        require(totalStaked > 0, "No stakers");
        require(rewardToken.transferFrom(msg.sender, address(this), totalReward), "Transfer failed");

        for (uint256 i = 0; i < stakers.length; i++) {
            uint256 reward = (totalReward * stakedBalance[stakers[i]]) / totalStaked;
            if (reward > 0) {
                require(rewardToken.transfer(stakers[i], reward), "Transfer failed");
            }
        }
    }

    /// @notice Get staker count
    function getStakerCount() external view returns (uint256) {
        return stakers.length;
    }
}

// INVARIANTS
// distributeRewards must complete within a single block's gas limit regardless of the number of unique stakers

// WHAT BREAKS
// Reward distribution becomes permanently bricked once the stakers array grows large enough that iterating it exceeds the block
// gas limit. All pending rewards are locked in the contract.

// EXPLOIT PATH
// 1. Over time, 5,000+ unique addresses call stake(1e18) each
// 2. stakers.length reaches 5,000
// 3. Owner calls distributeRewards(1000e18)
// 4. The for-loop at line 42 iterates 5,000 entries, each performing a storage read (stakedBalance) + external transfer (rewardToken.transfer), consuming ~50,000 gas per iteration
// 5. Total gas: 5,000 * 50,000 = 250,000,000, far exceeding the 30M block gas limit
// 6. distributeRewards permanently reverts, locking all reward tokens.

// WHY MISSED
// Auditors focus on access control and reentrancy in staking contracts. The stakers array growth is gradual and only becomes a
// problem at scale, making it easy to overlook during line-by-line review when the array starts empty.
