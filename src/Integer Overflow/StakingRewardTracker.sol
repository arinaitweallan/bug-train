// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title StakingRewardTracker
contract StakingRewardTracker {
    IERC20 public immutable token;
    address public owner;

    struct UserInfo {
        uint128 stakedAmount;
        uint64 rewardDebt;
        uint64 lastUpdate;
    }

    mapping(address => UserInfo) public users;

    uint256 public accRewardPerShare;
    uint256 public totalStaked;

    constructor(address _token) {
        token = IERC20(_token);
        owner = msg.sender;
    }

    /// @notice Stake tokens to earn rewards
    function stake(uint256 amount) external {
        require(amount > 0, "Zero");
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        UserInfo storage user = users[msg.sender];
        if (user.stakedAmount > 0) {
            uint256 pending = (uint256(user.stakedAmount) * accRewardPerShare / 1e12) - uint256(user.rewardDebt);
            if (pending > 0) token.transfer(msg.sender, pending);
        }

        totalStaked += amount;
        user.stakedAmount = uint128(amount + uint256(user.stakedAmount));
        user.rewardDebt = uint64(uint256(user.stakedAmount) * accRewardPerShare / 1e12);
        user.lastUpdate = uint64(block.timestamp);
    }

    /// @notice Unstake and reclaim tokens
    function unstake(uint256 amount) external {
        UserInfo storage user = users[msg.sender];
        require(uint256(user.stakedAmount) >= amount, "Insufficient");

        uint256 pending = (uint256(user.stakedAmount) * accRewardPerShare / 1e12) - uint256(user.rewardDebt);
        if (pending > 0) token.transfer(msg.sender, pending);

        user.stakedAmount -= uint128(amount);
        totalStaked -= amount;
        // rewardDebt is stored as uint64. What is the maximum value a uint64 can hold? What happens when
        // the computed debt exceeds that?
        user.rewardDebt = uint64(uint256(user.stakedAmount) * accRewardPerShare / 1e12);

        require(token.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Update contract parameters
    function updateRewards(uint256 reward) external {
        require(msg.sender == owner, "Not owner");

        if (totalStaked > 0) {
            accRewardPerShare += reward * 1e12 / totalStaked;
        }
    }
}

// BUG
// The reward debt is cast to uint64 via uint64(...). In Solidity 0.8+, explicit downcasts do NOT revert on overflow -- they
// silently truncate. If stakedAmount * accRewardPerShare / 1e12 exceeds 2^64 - 1 (18446744073709551615), the value wraps
// silently, producing a corrupted rewardDebt.

// IMPACT
// A truncated rewardDebt means the subtraction on line 40 yields a massively inflated pending reward. The user can drain the
// contract's token balance by claiming far more rewards than actually accrued.

// INVARIANT
// user.rewardDebt must always equal the full precision value of (stakedAmount * accRewardPerShare / 1e12) at the time of the
// last state change.

// WHAT BREAKS
// The uint64 downcast silently truncates the reward debt. When the full value exceeds 18446744073709551615 (uint64 max), the
// stored rewardDebt becomes the lower 64 bits -- a much smaller number. The pending reward calculation subtracts this small
// number from the full-precision product, yielding an enormous fake reward.

// EXPLOIT PATH
// 1. Attacker stakes 1000e18 tokens. accRewardPerShare grows to 20e12 over time
// 2. True rewardDebt = 1000e18 * 20e12 / 1e12 = 20000e18 = 2e22
// 3. uint64(2e22) = 2e22 mod 2^64 = 2e22 mod 1.844e19 = 1552921504606846976 (truncated)
// 4. On unstake, pending = 2e22 - 1552921504606846976 = ~1.845e22 tokens -- a massive fake reward
// 5. Attacker drains the contract.

// WHY MISSED
// The struct uses packed storage (uint128 + uint64 + uint64) which looks like a standard gas optimization. Auditors familiar
// with MasterChef patterns may not realize that Solidity 0.8 explicit downcasts silently truncate rather than revert.
