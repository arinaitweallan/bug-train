// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface AggregatorV3Interface {
    /// @notice Performs the latestRoundData operation for the protocol.
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

// The oracle validates that the price is positive and fresh. But what if the fresh price is wildly different
// from the previous price due to oracle corruption?

/// @title LendingWithOracle
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract LendingWithOracle {
    AggregatorV3Interface public immutable priceFeed;
    IERC20 public immutable collateral;
    IERC20 public immutable stablecoin;

    mapping(address => uint256) public collateralDeposits;
    mapping(address => uint256) public stableBorrowed;

    uint256 public constant STALENESS = 3600;
    uint256 public constant LTV_BPS = 7500;

    constructor(address _feed, address _collateral, address _stable) {
        priceFeed = AggregatorV3Interface(_feed);
        collateral = IERC20(_collateral);
        stablecoin = IERC20(_stable);
    }

    /// @notice Get price
    function getPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid price");
        require(block.timestamp - updatedAt <= STALENESS, "Stale");
        return uint256(answer);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(collateral.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        collateralDeposits[msg.sender] += amount;
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        uint256 price = getPrice();
        uint256 maxBorrow = (collateralDeposits[msg.sender] * price * LTV_BPS) / (1e8 * 10000);
        require(stableBorrowed[msg.sender] + amount <= maxBorrow, "Over LTV");
        stableBorrowed[msg.sender] += amount;
        require(stablecoin.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Liquidates a position that fails the health check.
    function liquidate(address user) external {
        uint256 price = getPrice();
        uint256 maxBorrow = (collateralDeposits[user] * price * LTV_BPS) / (1e8 * 10000);
        require(stableBorrowed[user] > maxBorrow, "Healthy");
        uint256 repayAmount = stableBorrowed[user];
        uint256 seized = collateralDeposits[user];
        collateralDeposits[user] = 0;
        stableBorrowed[user] = 0;
        require(stablecoin.transferFrom(msg.sender, address(this), repayAmount), "Repay failed");
        require(collateral.transfer(msg.sender, seized), "Transfer failed");
    }
}

// BUG
// getPrice() validates staleness and positivity but does not check whether the returned price deviates significantly from the
// previous known price. A single corrupted oracle update (compromised node, extreme event, or feed misconfiguration) is
// consumed without question.

// IMPACT
// A corrupted oracle reporting 10x or 0.1x the real price enables mass liquidations of healthy positions (price too low) or
// unlimited borrowing against inflated collateral (price too high).

// INVARIANT
// Oracle prices must be sanity-checked against a reference band or previous value to detect corrupted updates before they
// affect financial operations.

// WHAT BREAKS
// getPrice() accepts any positive, fresh price from Chainlink without comparing it to historical prices or a secondary oracle.
// A single corrupted round (compromised Chainlink node, decimal change, aggregator misconfiguration) is blindly consumed.

// EXPLOIT PATH
// 1. Normal ETH/USD price = $3,000 (3000e8)
// 2. A compromised Chainlink oracle node pushes a corrupted answer = 300e8 ($300) through the aggregator's consensus (this has happened in historical incidents)
// 3. updatedAt is fresh (just updated), answer > 0. getPrice() returns 300e8
// 4. liquidate() sees collateral valued at 1/10 of reality. Every borrower's maxBorrow drops by 90%
// 5. All positions become liquidatable. Liquidators repay debt at book value and seize $3,000-worth of ETH for each $300 of repaid debt -- a 10x windfall
// 6. When the feed corrects, the damage is done: all collateral has been seized at the corrupted price.

// WHY MISSED
// Staleness + positivity checks are the standard Chainlink integration pattern recommended in most guides. The deviation check
// is an additional defense layer that many protocols omit. Auditors following a 'standard Chainlink checklist' may mark the
// oracle integration as complete after verifying staleness and positivity.
