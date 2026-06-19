// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title LSTLending
contract LSTLending {
    IERC20 public immutable stETH;
    IERC20 public immutable weth;
    AggregatorV3Interface public immutable ethUsdFeed;

    uint256 public constant LTV = 85;
    uint256 public constant LIQUIDATION_THRESHOLD = 90;

    mapping(address => uint256) public stEthDeposits;
    mapping(address => uint256) public wethBorrowed;

    constructor(address _steth, address _weth, address _ethUsdFeed) {
        stETH = IERC20(_steth);
        weth = IERC20(_weth);
        ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);
    }

    /// @notice Get st eth price
    // The function is called getStEthPrice but reads from ethUsdFeed. Is stETH always worth exactly 1 ETH?
    function getStEthPrice() public view returns (uint256) {
        (, int256 ethPrice,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        require(ethPrice > 0 && block.timestamp - updatedAt < 3600, "Bad price"); // 3600 / 60 = 60 = 1 hour
        // only checks price is not zero and within update time window
        return uint256(ethPrice);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(stETH.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        stEthDeposits[msg.sender] += amount;
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        uint256 price = getStEthPrice();
        uint256 collateralValue = stEthDeposits[msg.sender] * price / 1e8;
        uint256 maxBorrow = collateralValue * LTV / 100;
        require(wethBorrowed[msg.sender] + amount <= maxBorrow, "Over LTV");
        wethBorrowed[msg.sender] += amount;
        require(weth.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(address user) external {
        uint256 price = getStEthPrice();
        uint256 collateralValue = stEthDeposits[user] * price / 1e8;
        require(wethBorrowed[user] * 100 > collateralValue * LIQUIDATION_THRESHOLD, "Healthy");

        uint256 seized = stEthDeposits[user];
        stEthDeposits[user] = 0;
        wethBorrowed[user] = 0;
        require(stETH.transfer(msg.sender, seized), "Transfer failed");
    }
}

// BUG
// getStEthPrice() uses the ETH/USD feed to price stETH, assuming 1 stETH = 1 ETH. During market stress, stETH can depeg from 
// ETH (it traded at 0.93 ETH during the Terra crash). The protocol overvalues stETH collateral by ignoring the exchange rate.

// IMPACT
// During a depeg, users borrow WETH against overvalued stETH. If stETH depegs to 0.90 ETH, a user with 100 stETH can borrow as 
// if they had 100 ETH worth, creating 10% bad debt on every position.

// INVARIANT
// Correlated asset pricing must account for potential depegs by using the specific asset's oracle feed, not the underlying's 
// feed.

// WHAT BREAKS
// getStEthPrice() returns the ETH/USD price for stETH valuation, hardcoding a 1:1 peg assumption. During a depeg event, stETH 
// collateral is overvalued, and the protocol accumulates bad debt.

// EXPLOIT PATH
// 1. ETH/USD = $2,000. stETH depegs to 0.90 ETH (real price: $1,800)
// 2. Attacker buys 100 stETH on the market for 90 ETH ($180,000)
// 3. Deposits 100 stETH. getStEthPrice() returns $2,000 (ETH/USD, ignoring depeg)
// 4. collateralValue = 100 * 2000 = $200,000. maxBorrow = $170,000 (85% LTV)
// 5. Attacker borrows 170,000 worth of WETH. Collateral is only worth $180,000
// 6. If stETH drops to 0.85 ETH, collateral = $170,000. Attacker defaults. Bad debt: $0-17,000 depending on timing. At scale 
//    with many users, systematic bad debt accumulates.

// WHY MISSED
// The ETH/USD feed is a legitimate Chainlink oracle with proper staleness checks. The function name getStEthPrice does not 
// immediately alert to the 1:1 peg assumption. stETH is widely considered 'ETH-equivalent' in normal conditions, making this 
// a protocol design assumption rather than an obvious bug.
