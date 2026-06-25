// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface AggregatorV3Interface {
    /// @notice Performs the latestRoundData operation for the protocol.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    /// @notice Returns the number of decimals used.
    function decimals() external view returns (uint8);
}

/// @title TreasuryVault
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract TreasuryVault {
    struct TokenConfig {
        IERC20 token;
        AggregatorV3Interface feed;
    }
    address public owner;
    TokenConfig[] public tokens;

    constructor() {
        owner = msg.sender;
    }

    /// @notice Add a new entry or allocation
    /// @param _token Token contract address
    /// @param _feed Feed value
    function addToken(address _token, address _feed) external {
        require(msg.sender == owner, "Not owner");
        tokens.push(TokenConfig(IERC20(_token), AggregatorV3Interface(_feed)));
    }

    /// @notice Get token value
    /// @param index Array or position index
    /// @param amount Token amount
    function getTokenValue(uint256 index, uint256 amount) public view returns (uint256) {
        TokenConfig memory config = tokens[index];
        (, int256 answer,, uint256 updatedAt,) = config.feed.latestRoundData();
        require(answer > 0 && block.timestamp - updatedAt < 3600, "Bad price");
        uint256 price = uint256(answer);
        return (amount * price) / 1e18;
    }

    /// @notice Get total value
    function getTotalValue() public view returns (uint256 total) {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = tokens[i].token.balanceOf(address(this));
            total += getTokenValue(i, balance);
        }
    }

    /// @notice Withdraw tokens from the contract
    /// @param index Array or position index
    /// @param amount Token amount
    function withdraw(uint256 index, uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        require(tokens[index].token.transfer(msg.sender, amount), "Transfer failed");
    }
}

// BUG
// The price normalization divides by 1e18, which is the token-decimal scale but ignores the feed's 1e8 decimal scale. For an
// 18-decimal token and an 8-decimal Chainlink feed, the correct divisor is 1e8 * 1e18 = 1e26. Dividing by 1e18 alone leaves
// an extra 1e8 factor unnormalized, causing the result to undervalue the position by a factor of 1000 relative to the expected
// 8-decimal USD representation.

// IMPACT
// getTokenValue() and getTotalValue() report the vault's holdings as 1000x smaller than reality for 8-decimal feeds paired with
// 18-decimal tokens. Any downstream protocol using these values for collateral ratios, rebalancing, or risk management operates
// on a 1000x incorrect valuation.

// INVARIANT
// Price normalization must divide by (token decimals * feed decimals), not token decimals alone. The scale of the divisor must
// equal the combined scale of the multiplied operands.

// WHAT BREAKS
// getTokenValue() divides by 1e18 only. For an 18-decimal token and an 8-decimal Chainlink feed, the correct normalization
// is /1e26 (1e18 token scale * 1e8 feed scale). Dropping the 1e8 factor produces a result with 1000x less magnitude than the
// expected 8-decimal USD value.

// EXPLOIT PATH
// 1. Vault holds 1,000 WETH (amount = 1000e18, 18 decimals). Chainlink ETH/USD feed returns price = 3000e8 (3,000 with 8 decimals)
// 2. Correct USD value in 8-decimal representation = 1,000 * 3,000 * 1e8 = 3e14
// 3. getTokenValue(): (1000e18 * 3000e8) / 1e18 = 3000e8 = 3e11
// 4. Actual result 3e11 vs expected 3e14 -- a factor of 1000x undervaluation in the 8-decimal USD scale
// 5. getTotalValue() sums these undervalued entries. A $3,000,000 treasury is reported as $3,000
// 6. Any downstream rebalancer or risk engine consuming this value operates on collateral that appears 1000x smaller than reality, potentially skipping rebalances or triggering emergency withdrawals that drain the vault.

// WHY MISSED
// The code queries feed.decimals() via the interface definition but never calls it. The 1e18 divisor looks like standard
// Solidity precision handling, and auditors familiar with 18-decimal ERC20 tokens may conflate token decimals with feed decimals.

