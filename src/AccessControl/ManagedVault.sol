// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ManagedVault
contract ManagedVault is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant HARVESTER_ROLE = keccak256("HARVESTER_ROLE");

    IERC20 public asset;
    address public strategy;

    uint256 public totalDeposited;
    mapping(address => uint256) public deposits;

    constructor(address _asset, address _strategy) {
        asset = IERC20(_asset);
        strategy = _strategy;
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(amount > 0, "Zero amount");

        asset.safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] += amount;
        totalDeposited += amount;
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 amount) external {
        require(deposits[msg.sender] >= amount, "Insufficient");

        deposits[msg.sender] -= amount;
        totalDeposited -= amount;
        asset.safeTransfer(msg.sender, amount);
    }

    /// @notice Configure a contract parameter
    function setStrategy(address _newStrategy) external onlyRole(STRATEGIST_ROLE) {
        require(_newStrategy != address(0), "Zero address");
        strategy = _newStrategy;
    }

    /// @notice Harvest and compound rewards
    function harvest() external onlyRole(HARVESTER_ROLE) {
        uint256 surplus = asset.balanceOf(address(this)) - totalDeposited;
        if (surplus > 0) {
            asset.safeTransfer(strategy, surplus);
        }
    }

    /// @notice Get balance
    function getBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

// BUG
// The constructor never calls _grantRole(DEFAULT_ADMIN_ROLE, msg.sender) or grants any roles. No address will ever have
// STRATEGIST_ROLE or HARVESTER_ROLE, and no admin exists to grant them.

// IMPACT
// setStrategy and harvest are permanently uncallable because no address has the required roles. The strategy can never be
// updated and yield can never be harvested, locking surplus funds in the contract forever.

// INVARIANT
// Critical vault management functions must be callable by at least one authorized address after deployment.

// WHAT BREAKS
// The contract inherits AccessControl and defines STRATEGIST_ROLE and HARVESTER_ROLE, but the constructor never grants any
// roles including DEFAULT_ADMIN_ROLE. Since no admin exists, no one can call grantRole to assign the strategist or harvester.
// Both setStrategy and harvest are permanently bricked, trapping all yield surplus in the contract.

// EXPLOIT PATH
// 1. ManagedVault is deployed with asset = USDC and strategy = 0xStrategy
// 2. Users deposit 1,000,000 USDC. totalDeposited = 1,000,000e6
// 3. Strategy generates 50,000 USDC yield. Contract balance = 1,050,000e6
// 4. Operator tries to call harvest(). Reverts: AccessControl: account 0xOp is missing role HARVESTER_ROLE
// 5. Operator tries to call grantRole(HARVESTER_ROLE, 0xOp). Reverts: missing DEFAULT_ADMIN_ROLE
// 6. 50,000 USDC surplus is permanently locked. As more yield accrues, more funds are trapped
// 7. This is a permanent denial-of-service on vault operations.

// WHY MISSED
// The contract imports and inherits AccessControl correctly, and role constants are properly defined with keccak256.
// The onlyRole modifiers are correctly applied. Everything looks right except the missing initialization in the constructor,
// which is easy to overlook because AccessControl does not revert during construction when roles are not set up.
