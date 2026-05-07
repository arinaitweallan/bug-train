// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Permissionless Oracle Reset Bricks Lending Liquidations

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LendingOracle
contract LendingOracle {
    using SafeERC20 for IERC20;

    struct PriceData {
        uint256 price;
        uint256 timestamp;
    }

    mapping(address => PriceData) public prices;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    IERC20 public collateralToken;
    IERC20 public borrowToken;

    uint256 public constant COLLATERAL_RATIO = 150;
    uint256 public constant STALENESS_THRESHOLD = 1 hours;

    event PriceSubmitted(address indexed token, uint256 price);
    event Borrowed(address indexed user, uint256 collateralAmt, uint256 borrowAmt);
    event Liquidated(address indexed user, address indexed liquidator, uint256 seized);

    constructor(address _collateralToken, address _borrowToken) {
        collateralToken = IERC20(_collateralToken);
        borrowToken = IERC20(_borrowToken);
    }

    /// @notice Submit a price update
    /// @param token Token contract address
    /// @param price Price value
    function submitPrice(address token, uint256 price) external {
        prices[token] = PriceData(price, block.timestamp);
        emit PriceSubmitted(token, price);
    }

    /// @notice Borrow tokens against collateral
    /// @param token Token used for price lookup
    /// @param collateralAmount Collateral token amount
    /// @param borrowAmount Amount to borrow
    function borrow(address token, uint256 collateralAmount, uint256 borrowAmount) external {
        require(prices[token].price > 0, "No price");
        require(block.timestamp - prices[token].timestamp < STALENESS_THRESHOLD, "Stale price");
        uint256 collateralValue = collateralAmount * prices[token].price / 1e18;
        require(collateralValue * 100 >= borrowAmount * COLLATERAL_RATIO, "Undercollateralized");
        collateralToken.safeTransferFrom(msg.sender, address(this), collateralAmount);
        collateral[msg.sender] += collateralAmount;
        debt[msg.sender] += borrowAmount;
        borrowToken.safeTransfer(msg.sender, borrowAmount);
        emit Borrowed(msg.sender, collateralAmount, borrowAmount);
    }

    /// @notice Liquidate an undercollateralized position
    /// @param user User address
    /// @param token Token used for price lookup
    function liquidate(address user, address token) external {
        require(prices[token].price > 0, "No price");
        require(block.timestamp - prices[token].timestamp < STALENESS_THRESHOLD, "Stale price");
        require(debt[user] > 0, "No debt");
        uint256 collateralValue = collateral[user] * prices[token].price / 1e18;
        require(collateralValue * 100 < debt[user] * COLLATERAL_RATIO, "Not liquidatable");
        uint256 seized = collateral[user];
        uint256 debtRepaid = debt[user];
        collateral[user] = 0;
        debt[user] = 0;
        borrowToken.safeTransferFrom(msg.sender, address(this), debtRepaid);
        collateralToken.safeTransfer(msg.sender, seized);
        emit Liquidated(user, msg.sender, seized);
    }

    /// @notice Get price
    function getPrice(address token) external view returns (uint256, uint256) {
        return (prices[token].price, prices[token].timestamp);
    }

    /// @notice Get health factor
    /// @param user User address
    /// @param token Token used for price lookup
    function getHealthFactor(address user, address token) external view returns (uint256) {
        if (debt[user] == 0) return type(uint256).max;
        uint256 collateralValue = collateral[user] * prices[token].price / 1e18;
        return (collateralValue * 100) / debt[user];
    }
}

// INVARIANT
// Only authorized oracle operators should be able to update price feeds used by critical lending operations

// WHAT BREAKS
// An attacker calls submitPrice(token, type(uint256).max) to set the collateral price extremely high. Now collateralValue * 100
// is always >= debt * COLLATERAL_RATIO, so the liquidation check at line 38 always fails. Undercollateralized positions cannot
// be liquidated. Alternatively, the attacker sets price to 0, causing require(prices[token].price > 0) to block both borrows
// and liquidations entirely.

// EXPLOIT PATH
// 1. User borrows against 100 ETH collateral. ETH price drops and position becomes liquidatable
// 2. Attacker calls submitPrice(ethAddress, type(uint256).max)
// 3. prices[ethAddress] = PriceData(type(uint256).max, block.timestamp)
// 4. Liquidator calls liquidate(user, ethAddress)
// 5. collateralValue = 100e18 * type(uint256).max / 1e18 = type(uint256).max
// 6. require(type(uint256).max * 100 < debt * 150) fails because collateral value is astronomically high
// 7. Liquidation reverts. Bad debt accumulates. Protocol becomes insolvent.

// WHY MISSED
// Auditors may assume submitPrice will be replaced with a proper oracle integration before deployment, or that the
// permissionless nature is intentional for a decentralized oracle design. The missing access control on a price setter
// is straightforward but easily dismissed as a design choice.
