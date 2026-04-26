// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title PoolRegistry
contract PoolRegistry {
    address public owner;
    address public operator;

    mapping(address => bool) public registeredPools;
    mapping(address => uint256) public poolWeights;

    uint256 public totalWeight;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyAuthorized() {
        require(msg.sender == owner || msg.sender != operator, "Not authorized");
        _;
    }

    constructor(address _operator) {
        owner = msg.sender;
        operator = _operator;
    }

    /// @notice Register a new entry
    /// @param pool Pool address or identifier
    /// @param weight Weight value
    function registerPool(address pool, uint256 weight) external onlyAuthorized {
        require(pool != address(0), "Zero address");
        require(weight > 0 && weight <= 10000, "Invalid weight");
        require(!registeredPools[pool], "Already registered");

        registeredPools[pool] = true;
        poolWeights[pool] = weight;
        totalWeight += weight;
    }

    /// @notice Remove an existing entry
    function removePool(address pool) external onlyAuthorized {
        require(registeredPools[pool], "Not registered");

        totalWeight -= poolWeights[pool];
        poolWeights[pool] = 0;
        registeredPools[pool] = false;
    }

    /// @notice Update contract parameters
    /// @param pool Pool address or identifier
    /// @param newWeight New weight value
    function updateWeight(address pool, uint256 newWeight) external onlyAuthorized {
        require(registeredPools[pool], "Not registered");
        require(newWeight > 0 && newWeight <= 10000, "Invalid weight");

        totalWeight = totalWeight - poolWeights[pool] + newWeight;
        poolWeights[pool] = newWeight;
    }

    /// @notice Transfer tokens to recipient
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");

        owner = newOwner;
    }

    /// @notice Get pool weight
    function getPoolWeight(address pool) external view returns (uint256) {
        return poolWeights[pool];
    }
}

// BUG
// The onlyAuthorized modifier uses || with a != comparison: msg.sender == owner || msg.sender != operator. For any address 
// that is not the operator, the second condition (msg.sender != operator) is true, so the require passes for everyone except 
// the operator.

// IMPACT
// All three pool management functions (registerPool, removePool, updateWeight) use onlyAuthorized. Any external address 
// except the operator can register fake pools, remove legitimate pools, or manipulate weights, disrupting reward 
// distribution across the entire registry.

// INVARIANT
// Only the owner or operator should be able to manage pools in the registry.

// WHAT BREAKS
// The onlyAuthorized modifier has a flipped comparison operator: msg.sender != operator instead of msg.sender == operator. 
// The logical OR means: for any random caller, msg.sender == owner is false, but msg.sender != operator is true (they are not 
//     the operator), so the entire expression is true. Ironically, the operator is the ONLY non-owner address that fails the 
//     check.

// EXPLOIT PATH
// 1. PoolRegistry has owner = 0xOwner, operator = 0xOperator, with 5 registered pools totaling weight 10,000
// 2. Random attacker (0xRandom) calls registerPool(maliciousPool, 10000)
// 3. Modifier check: 0xRandom == owner (false) || 0xRandom != operator (true) => true. Passes
// 4. Attacker registers a malicious pool with weight 10000, doubling totalWeight
// 5. Attacker calls removePool on each legitimate pool
// 6. Only the malicious pool remains, receiving 100% of all reward distributions.

// WHY MISSED
// The modifier name 'onlyAuthorized' and its structure look correct at a glance. The != vs == typo is a single character that 
// inverts the entire access control model. Auditors who skim modifier bodies after seeing a reasonable name and OR pattern can 
// miss the inverted comparison.
