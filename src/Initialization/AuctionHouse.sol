// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AuctionHouse
contract AuctionHouse {
    using SafeERC20 for IERC20;

    address public admin;
    IERC20 public bidToken;

    uint256 public currentEpoch;
    uint256 public epochDuration;
    uint256 public epochStartTime;
    uint256 public minBidIncrement;

    mapping(uint256 => address) public epochWinner;
    mapping(uint256 => uint256) public epochHighBid;
    mapping(uint256 => uint256) public previousEpochPrice;
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice Initialize contract state
    /// @param _admin Admin value
    /// @param _bidToken Bid token value
    /// @param _epochDuration Epoch duration value
    // @audit: permisionless initialization
    function initialize(address _admin, address _bidToken, uint256 _epochDuration) external {
        require(admin == address(0), "Already init");
        // q what if i initialize admin to address(0)? [means contract can always be reinitialized]
        // this can reset current epoch, epoch start time and duration

        admin = _admin;
        bidToken = IERC20(_bidToken);
        epochDuration = _epochDuration; // 500
        currentEpoch = 1;
        epochStartTime = block.timestamp; // 10_000
        minBidIncrement = 100e18;
    }

    /// @notice Place a bid in the auction
    // q what if i call bid before initialize()? [reverts]
    function bid(uint256 amount) external {
        // 10_100 < 10_000 + 500 [true]
        require(block.timestamp < epochStartTime + epochDuration, "Epoch ended");

        uint256 minBid = epochHighBid[currentEpoch] + minBidIncrement;
        uint256 priceFloor = previousEpochPrice[currentEpoch - 1] * 80 / 100;
        uint256 effectiveMin = minBid > priceFloor ? minBid : priceFloor;
        require(amount >= effectiveMin, "Bid too low");

        if (epochWinner[currentEpoch] != address(0)) {
            pendingWithdrawals[epochWinner[currentEpoch]] += epochHighBid[currentEpoch];
        }

        bidToken.safeTransferFrom(msg.sender, address(this), amount);
        epochHighBid[currentEpoch] = amount;
        epochWinner[currentEpoch] = msg.sender;
    }

    /// @notice Settle a pending transaction
    function settleEpoch() external {
        require(msg.sender == admin, "not owner");
        require(block.timestamp >= epochStartTime + epochDuration, "Not ended");

        previousEpochPrice[currentEpoch] = epochHighBid[currentEpoch];
        currentEpoch++;
        epochStartTime = block.timestamp;
    }

    /// @notice Claim accumulated rewards
    function claimRefund() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to claim");

        pendingWithdrawals[msg.sender] = 0;
        bidToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Get epoch info
    function getEpochInfo() external view returns (uint256, uint256, address) {
        return (currentEpoch, epochHighBid[currentEpoch], epochWinner[currentEpoch]);
    }
}

// BUG
// initialize sets currentEpoch=1 but never sets previousEpochPrice[0]. In the first epoch, bid() 
// computes priceFloor = previousEpochPrice[0] * 80 / 100 = 0, which means the price floor mechanism is completely 
// bypassed for epoch 1.

// IMPACT
// With previousEpochPrice[0] = 0, the price floor for epoch 1 is 0. Bidders can win epoch 1 with only minBidIncrement 
// (100 tokens), potentially far below the intended starting price. This sets a low previousEpochPrice for epoch 2, 
// cascading low floors forward.

// INVARIANT
// All state variables participating in the first operational cycle must be explicitly initialized, including historical/
// previous-epoch data.

// WHAT BREAKS
// previousEpochPrice[0] is never set during initialization, defaulting to 0. The first epoch's price floor calculation 
// returns 0, eliminating the floor protection. An attacker wins epoch 1 with the minimum bid increment, establishing a low 
// price that cascades through the previousEpochPrice chain to subsequent epochs.

// EXPLOIT PATH
// 1. AuctionHouse initialized with epochDuration=1 day, minBidIncrement=100e18. currentEpoch=1
// 2. previousEpochPrice[0] = 0 (never set). Intended starting floor was 10,000e18
// 3. Attacker bids 100e18 in epoch 1. priceFloor = 0 * 80 / 100 = 0. effectiveMin = max(100, 0) = 100. Bid accepted
// 4. No other bidder bids more. settleEpoch: previousEpochPrice[1] = 100e18
// 5. Epoch 2 floor = 100e18 * 80 / 100 = 80e18. Still far below intended 10,000e18
// 6. Attacker wins multiple epochs at ~100 tokens each instead of the intended ~10,000 price.

// WHY MISSED
// The auction state machine logic is correct for steady-state operation (epoch N uses epoch N-1 price). Auditors verify the 
// bid logic and settlement work correctly but overlook that the bootstrap condition (epoch 0 price) is never set, creating 
// a one-time exploit at launch.