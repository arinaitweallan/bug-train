// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BridgeTokenRegistry
contract BridgeTokenRegistry {
    using SafeERC20 for IERC20;

    address public guardian;
    address public relayer;

    mapping(uint256 => address) public remoteTokens;
    mapping(address => uint256) public lockedBalances;

    bool public initialized;

    /// @notice Initialize contract state
    /// @param _guardian Guardian address
    /// @param _relayer Relayer address
    function initialize(address _guardian, address _relayer) external {
        require(!initialized, "Already initialized");

        initialized = true;
        guardian = _guardian;
        relayer = _relayer;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "Not guardian");
        _;
    }

    modifier onlyRelayer() {
        require(msg.sender == relayer, "Not relayer");
        _;
    }

    /// @notice Register a new entry
    /// @param chainId Chain id value
    /// @param token Token contract address
    function registerRemoteToken(uint256 chainId, address token) external onlyGuardian {
        remoteTokens[chainId] = token;
    }

    /// @notice Lock tokens for a duration
    /// @param token Token contract address
    /// @param amount Token amount
    function lockTokens(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        lockedBalances[token] += amount;
    }

    /// @notice Release locked or vested tokens
    /// @param token Token contract address
    /// @param to Recipient address
    /// @param amount Token amount
    function releaseBridgedTokens(address token, address to, uint256 amount) external onlyRelayer {
        require(lockedBalances[token] >= amount, "Insufficient locked");
        
        lockedBalances[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Get locked balance
    function getLockedBalance(address token) external view returns (uint256) {
        return lockedBalances[token];
    }
}

// INVARIANT
// Only the legitimate deployer can initialize the bridge registry and set the guardian and relayer roles.

// WHAT BREAKS
// An attacker front-runs the deployer's initialize transaction, becoming both guardian and relayer. They can then drain all 
// locked bridge tokens and register malicious remote token mappings to steal cross-chain transfers.

// EXPLOIT PATH
// 1. BridgeTokenRegistry is deployed at address 0xBridge
// 2. Users lock 500,000 USDC via lockTokens before initialization completes
// 3. Attacker monitors the mempool, sees the deployer's initialize(deployer, trustedRelayer) transaction
// 4. Attacker front-runs with initialize(attackerAddr, attackerAddr) with higher gas price
// 5. Attacker calls releaseBridgedTokens(USDC, attackerAddr, 500000e6) as the relayer
// 6. 500,000 USDC is drained to the attacker.

// WHY MISSED
// The initialized boolean flag creates a false sense of security. Auditors see the re-initialization protection and assume 
// initialization is safe, overlooking that anyone can be the first caller.
