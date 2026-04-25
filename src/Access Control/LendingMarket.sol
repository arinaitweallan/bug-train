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
