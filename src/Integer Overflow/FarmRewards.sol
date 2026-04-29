// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FarmRewards
contract FarmRewards {
    IERC20 public immutable lpToken;
    IERC20 public immutable rewardToken;
    address public owner;

    uint256 public accRewardPerShare;
    uint256 public totalDeposited;
    uint256 public lastRewardTime;
    uint256 public rewardPerSecond;

    uint256 public constant PRECISION = 1e30;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    // q how many slots is this mapping occupying?
    mapping(address => UserInfo) public userInfo;

    constructor(address _lp, address _reward, uint256 _rewardPerSec) {
        lpToken = IERC20(_lp);
        rewardToken = IERC20(_reward);
        owner = msg.sender;
        rewardPerSecond = _rewardPerSec;
        lastRewardTime = block.timestamp;
    }

    /// @notice Update contract parameters
    function updatePool() public {
        if (totalDeposited == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - lastRewardTime;
        uint256 reward = elapsed * rewardPerSecond;
        accRewardPerShare += reward * PRECISION / totalDeposited;
        lastRewardTime = block.timestamp;
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        updatePool();
        UserInfo storage user = userInfo[msg.sender];
        if (user.amount > 0) {
            uint256 pending = user.amount * accRewardPerShare / PRECISION - user.rewardDebt;
            if (pending > 0) rewardToken.transfer(msg.sender, pending);
        }
        require(lpToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        user.amount += amount;
        user.rewardDebt = user.amount * accRewardPerShare / PRECISION;
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 amount) external {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Insufficient");
        updatePool();
        uint256 pending = user.amount * accRewardPerShare / PRECISION - user.rewardDebt;
        if (pending > 0) rewardToken.transfer(msg.sender, pending);
        user.amount -= amount;
        user.rewardDebt = user.amount * accRewardPerShare / PRECISION;
        require(lpToken.transfer(msg.sender, amount), "Transfer failed");
    }
}

// BUG
// PRECISION is 1e30. When accRewardPerShare grows large (it accumulates over time), the multiplication
// user.amount * accRewardPerShare on line 42 can overflow uint256. For a user with 1e18 LP tokens and accRewardPerShare of
// 1e40, the product is 1e58 which is fine -- but after years of accumulation, accRewardPerShare can reach 1e50+, making the
// product exceed 2^256 (~1.15e77). This causes a revert, permanently freezing user deposits.

// IMPACT
// All deposit and withdraw calls revert due to the overflow in the pending reward calculation. User funds are permanently
// locked in the contract.

// INVARIANT
// The intermediate product user.amount * accRewardPerShare must always fit within uint256 (< 2^256) for all users.

// WHAT BREAKS
// The PRECISION constant of 1e30 is too large. Combined with a long-running pool and small totalDeposited, accRewardPerShare
// grows until the multiplication with user.amount overflows uint256. Since Solidity 0.8 reverts on overflow, all withdraw and
// deposit calls revert permanently.

// EXPLOIT PATH
// 1. Pool runs with rewardPerSecond = 1e18, totalDeposited = 1e6 (tiny pool)
// 2. After 1 year (31536000 seconds): accRewardPerShare += 31536000 * 1e18 * 1e30 / 1e6 = 3.15e58
// 3. After 10 years: accRewardPerShare ~ 3.15e59
// 4. User with 1e18 LP calls withdraw. Product = 1e18 * 3.15e59 = 3.15e77
// 5. uint256 max = 1.15e77. 3.15e77 > 1.15e77 -- overflow revert
// 6. All user funds are permanently locked.

// WHY MISSED
// MasterChef clones typically use 1e12 for PRECISION, which is safe. The 1e30 value looks like extra safety but actually
// accelerates the overflow timeline. Auditors may not compute the long-term accumulation growth rate.
