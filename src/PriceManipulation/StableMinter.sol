// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Collateralized Stablecoin

// q getCollateralPrice() reads reserves from a pool. Can these reserves change
// within the same transaction that calls depositAndMint()?

interface IPool {
    function getReserves() external view returns (uint256 reserveA, uint256 reserveB);
}

interface IFlashLender {
    function flashLoan(address, address, uint256, bytes calldata) external;
}

/// @title StableMinter
contract StableMinter is ERC20 {
    IERC20 public immutable collateral;
    IPool public immutable pricePool;

    uint256 public constant COLLATERAL_RATIO = 150;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public minted;

    constructor(address _collateral, address _pool) ERC20("StableUSD", "sUSD") {
        collateral = IERC20(_collateral);
        pricePool = IPool(_pool);
    }

    /// @notice Get collateral price
    function getCollateralPrice() public view returns (uint256) {
        // rA = 1000 rB = 1000
        // 1000 * 1e18 / 1000 = 1e18
        (uint256 rA, uint256 rB) = pricePool.getReserves();
        return (rB * 1e18) / rA;
    }

    /// @notice Deposit tokens into the contract
    /// @param collateralAmt Collateral amt value
    /// @param mintAmt Mint amt value
    function depositAndMint(uint256 collateralAmt, uint256 mintAmt) external {
        require(collateral.transferFrom(msg.sender, address(this), collateralAmt), "Transfer failed");

        // 1000
        deposits[msg.sender] += collateralAmt;
        // 1e18
        uint256 price = getCollateralPrice();
        // 1000 * 1e18 / 1e18 = 1000
        uint256 collateralValue = (deposits[msg.sender] * price) / 1e18;
        // 1000 * 100 >= (0 + 500) * 150
        // 100_000 >= 75_000
        require(collateralValue * 100 >= (minted[msg.sender] + mintAmt) * COLLATERAL_RATIO, "Undercollateralized");

        minted[msg.sender] += mintAmt;
        _mint(msg.sender, mintAmt);
    }

    /// @notice Redeem shares for underlying tokens
    function redeem(uint256 stableAmt) external {
        require(minted[msg.sender] >= stableAmt, "Exceeds minted");

        _burn(msg.sender, stableAmt);
        minted[msg.sender] -= stableAmt;

        uint256 price = getCollateralPrice();
        // 500 * 1e18 / 1e18
        uint256 collateralReturn = (stableAmt * 1e18) / price;
        deposits[msg.sender] -= collateralReturn;

        require(collateral.transfer(msg.sender, collateralReturn), "Transfer failed");
    }

    // In the redeem function, the maths for calculating the return collateral when a user is trying to repay debt
    // is flawed in a way that it does not return all the collateral in the contract but burns all the stablecoin
    // minted. In the redeem function, the first require prevents a user from redeeming collateral for stablecoins
    // more than their minted balance

    // This means the user's collateral will be stuck in the collateral without a way of recovering it
}

// INVARIANT
// The price oracle used for collateral valuation must not be manipulable within a single atomic transaction.

// WHAT BREAKS
// getCollateralPrice() reads AMM reserves that change with every swap. An attacker can flash-loan collateral tokens,
// swap them into the pool to inflate the price, mint stablecoins at the inflated valuation, then swap back and repay
// the flash loan.

// EXPLOIT PATH
// 1. Pool reserves: 1M collateral, 1M stableRef. Price = 1:1
// 2. Attacker flash-loans 9M stableRef, swaps into pool. New reserves: 1M collateral, 10M stableRef. Price = 10:1
// 3. Attacker deposits 100 collateral. collateralValue = 100 * 10 = 1000. Mints 666 sUSD (at 150% ratio)
// 4. Attacker swaps back in pool, repays flash loan. Actual collateral value: $100
// 5. Protocol holds 100 collateral ($100) backing 666 sUSD. Bad debt: $566.

// WHY MISSED
// The contract has a proper COLLATERAL_RATIO check and clean separation of concerns. The AMM pool is treated as a
// reliable price source because it is a real on-chain contract. The atomicity of flash loans enabling same-transaction
// manipulation is the subtle issue.
