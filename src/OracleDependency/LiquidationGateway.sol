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

/// @title LiquidationGateway
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract LiquidationGateway {
    AggregatorV3Interface public immutable priceFeed;
    IERC20 public immutable collateral;
    IERC20 public immutable debt;

    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public debtBalance;

    uint256 public constant LTV = 80;

    constructor(address _feed, address _collateral, address _debt) {
        priceFeed = AggregatorV3Interface(_feed);
        collateral = IERC20(_collateral);
        debt = IERC20(_debt);
    }

    /// @notice Get validated price
    function getValidatedPrice() public view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        require(answer > 0, "Negative price");

        require(updatedAt > 0, "Incomplete round");
        require(answeredInRound >= roundId, "Stale round");
        require(block.timestamp - updatedAt < 3600, "Stale price");
        return uint256(answer);
    }

    /// @notice Deposit collateral
    function deposit(uint256 amount) external {
        require(collateral.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        collateralBalance[msg.sender] += amount;
    }

    /// @notice Borrow debt tokens against collateral
    function borrow(uint256 amount) external {
        uint256 price = getValidatedPrice();
        uint256 maxDebt = (collateralBalance[msg.sender] * price * LTV) / (1e8 * 100);
        require(debtBalance[msg.sender] + amount <= maxDebt, "Exceeds LTV");
        debtBalance[msg.sender] += amount;
        require(debt.transfer(msg.sender, amount), "Debt transfer failed");
    }

    /// @notice Liquidates a position that fails the health check.
    function liquidate(address user) external {
        uint256 price = getValidatedPrice();
        uint256 maxDebt = (collateralBalance[user] * price * LTV) / (1e8 * 100);
        require(debtBalance[user] > maxDebt, "Healthy");
        uint256 repayAmount = debtBalance[user];
        uint256 seized = collateralBalance[user];
        collateralBalance[user] = 0;
        debtBalance[user] = 0;
        require(debt.transferFrom(msg.sender, address(this), repayAmount), "Repay failed");
        require(collateral.transfer(msg.sender, seized), "Transfer failed");
    }
}

// BUG
// getValidatedPrice() reverts on any oracle failure condition (negative price, incomplete round, stale round, stale price).
// There is no try/catch or fallback mechanism. If the Chainlink feed enters any invalid state, ALL functions depending on
// getValidatedPrice() are DoS'd, including liquidations.

// IMPACT
// Liquidations revert when the oracle is unavailable. Unhealthy positions accumulate bad debt because they cannot be liquidated
// during the outage. This can lead to protocol insolvency if the outage coincides with a market crash.

// INVARIANT
// Critical protocol operations like liquidations must have a fallback price mechanism to prevent denial of service when the
// primary oracle is temporarily unavailable.

// WHAT BREAKS
// getValidatedPrice() has strict validation (which is good) but ONLY reverts on failure (which is bad for critical paths).
// When the Chainlink feed has an incomplete round, answeredInRound < roundId, or any other anomaly, liquidations are completely
// blocked.

// EXPLOIT PATH
// 1. A user borrows at 75% of max LTV via borrow(), pushing debtBalance[user] close to the liquidation threshold
// 2. Chainlink ETH/USD feed enters an incomplete round state (roundId increments but answeredInRound has not caught up -- this happens during aggregator phase transitions)
// 3. getValidatedPrice() calls latestRoundData(). answeredInRound < roundId. The require on line 34 reverts
// 4. All calls to liquidate() revert because they depend on getValidatedPrice()
// 5. ETH price crashes 40% during this window. The borrower's position at 80% LTV is now deeply insolvent
// 6. When the feed recovers, the position is liquidated but the collateral only covers a fraction of the debt. Protocol absorbs the difference as bad debt.

// WHY MISSED
// Strict oracle validation is generally good practice and appears defensive. Auditors may praise the thorough round validation
// without considering that the critical path (liquidations) needs a fallback rather than a hard revert. The vulnerability is in
// the absence of a graceful degradation path, not in the presence of bad code.
