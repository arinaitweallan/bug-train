// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface AggregatorV3Interface {
    /// @notice Performs the latestRoundData operation for the protocol.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title L2LendingPool - Deployed on Arbitrum
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract L2LendingPool {
    IERC20 public immutable collateralToken;
    IERC20 public immutable stableToken;
    AggregatorV3Interface public immutable priceFeed;

    uint256 public constant STALENESS = 3600;
    uint256 public constant LTV_BPS = 7500;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    constructor(address _collateral, address _stable, address _feed) {
        collateralToken = IERC20(_collateral);
        stableToken = IERC20(_stable);
        priceFeed = AggregatorV3Interface(_feed);
    }

    /// @notice Get price
    function getPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        // oracles on L2s need sequencers
        require(answer > 0, "Invalid price");
        require(block.timestamp - updatedAt <= STALENESS, "Stale");
        return uint256(answer);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(collateralToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        collateral[msg.sender] += amount;
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        uint256 price = getPrice();
        uint256 maxDebt = (collateral[msg.sender] * price * LTV_BPS) / (1e8 * 10000);
        require(debt[msg.sender] + amount <= maxDebt, "Exceeds LTV");
        debt[msg.sender] += amount;
        require(stableToken.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Liquidates a position that fails the health check.
    function liquidate(address user) external {
        uint256 price = getPrice();
        uint256 maxDebt = (collateral[user] * price * LTV_BPS) / (1e8 * 10000);
        require(debt[user] > maxDebt, "Healthy");

        uint256 repayAmount = debt[user];
        uint256 seized = collateral[user];
        collateral[user] = 0;
        debt[user] = 0;

        require(stableToken.transferFrom(msg.sender, address(this), repayAmount), "Repay failed");
        require(collateralToken.transfer(msg.sender, seized), "Transfer failed");
    }
}

// BUG
// On Arbitrum (L2), the Chainlink sequencer uptime feed is not checked. After a sequencer outage, the price feed may appear
// fresh (updatedAt is recent because updates resume) but the prices do not yet reflect current market conditions, creating an
// exploitable window

// IMPACT
// After sequencer recovery, stale-but-technically-fresh prices enable unfair liquidations of positions that moved during the
// outage, or allow borrowing against outdated collateral values via borrow() and liquidate()

// INVARIANT
// c

// WHAT BREAKS
// The contract is deployed on Arbitrum but does not query the Chainlink L2 sequencer uptime feed. After a sequencer outage
// lasting hours, the sequencer resumes and Chainlink updates the feed. The staleness check passes (updatedAt is fresh), but
// the price has not yet caught up to the real market price.

// EXPLOIT PATH
// 1. Arbitrum sequencer goes down for 2 hours. During downtime, ETH drops from $3,000 to $2,000 on mainnet
// 2. Sequencer comes back online. Chainlink pushes a new round with answer=$2,800 (first post-recovery update, still lagging)
// 3. updatedAt is now recent, so staleness check passes. getPrice() returns $2,800
// 4. Attacker deposits ETH at the $2,800 valuation and borrows stablecoins up to 75% LTV
// 5. Next oracle update reflects $2,000 reality. Attacker's position is underwater but they already withdrew the borrowed funds. Protocol absorbs $800/ETH in bad debt.

// WHY MISSED
// The staleness check and price positivity check are both present and correct for L1. The L2 sequencer risk is a
// deployment-context issue, not a code-logic issue, so auditors reviewing the Solidity in isolation may not consider the L2
// deployment target.
