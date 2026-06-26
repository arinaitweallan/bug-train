// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPriceOracle {
    /// @notice Returns the current price used by the contract.
    function getPrice() external view returns (uint256); // price in 1e18
}

/// @title OracleVault - Vault using oracle for NAV calculation
/// @notice On-chain price consumer that reads an external oracle to produce asset valuations.
contract OracleVault is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    IPriceOracle public immutable oracle;
    // If the oracle price can move within a single block, what happens to the share-to-asset
    // ratio between deposit and redeem?

    // Count the oracle reads across deposit and redeem. Is any of them TWAP-smoothed or rate-bounded?

    uint256 public totalUnits; // units of the underlying strategy position

    constructor(address _asset, address _oracle) ERC20("Oracle Vault", "ovToken") {
        asset = IERC20(_asset);
        oracle = IPriceOracle(_oracle);
    }

    /// @notice Total assets
    function totalAssets() public view returns (uint256) {
        return (totalUnits * oracle.getPrice()) / 1e18;
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 assets) external returns (uint256 shares) {
        uint256 supply = totalSupply();
        shares = supply == 0 ? assets : (assets * supply) / totalAssets();
        require(shares > 0, "zero");

        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 units = (assets * 1e18) / oracle.getPrice();
        totalUnits += units;
        _mint(msg.sender, shares);
    }

    /// @notice Redeem shares for underlying tokens
    function redeem(uint256 shares) external returns (uint256 assets) {
        assets = (shares * totalAssets()) / totalSupply();
        uint256 units = (assets * 1e18) / oracle.getPrice();
        totalUnits -= units;
        _burn(msg.sender, shares);
        asset.safeTransfer(msg.sender, assets);
    }

    /// @notice Preview deposit
    function previewDeposit(uint256 assets) external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        return (assets * supply) / totalAssets();
    }
}

// BUG
// totalAssets is computed from a live oracle spot price with no staleness, TWAP, or manipulation-resistance check.

// IMPACT
// deposit divides by an oracle-derived totalAssets; a flash-loan manipulation of the oracle lets an attacker mint shares
// at a discount and redeem at the recovered price.

// INVARIANT
// Share price must not be determined by a single spot price read from a manipulable oracle within a single transaction; NAV
// computations must use TWAP, staleness checks, or a commit-reveal pattern.

// WHAT BREAKS
// totalAssets() at line 27 is computed from totalUnits * oracle.getPrice(). The oracle is read twice in deposit()
// (once transitively via line 33's totalAssets(), once directly at line 36 for the units conversion), and both reads see the
// SAME manipulated price within a single flash-loan tx. This lets an attacker deposit at a discounted rate (low price -> more
// shares per asset) and redeem at a recovered rate (high price -> more assets per share). The vault has no staleness check,
// no TWAP, and no circuit breaker. Additional issues: redeem at line 42 reads oracle twice as well (line 43 and 44), with the
// same single-block consistency but also the same manipulation surface; no bounds on oracle return values; no pause/circuit-
// breaker on large NAV moves.

// EXPLOIT PATH
// 1. Initial state: totalUnits=1_000, oraclePrice=1e18, totalSupply=1_000. Line 27 totalAssets = 1_000 * 1e18 / 1e18 = 1_000
// 2. Attacker manipulates the oracle price DOWN to 0.5e18 (via flash-loan liquidity extraction from whatever source feeds the oracle). Line 27 totalAssets = 1_000 * 0.5e18 / 1e18 = 500
// 3. Attacker calls deposit(500). Line 33 reads supply=1_000, totalAssets=500. shares = (500 * 1_000) / 500 = 1_000. Line 36 reads oracle.getPrice() again (same manipulated 0.5e18) and computes units = 500 * 1e18 / 0.5e18 = 1_000. Line 37 totalUnits += 1_000 -> 2_000. totalSupply=2_000
// 4. Attacker releases the oracle manipulation. Oracle returns to 1e18. Line 27 totalAssets = 2_000 * 1e18 / 1e18 = 2_000
// 5. Attacker calls redeem(1_000). Line 43 assets = (1_000 * 2_000) / 2_000 = 1_000. Attacker spent 500 and received 1_000 - profit 500 (not 250 as the original md claimed; the totalUnits math at line 37 adds 1_000 units, not 500)
// 6. Existing holder's 1_000 shares are now worth 1_000 out of 2_000 total assets = same nominal amount as before, but the attacker captured 500 of unearned yield from thin air.

// WHY MISSED
// Oracle manipulation is a well-documented vulnerability, but reviewers often tick it as 'out of scope, trust oracle' rather
// than reasoning about the specific oracle source. The real exploit depends on the oracle's liquidity and manipulation cost.
// The earlier description also got the magnitudes wrong (claiming 250 profit instead of 500, using totalUnits=1_500 instead
// of 2_000), which distracted from the correct classification as an oracle-dependency bug rather than a vault-share-accounting
// bug.
