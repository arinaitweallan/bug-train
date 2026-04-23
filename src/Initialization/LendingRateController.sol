// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LendingRateController
contract LendingRateController {
    using SafeERC20 for IERC20;

    address public admin;
    IERC20 public lendingToken;

    uint256 public interestRateBps;
    uint256 public lastAccrualTimestamp;
    uint256 public totalBorrowed;
    uint256 public accruedProtocolFees;

    mapping(address => uint256) public borrowBalances;

    constructor(address _admin, address _token) {
        admin = _admin;
        lendingToken = IERC20(_token);
        lastAccrualTimestamp = block.timestamp;
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        accrueInterest();
        require(lendingToken.balanceOf(address(this)) >= amount, "Low liquidity");

        borrowBalances[msg.sender] += amount;
        totalBorrowed += amount;
        lendingToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Repay borrowed tokens
    function repay(uint256 amount) external {
        accrueInterest();
        require(borrowBalances[msg.sender] >= amount, "Over repay");

        lendingToken.safeTransferFrom(msg.sender, address(this), amount);
        borrowBalances[msg.sender] -= amount;
        totalBorrowed -= amount;
    }

    /// @notice Accrue interest
    function accrueInterest() public {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;

        uint256 interest = (totalBorrowed * interestRateBps * elapsed) / (365 days * 10000);
        accruedProtocolFees += interest;
        totalBorrowed += interest;
        lastAccrualTimestamp = block.timestamp;
    }

    /// @notice Configure a contract parameter
    function setInterestRate(uint256 _rateBps) external {
        require(msg.sender == admin, "Not admin");
        interestRateBps = _rateBps;
    }

    /// @notice Get accrued fees
    function getAccruedFees() external view returns (uint256) {
        return accruedProtocolFees;
    }
}

// BUG
// interestRateBps is never set in the constructor or at deployment. It defaults to 0 in Solidity, meaning all interest
// calculations produce zero fees.

// IMPACT
// In accrueInterest, interest = (totalBorrowed * 0 * elapsed) / (365 days * 10000) = 0. The protocol collects zero fees on
// all borrows until an admin manually calls setInterestRate, and all borrows made before that call were interest-free.

// INVARIANT
// The interest rate must be set to a valid non-zero value at deployment so that all borrows accrue protocol fees.

// WHAT BREAKS
// interestRateBps defaults to 0 because it is never initialized. All borrows accrue zero interest. The protocol operates as a
// free lending service until the admin notices and calls setInterestRate, but previously issued borrows already accrued nothing.

// EXPLOIT PATH
// 1. LendingRateController is deployed with admin and USDC token. interestRateBps = 0 (default)
// 2. Pool is funded with 1,000,000 USDC
// 3. Borrower calls borrow(500000e6). accrueInterest computes interest = 500000e6 * 0 * elapsed / ... = 0
// 4. 30 days pass. Borrower calls repay(500000e6). accrueInterest still computes 0 interest
// 5. Protocol earned 0 USDC in fees on a 500,000 USDC loan for 30 days
// 6. At 5% APR (500 bps), the expected fee was ~2,054 USDC, entirely lost.

// WHY MISSED
// Auditors focus on the correctness of the interest formula and the admin setter but assume the deployment script handles the
// initial value. The constructor sets admin and token but silently omits interestRateBps, which defaults to zero.
