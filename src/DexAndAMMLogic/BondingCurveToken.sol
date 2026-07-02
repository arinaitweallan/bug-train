// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BondingCurveToken
/// @notice Automated market maker contract that provides on-chain liquidity and swap routing.
contract BondingCurveToken is ERC20 {
    uint256 public reserveBalance;

    uint256 public constant RESERVE_RATIO = 500000;
    uint256 public constant MAX_RATIO = 1000000;
    uint256 public constant MIN_PURCHASE = 0.001 ether;

    uint256 public totalBuys;
    uint256 public totalSells;

    event TokensPurchased(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 price);
    event TokensSold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 price);

    constructor() ERC20("BondToken", "BOND") {}

    /// @notice Get current price
    function getCurrentPrice() public view returns (uint256) {
        if (totalSupply() == 0) return 1e18;
        return reserveBalance * MAX_RATIO / (totalSupply() * RESERVE_RATIO);
    }

    /// @notice Estimate buy
    function estimateBuy(uint256 ethAmount) external view returns (uint256) {
        uint256 price = getCurrentPrice();
        return ethAmount * 1e18 / price;
    }

    /// @notice Estimate sell
    function estimateSell(uint256 tokenAmount) external view returns (uint256) {
        uint256 price = getCurrentPrice();
        return tokenAmount * price / 1e18;
    }

    /// @notice Purchase tokens or assets
    function buy() external payable returns (uint256 tokensOut) {
        require(msg.value >= MIN_PURCHASE, "Below minimum");

        uint256 price = getCurrentPrice();
        tokensOut = msg.value * 1e18 / price;
        require(tokensOut > 0, "Zero tokens");

        reserveBalance += msg.value;
        _mint(msg.sender, tokensOut);
        totalBuys++;

        emit TokensPurchased(msg.sender, msg.value, tokensOut, price);
    }

    /// @notice Sell tokens or assets
    function sell(uint256 tokenAmount) external returns (uint256 ethOut) {
        require(tokenAmount > 0, "Zero amount");
        require(balanceOf(msg.sender) >= tokenAmount, "Insufficient balance");

        uint256 price = getCurrentPrice();
        ethOut = tokenAmount * price / 1e18;
        require(ethOut <= reserveBalance, "Insufficient reserve");

        reserveBalance -= ethOut;
        _burn(msg.sender, tokenAmount);
        totalSells++;

        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "ETH transfer failed");

        emit TokensSold(msg.sender, tokenAmount, ethOut, price);
    }

    /// @notice Get reserve
    function getReserve() external view returns (uint256) {
        return reserveBalance;
    }

    /// @notice Get market cap
    function getMarketCap() external view returns (uint256) {
        return totalSupply() * getCurrentPrice() / 1e18;
    }

    receive() external payable {
        reserveBalance += msg.value;
    }
}
