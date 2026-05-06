// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// USDC Blacklist Bricks Loan Repayment

/// @title LendingPool
contract LendingPool {
    struct Loan {
        address borrower;
        address lender;
        uint256 amount;
        uint256 interest;
        uint256 dueDate;
        bool repaid;
    }

    IERC20 public usdc;

    mapping(uint256 => Loan) public loans;

    uint256 public nextLoanId;

    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }

    /// @notice Create a new loan
    /// @param borrower Borrower address
    /// @param amount Loan amount
    /// @param interest Interest amount
    /// @param duration Time duration in seconds
    function createLoan(address borrower, uint256 amount, uint256 interest, uint256 duration) external {
        require(usdc.transferFrom(msg.sender, borrower, amount), "Transfer failed");

        loans[nextLoanId] = Loan(borrower, msg.sender, amount, interest, block.timestamp + duration, false);
        nextLoanId++;
    }

    /// @notice Repay borrowed tokens
    function repayLoan(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(!loan.repaid, "Already repaid");
        require(msg.sender == loan.borrower, "Not borrower");

        uint256 totalDue = loan.amount + loan.interest;
        require(usdc.transferFrom(msg.sender, loan.lender, totalDue), "Transfer failed");
        loan.repaid = true;
    }

    /// @notice Liquidate an overdue loan (liquidator repays debt to lender, seizes collateral rights)
    function liquidate(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(!loan.repaid, "Already repaid");
        require(block.timestamp > loan.dueDate, "Not yet due");
        uint256 penalty = loan.amount + loan.interest + (loan.amount / 10);
        require(usdc.transferFrom(msg.sender, loan.lender, penalty), "Transfer failed");
        loan.repaid = true;
    }

    /// @notice Get loan
    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }
}

// INVARIANT
// Borrowers must always be able to repay their loans regardless of the lender's external status

// WHAT BREAKS
// If the lender's address is blacklisted by USDC (Circle), the transferFrom at line 35 permanently reverts. The borrower cannot
// repay the loan through any code path. After dueDate passes, liquidate() also fails at line 44 for the same reason. The
// borrower is stuck with an un-repayable loan that accrues penalties forever.

// EXPLOIT PATH
// 1. Lender creates a loan: createLoan(borrower, 100_000e6, 5_000e6, 30 days)
// 2. Lender's address gets USDC-blacklisted by Circle (e.g., OFAC sanction)
// 3. Borrower calls repayLoan(0)
// 4. usdc.transferFrom(borrower, lender, 105_000e6) at line 35 reverts because USDC blacklists the lender as recipient
// 5. Borrower has no alternative repayment path
// 6. After 30 days, liquidate() also reverts at line 44 with the same blacklist error
// 7. Loan is permanently un-closable; borrower's collateral (if any external integration exists) is at risk.

// WHY MISSED
// Auditors often focus on whether the borrower can be blacklisted but overlook that the lender being blacklisted is equally
// devastating since repayment and liquidation both push tokens to the lender address.
