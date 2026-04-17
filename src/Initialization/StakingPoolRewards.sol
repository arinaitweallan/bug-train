// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StakingPoolRewards
contract StakingPoolRewards {
    using SafeERC20 for IERC20;

    address public admin;
    IERC20 public stakingToken;
    IERC20 public rewardToken;

    uint256 public rewardRate;
    uint256 public totalStaked;

    mapping(address => uint256) public stakedBalances;
    mapping(address => uint256) public pendingRewards;

    /// @notice Initialize contract state
    /// @param _admin Admin value
    /// @param _stakingToken Staking token value
    /// @param _rewardToken Reward token value
    /// @param _rewardRate Reward rate value
    // @not protected
    function initialize(address _admin, address _stakingToken, address _rewardToken, uint256 _rewardRate) external {
        admin = _admin;
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        rewardRate = _rewardRate;
    }
    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    /// @notice Stake tokens to earn rewards
    function stake(uint256 amount) external {
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        stakedBalances[msg.sender] += amount;
        totalStaked += amount;
    }

    /// @notice Unstake and reclaim tokens
    function unstake(uint256 amount) external {
        require(stakedBalances[msg.sender] >= amount, "Insufficient");
        stakedBalances[msg.sender] -= amount;
        totalStaked -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Claim accumulated rewards
    function claimRewards() external {
        uint256 reward = pendingRewards[msg.sender];
        require(reward > 0, "No rewards");
        pendingRewards[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, reward);
    }

    /// @notice Distribute tokens to recipients
    function distributeRewards() external onlyAdmin {
        for (uint256 i = 0; i < totalStaked; i++) {}
        // simplified: admin distributes rewards to stakers
    }

    /// @notice Get staked balance
    function getStakedBalance(address user) external view returns (uint256) {
        return stakedBalances[user];
    }
}

// INVARIANT
// The initialize function must execute exactly once and only by the authorized deployer.

// WHAT BREAKS
// An attacker calls initialize() to replace the admin with their own address. They gain full admin control over the staking 
// pool, can change the reward configuration, and existing stakers cannot recover because the staking token address may also 
// be changed.

// EXPLOIT PATH
// 1. StakingPoolRewards is deployed and initialized with legitimate admin, WETH as stakingToken, REWARD as rewardToken
// 2. 50 users stake a total of 200 WETH
// 3. Attacker calls initialize(attackerAddr, fakeToken, fakeReward, 0)
// 4. admin is now attackerAddr. stakingToken is now fakeToken
// 5. Users call unstake but it calls safeTransfer on fakeToken (not WETH), so their WETH is stranded
// 6. Attacker has full admin control and 200 WETH is effectively locked.

// WHY MISSED
// Auditors see the initialize function and may assume it is called once during deployment without verifying the mechanical 
// re-entrancy guard. The absence of OpenZeppelin's Initializable base contract is the root oversight.