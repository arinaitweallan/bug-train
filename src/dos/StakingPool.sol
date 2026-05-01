// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRewardReceiver {
    function onRewardReceived(address token, uint256 amount) external returns (bytes4);
}

/// @title StakingPool
contract StakingPool {
    IERC20 public stakingToken;
    IERC20 public rewardToken;

    mapping(address => uint256) public staked;
    mapping(address => uint256) public rewardDebt;

    uint256 public accRewardPerShare;
    uint256 public totalStaked;
    address public owner;

    constructor(address _stakingToken, address _rewardToken) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        owner = msg.sender;
    }

    /// @notice Stake tokens to earn rewards
    function stake(uint256 amount) external {
        require(amount > 0, "Zero amount");
        _claimReward(msg.sender);
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        staked[msg.sender] += amount;
        totalStaked += amount;
        rewardDebt[msg.sender] = staked[msg.sender] * accRewardPerShare / 1e18;
    }

    /// @notice Unstake and reclaim tokens
    function unstake(uint256 amount) external {
        require(staked[msg.sender] >= amount, "Insufficient");
        _claimReward(msg.sender);

        staked[msg.sender] -= amount;
        totalStaked -= amount;
        rewardDebt[msg.sender] = staked[msg.sender] * accRewardPerShare / 1e18;
        require(stakingToken.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Add a new entry or allocation
    function addRewards(uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        require(totalStaked > 0, "No stakers");
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        accRewardPerShare += (amount * 1e18) / totalStaked;
    }

    function _claimReward(address user) internal {
        uint256 pending = (staked[user] * accRewardPerShare / 1e18) - rewardDebt[user];
        if (pending > 0) {
            require(rewardToken.transfer(user, pending), "Transfer failed");
            IRewardReceiver(user).onRewardReceived(address(rewardToken), pending);
        }
    }
}

// INVARIANT
// Reward claiming must succeed regardless of whether the staker is an EOA or a contract without callback support

// WHAT BREAKS
// Any EOA staker (the vast majority of users) triggers a revert at line 52 when claiming rewards, because EOAs have no code and
// the interface call reverts. Since _claimReward is called inside stake() and unstake(), both functions also revert. Users
// cannot stake more, unstake, or claim rewards. All staked tokens are permanently locked.

// EXPLOIT PATH
// 1. EOA user stakes 1000e18 tokens via stake(1000e18). This succeeds because staked[user] == 0 so pending == 0 and the callback is skipped
// 2. Owner adds 100e18 rewards via addRewards(100e18). accRewardPerShare increases
// 3. User calls unstake(500e18)
// 4. _claimReward computes pending = (1000e18 * accRewardPerShare / 1e18) - rewardDebt > 0
// 5. rewardToken.transfer succeeds, then line 52 calls IRewardReceiver(EOA).onRewardReceived()
// 6. Call to EOA with no code reverts (Solidity 0.8.x reverts on calls to non-contract addresses returning no data matching bytes4)
// 7. unstake() reverts. User's 1000e18 tokens are permanently locked.

// WHY MISSED
// The callback pattern is common in ERC721/ERC1155. Auditors may assume stakers are always contracts (like in some
// protocol-to-protocol integrations) and not consider that EOA users trigger reverts on interface calls to codeless
// addresses.

