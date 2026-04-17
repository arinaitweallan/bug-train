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
        // q what if i initialize admin to address(0)?

        admin = _admin;
        bidToken = IERC20(_bidToken);
        epochDuration = _epochDuration; // 500
        currentEpoch = 1;
        epochStartTime = block.timestamp; // 10_000
        minBidIncrement = 100e18;
    }

    /// @notice Place a bid in the auction
    // q what if i call bid before initialize()? [cant be called]
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
    function settleEpoch() external onlyOwner {
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
