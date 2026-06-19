// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IUniswapV3Pool {
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
}

/// @title AggregatedOracle
contract AggregatedOracle {
    AggregatorV3Interface public immutable chainlink;
    IUniswapV3Pool public immutable uniPool;
    IERC20 public immutable collateral;
    IERC20 public immutable debt;

    uint256 public constant LTV = 80;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public borrowed;

    constructor(address _cl, address _uni, address _coll, address _debt) {
        chainlink = AggregatorV3Interface(_cl);
        uniPool = IUniswapV3Pool(_uni);
        collateral = IERC20(_coll);
        debt = IERC20(_debt);
    }

    function getChainlinkPrice() internal view returns (uint256) {
        (, int256 answer,, uint256 upd,) = chainlink.latestRoundData();
        require(answer > 0 && block.timestamp - upd < 3600, "CL bad");
        return uint256(answer) * 1e10;
    }

    function getUniTWAP() internal view returns (uint256) {
        uint32[] memory secs = new uint32[](2);
        secs[0] = 1800;
        secs[1] = 0;
        (int56[] memory ticks,) = uniPool.observe(secs);
        int24 avg = int24((ticks[1] - ticks[0]) / 1800);
        return uint256(int256(avg) + 100_000) * 1e14;
    }

    /// @notice Get price
    function getPrice() public view returns (uint256) {
        uint256 clPrice = getChainlinkPrice();
        uint256 uniPrice = getUniTWAP();
        // clPrice = 2000 (steady state) uniPrice = 1980  | 2000 (we use the real price)
        // clPrice = 2200 (rapid increase) uniPrice = 1980| 2200 (we use the real price still)
        // clPrice = 1800 (rapid decrease) uniPrice = 1980| 1980 (we use the twap price because the price drop rapidly)
        return clPrice > uniPrice ? clPrice : uniPrice;
    }

    /// @notice Deposit tokens into the contract
    /// @param collAmt Coll amt value
    /// @param borrowAmt Borrow amt value
    function depositAndBorrow(uint256 collAmt, uint256 borrowAmt) external {
        require(collateral.transferFrom(msg.sender, address(this), collAmt), "Transfer failed");
        deposits[msg.sender] += collAmt;
        uint256 price = getPrice();
        uint256 value = deposits[msg.sender] * price / 1e18;
        require(borrowed[msg.sender] + borrowAmt <= value * LTV / 100, "Over LTV");
        borrowed[msg.sender] += borrowAmt;
        require(debt.transfer(msg.sender, borrowAmt), "Transfer failed");
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(address user) external {
        uint256 price = getPrice();
        uint256 value = deposits[user] * price / 1e18;
        require(borrowed[user] > value * 90 / 100, "Healthy");
        deposits[user] = 0;
        borrowed[user] = 0;
    }
}

// BUG
// getPrice() returns max(chainlinkPrice, uniTWAP). An attacker only needs to manipulate ONE source upward to inflate the final 
// price. The Uniswap TWAP is cheaper to manipulate than Chainlink, so the attacker can push the TWAP above Chainlink to set 
// the reported price.

// IMPACT
// The attacker borrows against collateral valued at the higher of two oracles. By manipulating the cheaper oracle (TWAP) upward, 
// they can borrow more than the collateral is worth at the true market price.

// INVARIANT
// Multi-oracle aggregation must not allow manipulation of the easiest-to-influence source to determine the final price.

// WHAT BREAKS
// getPrice() returns the maximum of Chainlink and Uniswap TWAP. For collateral valuation, max() is the wrong aggregation 
// because it gives the attacker two chances to inflate the price -- they only need to push the cheaper source upward.

// EXPLOIT PATH
// 1. Chainlink ETH/USD = $2,000. Uniswap TWAP = $2,000. getPrice() = $2,000
// 2. Attacker manipulates Uniswap pool: sustains buy pressure for 30 min, pushing TWAP to $3,000. Cost: ~$100K
// 3. getPrice() = max($2,000, $3,000) = $3,000
// 4. Attacker deposits 100 ETH. value = 100 * $3,000 = $300K. maxBorrow = $240K
// 5. Fair borrow limit: 100 * $2,000 * 80% = $160K. Excess borrowed: $80K
// 6. After TWAP normalizes, attacker defaults. Bad debt: $80K. Profit: $80K - $100K manip cost = marginal at this scale, 
// profitable at larger scale.

// WHY MISSED
// Using two oracle sources and taking the maximum appears conservative and redundant. The presence of both Chainlink (reliable) 
// and TWAP (decentralized) suggests defense-in-depth. The issue is that max() is the wrong aggregation for defensive pricing 
// -- it should be min() for collateral and max() for debt.
