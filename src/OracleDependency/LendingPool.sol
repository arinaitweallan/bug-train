// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface AggregatorV3Interface {
    /// @notice Performs the latestRoundData operation for the protocol.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    /// @notice Returns the number of decimals used.
    function decimals() external view returns (uint8);
}

/// @title LendingPool
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract LendingPool {
    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    AggregatorV3Interface public immutable priceFeed;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;
    uint256 public constant LTV = 75;

    constructor(address _collateral, address _debt, address _feed) {
        collateralToken = IERC20(_collateral);
        debtToken = IERC20(_debt);
        priceFeed = AggregatorV3Interface(_feed);
    }

    /// @notice Get price
    function getPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        // easy one
        // @bug: staleness of the price is not checked
        require(answer > 0, "Invalid price");
        return uint256(answer);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(amount > 0, "Zero amount");
        require(collateralToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        collateral[msg.sender] += amount;
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        uint256 price = getPrice();
        uint256 collateralValue = (collateral[msg.sender] * price) / 1e8;
        uint256 maxBorrow = (collateralValue * LTV) / 100;
        require(debt[msg.sender] + amount <= maxBorrow, "Exceeds LTV");
        debt[msg.sender] += amount;
        require(debtToken.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Liquidates a position that fails the health check.
    function liquidate(address user) external {
        uint256 price = getPrice();
        uint256 collateralValue = (collateral[user] * price) / 1e8;
        uint256 maxBorrow = (collateralValue * LTV) / 100;
        require(debt[user] > maxBorrow, "Not liquidatable");
        uint256 repayAmount = debt[user];
        uint256 seized = collateral[user];
        collateral[user] = 0;
        debt[user] = 0;
        require(debtToken.transferFrom(msg.sender, address(this), repayAmount), "Repay failed");
        require(collateralToken.transfer(msg.sender, seized), "Transfer failed");
    }
}

// BUG
// The updatedAt value from latestRoundData() is fetched but never compared against a staleness threshold. During Chainlink
// feed outages or network congestion, the protocol will consume arbitrarily old prices.

// IMPACT
// Stale prices allow users to borrow against inflated collateral values or avoid legitimate liquidations, causing protocol
// insolvency.

// INVARIANT
// The oracle price used in any financial calculation must have been updated within a protocol-defined heartbeat window
// (e.g., 3600 seconds for ETH/USD).

// WHAT BREAKS
// The getPrice() function reads updatedAt in the destructure but never validates it against block.timestamp. If the Chainlink
// feed stops updating (outage, congestion, gas spike), the protocol keeps using the last reported price indefinitely.

// EXPLOIT PATH
// 1. ETH/USD Chainlink feed last updated 12 hours ago at $3,000. Current market price has crashed to $1,500
// 2. Attacker deposits 10 ETH as collateral. getPrice() returns the stale $3,000
// 3. collateralValue = 10 * 3000e8 / 1e8 = $30,000. maxBorrow = $30,000 * 75 / 100 = $22,500
// 4. Attacker borrows 22,500 debtTokens against collateral actually worth $15,000
// 5. Attacker defaults. Protocol is left with $15,000 collateral backing $22,500 debt = $7,500 bad debt per position.

// WHY MISSED
// The code fetches updatedAt in the destructured return (suggesting awareness), and the require(answer > 0) check creates a
// false sense of complete validation. Auditors may assume the staleness check exists elsewhere or that fetching the variable
// implies it is used.
