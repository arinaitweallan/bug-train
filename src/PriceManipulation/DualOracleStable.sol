// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IUniswapV3Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

/// @title DualOracleStable
contract DualOracleStable is ERC20 {
    IERC20 public immutable collateral;
    AggregatorV3Interface public immutable chainlinkFeed;
    IUniswapV3Pool public immutable uniPool;

    uint256 public constant COLLATERAL_RATIO = 150;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public minted;

    constructor(address _coll, address _feed, address _pool) ERC20("DualStable", "dUSD") {
        collateral = IERC20(_coll);
        chainlinkFeed = AggregatorV3Interface(_feed);
        uniPool = IUniswapV3Pool(_pool);
    }

    /// @notice Get chainlink price
    function getChainlinkPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = chainlinkFeed.latestRoundData();

        // q when last updated for more than 1 hour, revert
        require(answer > 0 && block.timestamp - updatedAt < 3600, "Bad CL price");
        return uint256(answer) * 1e10; // q is this the right scale?
    }

    /// @notice Get uniswap price
    function getUniswapPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = uniPool.slot0();
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
    }

    /// @notice Mint new tokens or shares
    /// @param collateralAmt Collateral amt value
    /// @param stableAmt Stable amt value
    function mint(uint256 collateralAmt, uint256 stableAmt) external {
        require(collateral.transferFrom(msg.sender, address(this), collateralAmt), "Transfer failed");

        deposits[msg.sender] += collateralAmt;
        uint256 price = getChainlinkPrice();

        // 1000e18 * 1e10 / 1e18
        uint256 value = deposits[msg.sender] * price / 1e18;

        require(value * 100 >= (minted[msg.sender] + stableAmt) * COLLATERAL_RATIO, "Under-collateralized");
        minted[msg.sender] += stableAmt;
        _mint(msg.sender, stableAmt);
    }

    /// @notice Redeem shares for underlying tokens
    function redeem(uint256 stableAmt) external {
        require(minted[msg.sender] >= stableAmt, "Exceeds minted");

        _burn(msg.sender, stableAmt);
        minted[msg.sender] -= stableAmt;
        uint256 price = getUniswapPrice();
        uint256 collateralOut = stableAmt * 1e18 / price;
        deposits[msg.sender] -= collateralOut;

        require(collateral.transfer(msg.sender, collateralOut), "Transfer failed");
    }
}

// BUG
// mint() uses Chainlink price (line 43) while redeem() uses Uniswap spot price (line 53). The attacker can manipulate the
// Uniswap price downward to redeem more collateral than their stablecoins are worth, while minting used the stable Chainlink
// price.

// IMPACT
// By manipulating Uniswap price down, collateralOut = stableAmt * 1e18 / lowPrice becomes very large. The attacker extracts
// excess collateral.

// INVARIANT
// Symmetric operations (mint/redeem) must use the same price source to prevent arbitrage from price discrepancies.

// WHAT BREAKS
// mint() values collateral at the Chainlink price (manipulation-resistant), but redeem() computes collateral return using
// Uniswap slot0 price (flash-loan-manipulable). The attacker mints at fair price and redeems at a manipulated price.

// EXPLOIT PATH
// 1. Chainlink price: 1 ETH = $2,000. Attacker deposits 10 ETH, mints 13,333 dUSD (150% ratio)
// 2. Attacker flash-loans ETH, swaps into Uniswap pool to crash spot price to $1,000
// 3. Attacker calls redeem(13,333). collateralOut = 13,333 * 1e18 / 1000e18 = 13.333 ETH
// 4. Attacker recovers 13.333 ETH (deposited 10). Attacker swaps back, repays flash loan
// 5. Profit: 3.333 ETH ($6,666). Protocol lost 3.333 ETH from other depositors' collateral.

// WHY MISSED
// Each oracle function individually looks well-implemented -- Chainlink has staleness checks, Uniswap reads the correct slot0
// field. The bug is architectural: two separate functions in two separate code paths use different oracles for paired operations.
