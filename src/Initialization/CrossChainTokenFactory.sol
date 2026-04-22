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
