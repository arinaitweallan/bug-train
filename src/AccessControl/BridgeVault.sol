// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BridgeVault
contract BridgeVault {
    using SafeERC20 for IERC20;

    address public admin;
    address public relayer;
    IERC20 public bridgeToken;

    mapping(bytes32 => bool) public processedMessages;
    bool private _initialized;

    /// @notice Initialize contract state
    /// @param _admin Admin value
    /// @param _relayer Relayer address
    /// @param _token Token contract address
    function initialize(address _admin, address _relayer, address _token) external {
        require(!_initialized, "Already initialized");

        _initialized = true;
        admin = _admin;
        relayer = _relayer;
        bridgeToken = IERC20(_token);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier onlyRelayer() {
        require(msg.sender == relayer, "Not relayer");
        _;
    }

    /// @notice Release locked or vested tokens
    /// @param recipient Recipient address
    /// @param amount Token amount
    /// @param msgHash Msg hash value
    function releaseFunds(address recipient, uint256 amount, bytes32 msgHash) external onlyRelayer {
        require(!processedMessages[msgHash], "Already processed");

        processedMessages[msgHash] = true;
        bridgeToken.safeTransfer(recipient, amount);
    }

    /// @notice Configure a contract parameter
    function setRelayer(address _newRelayer) external onlyAdmin {
        require(_newRelayer != address(0), "Zero address");

        relayer = _newRelayer;
    }

    /// @notice Execute emergency action
    /// @param token Token contract address
    /// @param amount Token amount
    function emergencyWithdraw(address token, uint256 amount) external onlyAdmin {
        IERC20(token).safeTransfer(admin, amount);
    }

    /// @notice Get balance
    function getBalance() external view returns (uint256) {
        return bridgeToken.balanceOf(address(this));
    }
}

// INVARIANT
// Only the authorized deployer should be able to initialize the contract and set admin/relayer roles.

// WHAT BREAKS
// The initialize function uses a simple boolean guard that only prevents re-initialization but not unauthorized first
// initialization. An attacker who monitors the mempool can front-run the initialization, setting themselves as admin and
// relayer to steal all bridged funds.

// EXPLOIT PATH
// 1. Protocol deploys BridgeVault implementation contract
// 2. Protocol broadcasts a transaction calling initialize(protocolAdmin, protocolRelayer, USDC)
// 3. Attacker sees the pending tx, sends initialize(attackerAddr, attackerAddr, USDC) with higher gas
// 4. Attacker's tx mines first: admin = attacker, relayer = attacker
// 5. Protocol's initialize call reverts with 'Already initialized'
// 6. Users bridge 200,000 USDC into the vault
// 7. Attacker calls emergencyWithdraw(USDC, 200000e6) and drains all funds.

// WHY MISSED
// The _initialized boolean flag creates an illusion of safety. Auditors see the re-initialization protection and mentally
// check off 'initialization handled' without considering the first-init race condition that exists before any deployer check.
