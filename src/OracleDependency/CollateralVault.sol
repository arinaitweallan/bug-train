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

/// @title CollateralVault
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract CollateralVault {
    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    AggregatorV3Interface public immutable priceFeed;

    uint256 public constant MAX_STALENESS = 3600;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public borrowed;

    constructor(address _collateral, address _debt, address _feed) {
        collateralToken = IERC20(_collateral);
        debtToken = IERC20(_debt);
        priceFeed = AggregatorV3Interface(_feed);
    }

    /// @notice Get token price
    function getTokenPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(block.timestamp - updatedAt <= MAX_STALENESS, "Stale price");
        return uint256(answer);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(collateralToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        deposits[msg.sender] += amount;
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        uint256 price = getTokenPrice();
        uint256 maxBorrow = (deposits[msg.sender] * price) / 1e8 / 2;
        require(borrowed[msg.sender] + amount <= maxBorrow, "Over limit");
        borrowed[msg.sender] += amount;
        require(debtToken.transfer(msg.sender, amount), "Debt transfer failed");
    }

    /// @notice Repay borrowed debt
    function repay(uint256 amount) external {
        require(amount <= borrowed[msg.sender], "Repay exceeds debt");
        borrowed[msg.sender] -= amount;
        require(debtToken.transferFrom(msg.sender, address(this), amount), "Repay transfer failed");
    }

    /// @notice Is liquidatable
    function isLiquidatable(address user) public view returns (bool) {
        uint256 price = getTokenPrice();
        uint256 collateralValue = (deposits[user] * price) / 1e8;
        return borrowed[user] > (collateralValue * 80) / 100;
    }
}

// BUG
// The int256 answer is cast directly to uint256 without checking answer > 0. Chainlink can return 0 during flash crashes or
// negative values from misconfigured aggregators. Casting a negative int256 to uint256 produces a massive number; zero causes
// division-by-zero or zero-value collateral.

// IMPACT
// A zero price makes all collateral worthless (maxBorrow = 0 for new borrows, but existing positions become instantly
// liquidatable). A negative-to-uint256 wrap produces an astronomically high price, letting users borrow unlimited funds.

// INVARIANT
// The oracle price must always be a positive value before being used in any collateral or borrowing calculation.

// WHAT BREAKS
// getTokenPrice() casts int256 answer to uint256 without validating answer > 0. If Chainlink returns 0 (aggregator bug, flash
// crash) or a negative value (misconfigured feed), the cast either produces 0 or wraps to 2^255+, breaking all accounting.

// EXPLOIT PATH
// 1. Chainlink ETH/USD feed returns answer = 0 during a temporary aggregator malfunction
// 2. getTokenPrice() returns 0. isLiquidatable() computes collateralValue = deposits[user] * 0 / 1e8 = 0
// 3. Any user with borrowed > 0 becomes instantly liquidatable: borrowed[user] > 0 * 80 / 100 = 0 is true
// 4. Liquidator seizes all collateral across every borrower during the zero-price window
// 5. Alternatively, if answer = -1, uint256(-1) = type(uint256).max. maxBorrow becomes astronomical, letting an attacker borrow the entire pool via borrow().

// WHY MISSED
// The staleness check (block.timestamp - updatedAt <= MAX_STALENESS) provides a false sense of completeness. Auditors see
// validation logic and assume the price is fully validated, overlooking the missing positivity check on a different return field.
