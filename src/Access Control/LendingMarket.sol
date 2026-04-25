// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LendingMarket
contract LendingMarket {
    using SafeERC20 for IERC20;

    IERC20 public collateralToken;
    IERC20 public debtToken;
    address public admin;

    bool public paused;

    mapping(address => uint256) public collateralBalances;
    mapping(address => uint256) public debtBalances;

    uint256 public totalCollateral;
    uint256 public totalDebt;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    constructor(address _collateral, address _debt) {
        admin = msg.sender;
        collateralToken = IERC20(_collateral);
        debtToken = IERC20(_debt);
    }

    function depositCollateral(uint256 amount) external whenNotPaused {
        require(amount > 0, "Zero amount");

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        collateralBalances[msg.sender] += amount;
        totalCollateral += amount;
    }

    function borrow(uint256 amount) external whenNotPaused {
        require(collateralBalances[msg.sender] * 75 / 100 >= debtBalances[msg.sender] + amount, "Undercollateralized");

        debtBalances[msg.sender] += amount;
        totalDebt += amount;
        debtToken.safeTransfer(msg.sender, amount);
    }

    function liquidate(address borrower, uint256 repayAmount) external {
        require(collateralBalances[borrower] * 75 / 100 < debtBalances[borrower], "Not liquidatable");
        require(repayAmount <= debtBalances[borrower], "Over repay");

        debtToken.safeTransferFrom(msg.sender, address(this), repayAmount);
        debtBalances[borrower] -= repayAmount;
        totalDebt -= repayAmount;
        uint256 collateralReward = (repayAmount * 110) / 100;
        if (collateralReward > collateralBalances[borrower]) {
            collateralReward = collateralBalances[borrower];
        }
        collateralBalances[borrower] -= collateralReward;
        totalCollateral -= collateralReward;
        collateralToken.safeTransfer(msg.sender, collateralReward);
    }

    function pause() external onlyAdmin {
        paused = true;
    }

    function unpause() external onlyAdmin {
        paused = false;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        if (debtBalances[user] == 0) return type(uint256).max;
        return (collateralBalances[user] * 75) / debtBalances[user];
    }
}

// IMPACT
// When the protocol is paused (e.g., during an oracle malfunction or exploit), liquidators can still liquidate positions using
// stale or manipulated prices. Borrowers cannot deposit additional collateral to save their positions because depositCollateral
// is paused, making them defenseless against liquidation.

// BUG
// The liquidate function is missing the whenNotPaused modifier. During an emergency pause, liquidations can still execute
// while deposits and borrows are frozen.

// INVARIANT
// During emergency pause, all state-changing user operations including liquidation must be halted to prevent exploitation of
// frozen market conditions.

// WHAT BREAKS
// The pause mechanism protects depositCollateral and borrow but not liquidate. During a pause triggered by an oracle failure
// or market crash, borrowers cannot deposit more collateral (paused), but liquidators can still liquidate their positions.
// This creates an asymmetric situation where borrowers are defenseless against liquidation during the exact conditions when
// the protocol should be protecting them.

// EXPLOIT PATH
// 1. Borrower has 100,000 USDC collateral, 70,000 DAI debt (health factor = 100000*75/70000 = 107%)
// 2. Oracle malfunctions, showing inflated debt value. Admin calls pause()
// 3. Borrower tries depositCollateral(50000e6) to increase health factor. Reverts: 'Contract paused'
// 4. Liquidator calls liquidate(borrower, 70000e18). Function has no whenNotPaused check. Proceeds
// 5. Liquidator repays 70,000 DAI and receives 77,000 USDC collateral (110% reward)
// 6. Borrower loses 77,000 USDC collateral during an emergency pause while unable to defend their position.

// WHY MISSED
// Auditors checking pause coverage often verify that deposits and withdrawals respect the pause flag and check the box.
// Liquidation functions are often intentionally left unpaused in some protocols (to maintain solvency), so the auditor
// may assume this is by design without analyzing the asymmetric impact on borrowers.
