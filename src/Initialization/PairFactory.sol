// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PairFactory
contract PairFactory {
    address public pairImplementation;
    address public admin;

    mapping(bytes32 => address) public getPair;
    address[] public allPairs;

    constructor(address _implementation) {
        pairImplementation = _implementation;
        admin = msg.sender;
    }

    /// @notice Create a new entry or position
    /// @param tokenA Token a value
    /// @param tokenB Token b value
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "Identical tokens");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        require(getPair[salt] == address(0), "Pair exists");

        pair = Clones.cloneDeterministic(pairImplementation, salt);
        getPair[salt] = pair;
        allPairs.push(pair);
    }

    /// @notice Initialize contract state
    /// @param pair Pair value
    /// @param tokenA Token a value
    /// @param tokenB Token b value
    /// @param fee Fee amount or percentage
    function initializePair(address pair, address tokenA, address tokenB, uint256 fee) external {
        require(msg.sender == admin, "Not admin");
        TradingPair(pair).initialize(tokenA, tokenB, fee);
    }

    /// @notice Get pair count
    function getPairCount() external view returns (uint256) {
        return allPairs.length;
    }
}

contract TradingPair {
    address public factory;
    address public token0;
    address public token1;

    uint256 public swapFee;

    bool public initialized;

    /// @notice Initialize contract state
    /// @param _token0 Token0 value
    /// @param _token1 Token1 value
    /// @param _fee Fee amount or percentage
    function initialize(address _token0, address _token1, uint256 _fee) external {
        require(!initialized, "Already initialized");

        initialized = true;
        // factory will be the `PairFactory`
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
        swapFee = _fee;
    }

    /// @notice Exchange one token for another
    /// @param tokenIn Token in value
    /// @param amountIn Input token amount
    function swap(address tokenIn, uint256 amountIn) external returns (uint256) {
        require(initialized, "Not initialized");
        require(tokenIn == token0 || tokenIn == token1, "Invalid token");
        uint256 fee = amountIn * swapFee / 10000;
        return amountIn - fee;
    }

    /// @notice Get reserves
    function getReserves() external view returns (uint256, uint256) {
        return (IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }
}

// BUG
// createPair deploys the clone but does NOT call initialize. initializePair is a separate admin-only function. Between the 
// two transactions, an attacker can front-run initializePair and call initialize() directly on the clone.

// IMPACT
// The attacker initializes the clone with malicious parameters: a zero swapFee (stealing fee revenue), wrong token addresses 
// (breaking the pair), or setting factory to their own address.

// INVARIANT
// Clone creation and initialization must happen atomically in the same transaction to prevent front-running.

// WHAT BREAKS
// The factory creates clones in one transaction and initializes them in a separate admin transaction. An attacker monitors 
// for new clone deployments and calls initialize() directly on the clone before the admin's initializePair transaction lands, 
// setting malicious parameters like zero fees or wrong token addresses.

// EXPLOIT PATH
// 1. Admin calls createPair(WETH, USDC). Clone is deployed at deterministic address 0xPair
// 2. Admin submits initializePair(0xPair, WETH, USDC, 30) (0.3% fee) in the next block
// 3. Attacker sees the createPair event, calls TradingPair(0xPair).initialize(WETH, USDC, 0) with higher gas
// 4. Attacker's initialize lands first: factory = attackerAddr, swapFee = 0
// 5. Admin's initializePair reverts with 'Already initialized'
// 6. The WETH/USDC pair has 0% fees permanently. All fee revenue is lost.

// WHY MISSED
// Auditors check that the clone has an initializer modifier and that initializePair has access control. They overlook that the 
// clone's initialize() itself has no caller restriction - anyone can call it between the two factory transactions.
