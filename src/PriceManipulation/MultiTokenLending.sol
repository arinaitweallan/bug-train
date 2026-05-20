// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/// @title MultiTokenLending
contract MultiTokenLending {
    struct Market {
        address token;
        address priceFeed;
        uint256 ltv;
    }

    Market[] public markets;

    mapping(address => mapping(uint256 => uint256)) public deposits;
    mapping(address => uint256) public debt;
    IERC20 public immutable stablecoin;

    constructor(address _stable) {
        stablecoin = IERC20(_stable);
    }

    /// @notice Add a new entry or allocation
    /// @param _token Token contract address
    /// @param _feed Feed value
    /// @param _ltv Ltv value
    function addMarket(address _token, address _feed, uint256 _ltv) external {
        markets.push(Market(_token, _feed, _ltv));
    }

    /// @notice Get token price
    function getTokenPrice(uint256 marketId) public view returns (uint256) {
        Market memory m = markets[marketId];
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(m.priceFeed).latestRoundData();
        require(answer > 0 && block.timestamp - updatedAt < 3600, "Bad price");
        return uint256(answer);
    }

    /// @notice Deposit tokens into the contract
    /// @param marketId Market id value
    /// @param amount Token amount
    function deposit(uint256 marketId, uint256 amount) external {
        require(IERC20(markets[marketId].token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        deposits[msg.sender][marketId] += amount;
    }

    /// @notice Get collateral value
    // The formula multiplies deposits * price / 1e8. But deposits are in token-native decimals.
    // q What if one token has 6 decimals and another has 18?
    function getCollateralValue(address user) public view returns (uint256 totalValue) {
        for (uint256 i = 0; i < markets.length; i++) {
            uint256 price = getTokenPrice(i);
            totalValue += deposits[user][i] * price * markets[i].ltv / 100 / 1e8;
        }
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        uint256 value = getCollateralValue(msg.sender);
        require(debt[msg.sender] + amount <= value, "Over limit");
        debt[msg.sender] += amount;
        require(stablecoin.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(address user) external {
        require(debt[user] > getCollateralValue(user), "Healthy");
        debt[user] = 0;
    }
}

// BUG
// getCollateralValue() multiplies deposits[user][i] * price without normalizing for token decimals. USDC (6 decimals) deposits
// are treated the same as WETH (18 decimals). A deposit of 1000 USDC (1000e6) is valued 1e12 times less than 1000 WETH
// (1000e18) even if prices are similar.

// IMPACT
// Users depositing tokens with fewer decimals (USDC, USDT, WBTC) have their collateral severely undervalued, while tokens with
// 18 decimals are correctly valued. Alternatively, if the oracle returns 8-decimal prices for both, 6-decimal tokens get 1e12x
// undervalued.

// INVARIANT
// Collateral valuation must produce correct USD values regardless of the deposited token's decimal precision.

// WHAT BREAKS
// getCollateralValue() at line 48 does not normalize for token decimals. deposits[user][i] is in native token units (6 for USDC,
// 18 for WETH). Dividing by 1e8 (Chainlink decimals) is not sufficient -- the token decimal difference is unaccounted for.

// EXPLOIT PATH
// 1. WETH market (18 decimals, price $2000e8). User deposits 1 WETH (1e18). Value = 1e18 * 2000e8 / 1e8 = 2000e18. Correct
// 2. USDC market (6 decimals, price $1e8). User deposits $2000 USDC (2000e6). Value = 2000e6 * 1e8 / 1e8 = 2000e6. This is 1e12x too small
// 3. USDC depositor can only borrow 2000e6 / 1e18 = ~0 stablecoins. Their $2000 collateral is effectively worthless
// 4. Conversely, if an attacker deposits 1 WETH and borrows against it, the WETH is correctly valued -- but the pool's USDC collateral is phantom, leading to systematic undercollateralization.

// WHY MISSED
// The price feed integration looks correct (staleness check, positive price check, /1e8 for Chainlink decimals). The missing
// normalization is easy to overlook because the formula works perfectly for 18-decimal tokens. Testing with only WETH would
// never reveal the bug.

