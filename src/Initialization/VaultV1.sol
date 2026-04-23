// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title VaultV1
contract VaultV1 is Initializable {
    address public owner;
    address public asset;

    uint256 public totalDeposited;

    mapping(address => uint256) public balances;
    uint256[47] private __gap;

    /// @notice Initialize contract state
    /// @param _owner Token owner address
    /// @param _asset Asset value
    function initialize(address _owner, address _asset) external initializer {
        owner = _owner;
        asset = _asset;
    }
}

contract VaultV2 is Initializable {
    address public owner;
    address public feeRecipient;
    address public asset;

    uint256 public feePercent;
    uint256 public totalDeposited;

    mapping(address => uint256) public balances;
    uint256[44] private __gap;

    /// @notice Initialize contract state
    /// @param _owner Token owner address
    /// @param _asset Asset value
    function initialize(address _owner, address _asset) external initializer {
        owner = _owner;
        asset = _asset;
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        uint256 fee = (amount * feePercent) / 10000;
        balances[msg.sender] += amount - fee;
        totalDeposited += amount - fee;
    }

    /// @notice Withdraw tokens from the contract
    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient");

        balances[msg.sender] -= amount;
        totalDeposited -= amount;
    }

    /// @notice Configure a contract parameter
    function setFeeRecipient(address _recipient) external {
        require(msg.sender == owner, "Not owner");
        feeRecipient = _recipient;
    }

    /// @notice Configure a contract parameter
    function setFeePercent(uint256 _fee) external {
        require(msg.sender == owner, "Not owner");
        require(_fee <= 1000, "Fee too high");
        feePercent = _fee;
    }

    /// @notice Get balance
    function getBalance(address user) external view returns (uint256) {
        return balances[user];
    }
}

// BUG
// VaultV2 inserts feeRecipient at slot 1 and feePercent at slot 3, pushing asset to slot 2 and totalDeposited to slot 4. 
// In VaultV1, asset was slot 1, totalDeposited was slot 2, and balances mapping was slot 3. After upgrade, the V1 asset 
// address is read as feeRecipient, totalDeposited becomes asset, and the balances mapping is shifted.

// IMPACT
// After upgrade, asset points to the old totalDeposited value (a uint256 interpreted as an address), totalDeposited reads 
// from the old balances mapping slot, and all user balances are corrupted. Deposits and withdrawals operate on wrong data.

// INVARIANT
// Upgradeable contract storage layouts must be append-only; new variables must be placed after all existing variables to 
// preserve slot assignments.

// WHAT BREAKS
// VaultV2 inserts feeRecipient and feePercent before asset, shifting the storage layout. After upgrading the proxy, slot 1 
// (which held the asset address) is now read as feeRecipient. slot 2 (totalDeposited) becomes asset. All user balances are
// corrupted because the mapping's base slot shifted.

// EXPLOIT PATH
// 1. VaultV1 deployed behind proxy. Users deposit 500,000 USDC. asset = USDC at slot 1, totalDeposited = 500000e6 at slot 2
// 2. Admin upgrades proxy to VaultV2 implementation
// 3. VaultV2 reads slot 1 as feeRecipient = USDC address (0x...A0b86991...). Reads slot 2 as asset = 500000e6 cast to address
// 4. deposit() tries to interact with the corrupted asset address (500000e6 as an address), which reverts
// 5. withdraw() is also broken: balances mapping shifted slots, all users read 0
// 6. 500,000 USDC is permanently locked in the proxy with no functional access.

// WHY MISSED
// The __gap arrays suggest the developer was aware of storage layout concerns. Auditors see the gap and assume the layout 
// is preserved. They do not diff the actual slot assignments between V1 and V2 to notice the mid-layout insertion.
