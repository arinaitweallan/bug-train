// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UpgradeableStakingPool
contract UpgradeableStakingPool {
    using SafeERC20 for IERC20;

    address public owner;
    IERC20 public stakingToken;
    IERC20 public rewardToken;
    uint256 public rewardRate;
    uint256 public totalStaked;
    bool private initialized;

    mapping(address => uint256) public staked;
    mapping(address => uint256) public rewardDebt;

    /// @notice Initialize contract state
    /// @param _stakingToken Staking token value
    /// @param _rewardToken Reward token value
    /// @param _rewardRate Reward rate value
    function initialize(address _stakingToken, address _rewardToken, uint256 _rewardRate) external {
        require(!initialized, "Already initialized");
        
        owner = msg.sender;
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        rewardRate = _rewardRate;
        initialized = true;
    }

    /// @notice Stake tokens to earn rewards
    function stake(uint256 amount) external {
        require(initialized, "Not initialized");

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        staked[msg.sender] += amount;
        totalStaked += amount;
    }

    /// @notice Unstake and reclaim tokens
    function unstake(uint256 amount) external {
        require(staked[msg.sender] >= amount, "Insufficient stake");

        staked[msg.sender] -= amount;
        totalStaked -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Configure a contract parameter
    function setRewardRate(uint256 _rate) external {
        require(msg.sender == owner, "Not owner");

        rewardRate = _rate;
    }

    /// @notice Get stake
    function getStake(address user) external view returns (uint256) {
        return staked[user];
    }
}
