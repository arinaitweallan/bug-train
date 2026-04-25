// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// @title CrossAssetOracle
contract CrossAssetOracle {
    address public admin;

    mapping(address => AggregatorV3Interface) public priceFeeds;
    mapping(address => mapping(address => uint256)) public tokenDeposits;

    constructor() {
        admin = msg.sender;
    }

    /// @notice Configure a contract parameter
    /// @param token Token contract address
    /// @param feed Feed value
    function setFeed(address token, address feed) external {
        require(msg.sender == admin, "Not admin");
        priceFeeds[token] = AggregatorV3Interface(feed);
    }

    /// @notice Get price
    function getPrice(address token) public view returns (uint256) {
        AggregatorV3Interface feed = priceFeeds[token];
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        require(answer > 0 && block.timestamp - updatedAt < 3600, "Bad");
        return uint256(answer);
    }

    /// @notice Deposit tokens into the contract
    /// @param token Token contract address
    /// @param amount Token amount
    function deposit(address token, uint256 amount) external {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        tokenDeposits[msg.sender][token] += amount;
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(address token, uint256 amount) external {
        require(tokenDeposits[msg.sender][token] >= amount, "Insufficient");

        tokenDeposits[msg.sender][token] -= amount;
        require(IERC20(token).transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Get account value in USD (scaled by 1e8)
    function getAccountValue(address user, address token) external view returns (uint256) {
        return (tokenDeposits[user][token] * getPrice(token)) / 1e8;
    }
}

// INVARIANT
// Privileged admin functions that wire external dependencies must either (a) validate the dependency's identity on-chain,
// or (b) be guarded by a multi-sig + timelock so the misconfiguration window is reviewable before execution.

// WHAT BREAKS
// setFeed() trusts the admin to bind feeds correctly but the contract never verifies the binding matches the token's real
// asset. A single typo in a governance transaction mis-prices the token permanently until another setFeed() call corrects it.

// EXPLOIT PATH
// 1. Admin calls setFeed(SHITCOIN_ADDRESS, ETH_USD_FEED) by mistake (wrong token address in a governance proposal payload)
// 2. SHITCOIN (real price $0.001) is now priced via ETH/USD feed returning $3,000
// 3. Attacker buys 1,000e18 SHITCOIN for $1 total on a DEX
// 4. Attacker calls deposit(SHITCOIN, 1000e18). tokenDeposits[attacker][SHITCOIN] += 1000e18
// 5. getAccountValue(attacker, SHITCOIN) = 1000e18 * 3000e8 / 1e8 = 3,000,000e18 ($3,000,000)
// 6. Attacker is credited with $3,000,000 in collateral value for $1 of tokens. They borrow or withdraw protocol assets accordingly.

// WHY MISSED
// Feed assignment is an admin configuration step, not a code-level computation. Auditors may treat setFeed as a trusted
// admin operation and focus on the price consumption logic. Classifying the risk as 'access control' makes the review
// question explicit: is the admin key trustworthy enough to hold this much protocol value?
