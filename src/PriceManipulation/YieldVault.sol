// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title YieldVault
contract YieldVault is ERC20 {
    IERC20 public immutable asset;

    address public strategy;
    uint256 public depositCap;

    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);
    event Harvested(uint256 yield);

    constructor(address _asset, uint256 _cap) ERC20("Yield Vault", "yVLT") {
        asset = IERC20(_asset);
        strategy = msg.sender;
        depositCap = _cap;
    }

    /// @notice Total assets
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Preview deposit
    function previewDeposit(uint256 assets) public view returns (uint256) {
        if (totalSupply() == 0) return assets;
        return (assets * totalSupply()) / totalAssets();
    }

    /// @notice Deposit tokens into the contract
    /// @param assets Amount of underlying assets
    /// @param receiver Receiver address
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets > 0, "Zero deposit");
        require(totalAssets() + assets <= depositCap, "Cap exceeded");

        shares = totalSupply() == 0 ? assets : (assets * totalSupply()) / totalAssets();

        require(shares > 0, "Zero shares");
        require(asset.transferFrom(msg.sender, address(this), assets), "Transfer failed");

        _mint(receiver, shares);
        emit Deposited(receiver, assets, shares);
    }

    /// @notice Withdraw tokens from the contract
    /// @param shares Amount of vault shares
    /// @param receiver Receiver address
    function withdraw(uint256 shares, address receiver) external returns (uint256 assets) {
        require(shares > 0, "Zero shares");
        require(balanceOf(msg.sender) >= shares, "Insufficient shares");
        assets = (shares * totalAssets()) / totalSupply();
        _burn(msg.sender, shares);
        require(asset.transfer(receiver, assets), "Transfer failed");
        emit Withdrawn(receiver, assets, shares);
    }

    /// @notice Harvest and compound rewards
    function harvest(uint256 yield) external {
        require(msg.sender == strategy, "Not strategy");
        require(asset.transferFrom(msg.sender, address(this), yield), "Transfer failed");
        emit Harvested(yield);
    }

    /// @notice Configure a contract parameter
    function setDepositCap(uint256 _cap) external {
        require(msg.sender == strategy, "Not strategy");
        depositCap = _cap;
    }

    /// @notice Configure a contract parameter
    function setStrategy(address _strategy) external {
        require(msg.sender == strategy, "Not strategy");
        strategy = _strategy;
    }
}

// BUG
// When totalSupply is 0, the first depositor gets shares 1:1 with assets. There is no virtual offset or minimum deposit. The
// attacker can deposit 1 wei, then donate a large amount directly to the vault, inflating the share price so that subsequent
// depositors receive 0 shares due to rounding.

// IMPACT
// Subsequent depositors' assets / totalAssets() * totalSupply() rounds to 0. Their deposit is captured by the attacker's single
// share. The require(shares > 0) does not help because the rounding happens before the check for realistic deposit amounts.

// INVARIANT
// No depositor should lose assets due to share price inflation caused by a prior deposit plus donation sequence.

// WHAT BREAKS
// The share calculation at line 22-23 divides by totalAssets() which includes donated tokens. With 1 share outstanding and 1e18
// + 1 total assets, a deposit of 999e15 yields (999e15 * 1) / (1e18 + 1) = 0 shares.

// EXPLOIT PATH
// 1. Attacker deposits 1 wei of asset, receiving 1 share (totalSupply = 1, totalAssets = 1)
// 2. Attacker donates 1e18 tokens directly via asset.transfer(vault). totalAssets = 1e18 + 1, totalSupply = 1
// 3. Victim deposits 500e15 (0.5 tokens). shares = 500e15 * 1 / (1e18 + 1) = 0
// 4. Victim's tx reverts due to require(shares > 0). If victim deposits 1.5e18, shares = 1.5e18 / (1e18+1) = 1 share
// 5. Attacker withdraws 1 share: assets = 1 * (2.5e18 + 1) / 2 = 1.25e18. Attacker profits ~0.25e18 from victim's deposit.

// WHY MISSED
// The require(shares > 0) check creates a false sense of safety. Auditors may think it prevents the attack, but it only causes
// a revert for small depositors while larger depositors still lose funds to rounding.
