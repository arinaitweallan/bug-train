// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IBalancerPool {
    /// @notice Returns the total supply of outstanding shares.
    function totalSupply() external view returns (uint256);
    /// @notice Performs the getActualSupply operation for the protocol.
    function getActualSupply() external view returns (uint256);
    /// @notice Performs the getPoolId operation for the protocol.
    function getPoolId() external view returns (bytes32);
}

interface IBalancerVault {
    /// @notice Performs the getPoolTokens operation for the protocol.
    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

interface AggregatorV3Interface {
    /// @notice Performs the latestRoundData operation for the protocol.
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

// The interface exposes both totalSupply() and getActualSupply(). Which one represents the circulating supply of a Balancer
// pool with pre-minted BPT?

// Balancer composable stable pools pre-mint the max BPT supply. totalSupply() includes this pre-minted amount, while
// getActualSupply() returns only the circulating BPT.

/// @title BPTOracle
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract BPTOracle {
    IBalancerPool public immutable bptPool;
    IBalancerVault public immutable balancerVault;

    mapping(address => AggregatorV3Interface) public tokenFeeds;

    constructor(address _pool, address _vault, address[] memory _tokens, address[] memory _feeds) {
        bptPool = IBalancerPool(_pool);
        balancerVault = IBalancerVault(_vault);

        require(_tokens.length == _feeds.length, "Length mismatch");
        for (uint256 i = 0; i < _tokens.length; i++) {
            tokenFeeds[_tokens[i]] = AggregatorV3Interface(_feeds[i]);
        }
    }

    /// @notice Get bptprice
    function getBPTPrice() public view returns (uint256) {
        bytes32 poolId = bptPool.getPoolId();
        (address[] memory tokens, uint256[] memory balances,) = balancerVault.getPoolTokens(poolId);
        uint256 totalValue = 0;

        for (uint256 i = 0; i < balances.length; i++) {
            AggregatorV3Interface feed = tokenFeeds[tokens[i]];
            (, int256 tokenPrice,, uint256 updatedAt,) = feed.latestRoundData();
            require(tokenPrice > 0 && block.timestamp - updatedAt < 3600, "Bad price");
            // token prices of different tokens are returned in different decimals
            // the loop divides by 1e8 for every token, is this right?
            totalValue += (balances[i] * uint256(tokenPrice)) / 1e8;
        }
        uint256 supply = bptPool.totalSupply();
        return (totalValue * 1e18) / supply;
    }

    /// @notice Get collateral value
    function getCollateralValue(uint256 bptAmount) external view returns (uint256) {
        return (bptAmount * getBPTPrice()) / 1e18;
    }
}

// BUG
// Uses totalSupply() instead of getActualSupply(). Balancer composable stable pools pre-mint BPT held inside the pool itself,
// so totalSupply() includes those non-circulating tokens. The actual circulating supply is much smaller, so dividing by
// totalSupply() dramatically underprices each BPT token.

// IMPACT
// BPT is undervalued. getCollateralValue() returns a near-zero value for any BPT amount, causing lending protocols to under-credit
// BPT collateral and triggering unfair liquidations.

// INVARIANT
// LP token pricing must use the actual circulating supply, not the total supply which may include pre-minted or protocol-owned
// tokens.

// WHAT BREAKS
// totalSupply() for Balancer composable stable pools includes ~2^111 pre-minted BPT. The actual circulating supply
// (getActualSupply) is orders of magnitude smaller. Dividing totalValue by the inflated totalSupply produces a BPT price near
// zero.

// EXPLOIT PATH
// 1. Pool holds $10M in assets. getActualSupply() = 5M BPT. Correct BPT price = $10M / 5M = $2
// 2. But totalSupply() = 2^111 + 5M (pre-minted). getBPTPrice() = ($10M * 1e18) / 2^111 which is approximately 3.8e-21 (virtually zero)
// 3. A lending protocol using this oracle values 1M BPT collateral at essentially $0
// 4. Users' BPT collateral is worthless according to the oracle, triggering mass liquidations
// 5. Liquidators seize BPT worth $2M for near-zero repayment cost.

// WHY MISSED
// totalSupply() is the standard ERC20 function used universally for supply queries. The Balancer-specific distinction between
// totalSupply and getActualSupply requires protocol-specific knowledge. The interface even includes getActualSupply, but
// auditors may not know why both exist.
