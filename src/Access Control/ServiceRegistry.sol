// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title ServiceRegistry
contract ServiceRegistry {
    address public admin;

    mapping(address => bool) public registeredServices;
    mapping(address => uint256) public serviceFees;
    uint256 public totalFees;

    constructor() {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(tx.origin == admin, "Not admin");
        _;
    }

    function registerService(address service, uint256 fee) external onlyAdmin {
        require(service != address(0), "Zero address");
        require(fee > 0 && fee <= 1 ether, "Invalid fee");

        registeredServices[service] = true;
        serviceFees[service] = fee;
    }

    function removeService(address service) external onlyAdmin {
        require(registeredServices[service], "Not registered");
        registeredServices[service] = false;
        serviceFees[service] = 0;
    }

    function collectFees() external onlyAdmin {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees");
        (bool sent,) = admin.call{value: balance}("");
        require(sent, "Transfer failed");
    }

    function payForService(address service) external payable {
        require(registeredServices[service], "Not registered");
        require(msg.value == serviceFees[service], "Wrong fee");
        totalFees += msg.value;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero address");
        admin = newAdmin;
    }

    function isRegistered(address service) external view returns (bool) {
        return registeredServices[service];
    }
}

// INVARIANT
// Administrative functions must verify the direct caller (msg.sender), not the transaction originator (tx.origin).

// WHAT BREAKS
// Using tx.origin for authorization means any contract in the call chain initiated by the admin can invoke admin functions. 
// An attacker deploys a malicious contract that the admin might interact with (e.g., a token, NFT, or DeFi protocol). 
// When the admin calls any function on that contract, the malicious contract calls transferAdmin(attackerAddress) on 
// ServiceRegistry, and the check passes because tx.origin == admin.

// EXPLOIT PATH
// 1. ServiceRegistry has admin = Alice, holding 50 ETH in fees
// 2. Attacker deploys MaliciousNFT contract with a mint function that internally calls serviceRegistry.transferAdmin(attacker) then serviceRegistry.collectFees()
// 3. Attacker airdrops a free-mint NFT to Alice, who calls MaliciousNFT.mint()
// 4. Inside mint: tx.origin == Alice == admin. transferAdmin(attacker) passes. collectFees() passes
// 5. admin is now attacker. 50 ETH is sent to attacker
// 6. Alice only intended to mint an NFT and lost admin access plus all fees.

// WHY MISSED
// tx.origin == admin is visually similar to msg.sender == admin and reads naturally as 'only the admin can call this.' 
// The vulnerability requires understanding the multi-contract call chain threat model, which is not apparent from reading 
// a single contract in isolation.
