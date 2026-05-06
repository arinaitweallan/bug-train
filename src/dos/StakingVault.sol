// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Zero-Amount Stake Creates Undeletable Position Bricking Rewards

/// @title StakingVault
contract StakingVault {
    struct Position {
        uint256 amount;
        uint256 rewardDebt;
        uint256 entryTime;
    }

    IERC20 public stakingToken;
    IERC20 public rewardToken;

    mapping(address => Position[]) public positions;

    uint256 public accRewardPerShare;
    uint256 public totalStaked;
    address public rewarder;

    constructor(address _staking, address _reward) {
        stakingToken = IERC20(_staking);
        rewardToken = IERC20(_reward);
        rewarder = msg.sender;
    }

    /// @notice Stake tokens to earn rewards
    function stake(uint256 amount) external {
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        // staking token: balanceOf(address(this)) == 0

        //     Position {
        //      amount: 0
        //      rewardDebt: 0
        //      entryTime: 1.7e9
        // }

        // totalStaked = 0
        positions[msg.sender].push(Position(amount, amount * accRewardPerShare / 1e18, block.timestamp));
        totalStaked += amount;
    }

    /// @notice Claim accumulated rewards
    function claimAll() external {
        Position[] storage pos = positions[msg.sender];
        uint256 totalReward = 0;

        for (uint256 i = 0; i < pos.length; i++) {
            uint256 reward = (pos[i].amount * accRewardPerShare / 1e18) - pos[i].rewardDebt;
            pos[i].rewardDebt = pos[i].amount * accRewardPerShare / 1e18;
            totalReward += reward;
        }

        require(totalReward > 0, "No rewards");
        require(rewardToken.transfer(msg.sender, totalReward), "Transfer failed");
    }

    /// @notice Add a new entry or allocation
    function addRewards(uint256 amount) external {
        require(msg.sender == rewarder, "Not rewarder");
        require(totalStaked > 0, "No stakers");
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        accRewardPerShare += (amount * 1e18) / totalStaked;
    }

    /// @notice Get position count
    function getPositionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }
}

// INVARIANT
// Every staking position must represent a non-zero economic stake, and claim operations must complete within gas limits

// WHAT BREAKS
// An attacker calls stake(0) thousands of times for their own address (or for a target if there were a beneficiary parameter).
// Each call pushes a Position{amount:0, rewardDebt:0, entryTime:now} to positions[attacker]. When the attacker later stakes a
// real amount and tries to claimAll(), the loop iterates thousands of zero-amount entries. Each iteration costs ~10,000 gas
// (3 SLOADs + arithmetic). At 5,000 entries: 50M gas, exceeding the block gas limit. claimAll permanently reverts. The real
// staked position's rewards are unclaimable.

// EXPLOIT PATH
// 1. Attacker calls stake(0) in a loop 5,000 times. Each call: transferFrom(attacker, contract, 0) succeeds (standard ERC20 allows 0 transfers). Position{0, 0, now} pushed
// 2. positions[attacker].length = 5,000. totalStaked unchanged
// 3. Attacker calls stake(10_000e18) legitimately. positions[attacker].length = 5,001
// 4. Rewarder adds 1,000e18 rewards via addRewards
// 5. Attacker calls claimAll(). Loop iterates 5,001 entries. Gas: 5,001 * 10,000 = 50M. Exceeds 30M block gas limit
// 6. claimAll reverts. Attacker's 10,000e18 staked tokens earn rewards but rewards are permanently unclaimable.

// WHY MISSED
// Most ERC20 tokens allow zero-amount transfers, so the transferFrom does not revert. Auditors checking the stake function see
// a working flow and may not consider that amount=0 is a valid but harmful input that creates phantom positions.
