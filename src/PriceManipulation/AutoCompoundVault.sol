// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISwapRouter {
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);
}

/// @title AutoCompoundVault
contract AutoCompoundVault is ERC20 {
    IERC20 public immutable baseToken;
    IERC20 public immutable yieldToken;
    ISwapRouter public immutable router;
    address[] public swapPath;

    constructor(address _base, address _yield, address _router, address[] memory _path) ERC20("AutoVault", "aVLT") {
        baseToken = IERC20(_base);
        yieldToken = IERC20(_yield);
        router = ISwapRouter(_router);
        swapPath = _path;
    }

    /// @notice Total assets
    function totalAssets() public view returns (uint256) {
        return baseToken.balanceOf(address(this));
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external returns (uint256 shares) {
        _compound();

        shares = totalSupply() == 0 ? amount : (amount * totalSupply()) / totalAssets();
        require(baseToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        _mint(msg.sender, shares);
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 shares) external returns (uint256 assets) {
        _compound();

        assets = (shares * totalAssets()) / totalSupply();
        _burn(msg.sender, shares);
        require(baseToken.transfer(msg.sender, assets), "Transfer failed");
    }

    function _compound() internal {
        uint256 yieldBal = yieldToken.balanceOf(address(this));

        if (yieldBal == 0) return;
        yieldToken.approve(address(router), yieldBal);
        router.swapExactTokensForTokens(yieldBal, 0, swapPath, address(this), block.timestamp);
    }
}

// BUG
// _compound() swaps yield tokens with minAmountOut = 0 and is called inside deposit() and withdraw(). This internal swap is
// sandwichable, manipulating the share price seen by depositors and withdrawers.

// IMPACT
// Depositors receive fewer shares and withdrawers receive fewer assets because the compound swap executes at a manipulated price,
// reducing the vault's totalAssets().

// INVARIANT
// The share price seen by depositors and withdrawers must not be manipulable by sandwiching internal swaps.

// WHAT BREAKS
// _compound() is called inside deposit() and withdraw() with a 0-slippage swap. An attacker can front-run a user's deposit,
// manipulate the pool so _compound() converts yield at a terrible rate, reducing totalAssets() and inflating the share/asset
// ratio against the user.

// EXPLOIT PATH
// 1. Vault has 1000 baseToken, 100 yieldToken pending. Fair compound would add 200 baseToken
// 2. Alice calls deposit(500). Attacker front-runs: manipulates pool so yield converts to only 20 baseToken
// 3. _compound() runs: totalAssets becomes 1020 instead of 1200
// 4. Alice's shares = 500 * totalSupply / 1020 (lower ratio than expected)
// 5. Attacker back-runs: restores pool. Next compound recovers proper rates. Alice's shares are permanently diluted
// 6. If totalSupply was 1000 shares: Alice gets 490 shares instead of 416 she should have gotten at fair price of 1200. Wait -- attacker extracts ~$90 value from the reduced compound.

// WHY MISSED
// The _compound() function appears to be a benign internal optimization. Auditors may focus on the deposit/withdraw share math
// without tracing into the swap that modifies totalAssets() between the function entry and the share calculation
