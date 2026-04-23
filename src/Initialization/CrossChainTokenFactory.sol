// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CrossChainTokenFactory
contract CrossChainTokenFactory {
    address public bridgeToken;
    address public admin;

    mapping(bytes32 => address) public deployedTokens;

    constructor(address _bridgeToken) {
        bridgeToken = _bridgeToken;
        admin = msg.sender;
    }

    /// @notice Compute token address
    /// @param srcChainId Src chain id value
    /// @param srcToken Src token value
    function computeTokenAddress(uint256 srcChainId, address srcToken) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(srcChainId, srcToken));
        return Clones.predictDeterministicAddress(bridgeToken, salt);
    }

    /// @notice Deploy bridged token
    /// @param srcChainId Src chain id value
    /// @param srcToken Src token value
    /// @param name Name value
    /// @param symbol Symbol value
    function deployBridgedToken(uint256 srcChainId, address srcToken, string calldata name, string calldata symbol)
        external
        returns (address token)
    {
        bytes32 salt = keccak256(abi.encodePacked(srcChainId, srcToken));
        require(deployedTokens[salt] == address(0), "Already deployed");

        token = Clones.cloneDeterministic(bridgeToken, salt);
        deployedTokens[salt] = token;
        BridgedToken(token).initialize(name, symbol, address(this));
    }

    /// @notice Mint new tokens or shares
    /// @param srcChainId Src chain id value
    /// @param srcToken Src token value
    /// @param to Recipient address
    /// @param amount Token amount
    function mintBridged(uint256 srcChainId, address srcToken, address to, uint256 amount) external {
        require(msg.sender == admin, "Not admin");

        bytes32 salt = keccak256(abi.encodePacked(srcChainId, srcToken));
        address token = deployedTokens[salt];
        require(token != address(0), "Not deployed");

        BridgedToken(token).mint(to, amount);
    }

    /// @notice Get deployed token
    /// @param srcChainId Src chain id value
    /// @param srcToken Src token value
    function getDeployedToken(uint256 srcChainId, address srcToken) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(srcChainId, srcToken));
        return deployedTokens[salt];
    }
}

contract BridgedToken {
    string public name;
    string public symbol;

    address public minter;

    bool public initialized;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    /// @notice Initialize contract state
    /// @param _name Name value
    /// @param _symbol Symbol value
    /// @param _minter Minter value
    function initialize(string calldata _name, string calldata _symbol, address _minter) external {
        require(!initialized, "Already init");

        initialized = true;
        name = _name;
        symbol = _symbol;
        minter = _minter;
    }

    /// @notice Mint new tokens or shares
    /// @param to Recipient address
    /// @param amount Token amount
    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "Not minter");

        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /// @notice Transfer tokens to recipient
    /// @param to Recipient address
    /// @param amount Token amount
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// BUG
// The salt is computed from srcChainId and srcToken only, without including the factory address or deployer. The deterministic
// address is predictable, and on chains where the factory is deployed at different addresses, an attacker on chain B can deploy
// a malicious token at the address that chain A's factory would use.

// IMPACT
// An attacker deploys their own factory on a target chain, computes the same salt, deploys a clone at the predicted address,
// and initializes it with themselves as minter. When the real bridge tries to mint tokens, it fails or the attacker has already
// minted fake tokens to steal bridged funds.

// INVARIANT
// Deterministic addresses for bridged tokens must include chain-specific and deployer-specific entropy to prevent cross-chain
// address collisions.

// WHAT BREAKS
// The salt uses only srcChainId and srcToken, making the address predictable. An attacker deploys the same factory bytecode on
// the target chain (via CREATE2 with the same deployer), computes the same salt, deploys the clone first, and initializes it
// with themselves as minter. When the legitimate bridge directs users to that address, the attacker can mint fake tokens or
// block the real initialization.

// EXPLOIT PATH
// 1. CrossChainTokenFactory on Ethereum at 0xFactory. computeTokenAddress(56, BUSD) = 0xPredicted
// 2. Attacker deploys identical factory bytecode on BSC at the same address 0xFactory (using CREATE2 from the same deployer)
// 3. Attacker calls deployBridgedToken(56, BUSD, 'Fake BUSD', 'fBUSD') on BSC factory. Clone deployed at 0xPredicted
// 4. BridgedToken at 0xPredicted is initialized with attacker as minter
// 5. Attacker calls mint(attackerAddr, 10000000e18) creating 10M fake tokens at 0xPredicted
// 6. Users on BSC trust 0xPredicted (the expected bridged BUSD address) and accept attacker's fake tokens as real bridged BUSD.

// WHY MISSED
// Auditors verify the CREATE2 deterministic deployment works correctly and that the clone is initialized atomically. They do
// not consider that the same deterministic address can be claimed by an attacker on a different chain by replicating the
// factory deployment.
