// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LendingPool
contract LendingPool {
    using SafeERC20 for IERC20;

    IERC20 public lendingToken;

    mapping(address => uint256) public balances;
    mapping(address => uint256) public borrowAmounts;

    uint256 public totalLiquidity;

    constructor(address _token) {
        lendingToken = IERC20(_token);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(amount > 0, "Zero amount");

        lendingToken.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        totalLiquidity += amount;
    }

    /// @notice Withdraw tokens from the contract
    /// @param owner Token owner address
    /// @param amount Token amount
    function withdraw(address owner, uint256 amount) external {
        require(balances[owner] >= amount, "Insufficient balance");
        require(balances[owner] - amount >= borrowAmounts[owner], "Collateral locked");

        balances[owner] -= amount;
        totalLiquidity -= amount;
        lendingToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Borrow tokens against collateral
    function borrow(uint256 amount) external {
        require(balances[msg.sender] >= borrowAmounts[msg.sender] + amount, "Undercollateralized");

        borrowAmounts[msg.sender] += amount;
        totalLiquidity -= amount;
        lendingToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Repay borrowed tokens
    function repay(uint256 amount) external {
        require(borrowAmounts[msg.sender] >= amount, "Over repay");

        lendingToken.safeTransferFrom(msg.sender, address(this), amount);
        borrowAmounts[msg.sender] -= amount;
        totalLiquidity += amount;
    }

    /// @notice Get available liquidity
    function getAvailableLiquidity() external view returns (uint256) {
        return totalLiquidity;
    }
}

// IMPACT
// The function debits balances[owner] (the victim's balance) but transfers tokens to msg.sender (the attacker), allowing anyone
// to drain any user's deposited funds.

// BUG
// The withdraw function accepts an arbitrary owner address parameter but never checks that msg.sender == owner or that
// msg.sender is approved by the owner.

// INVARIANT
// Only a depositor (or their approved delegate) can withdraw their own deposited funds.

// WHAT BREAKS
// The withdraw function takes an arbitrary owner address and deducts from that user's balance, but transfers the tokens to
// msg.sender. An attacker passes any victim's address as owner and receives their funds directly.

// EXPLOIT PATH
// 1. Alice deposits 50,000 USDC into the LendingPool. balances[Alice] = 50,000
// 2. Attacker calls withdraw(Alice, 50000e6). The function checks balances[Alice] >= 50000e6 which passes
// 3. balances[Alice] is reduced to 0
// 4. lendingToken.safeTransfer(msg.sender, 50000e6) sends 50,000 USDC to the attacker
// 5. Alice's entire deposit is stolen.

// WHY MISSED
// The function signature looks like a standard withdrawal with an owner parameter for flexibility. Auditors may assume the
// owner parameter is used for on-behalf-of functionality with approval checks elsewhere, but no approval mechanism exists.
