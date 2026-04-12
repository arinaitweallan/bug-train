// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ClaimDistributor
contract ClaimDistributor {
    using SafeERC20 for IERC20;

    address public admin;
    IERC20 public rewardToken;
    uint256 public claimDeadline;
    uint256 public totalClaimed; // this not initialized and starts at 0
    bytes32 public merkleRoot;

    mapping(address => bool) public hasClaimed;

    constructor(address _admin, address _token, bytes32 _merkleRoot, uint256 _claimWindowDays) {
        admin = _admin;
        rewardToken = IERC20(_token);
        merkleRoot = _merkleRoot;
        claimDeadline = block.timestamp + _claimWindowDays; // block.timestamp + 3 days
    }

    /// @notice Claim accumulated rewards
    /// @param amount Token amount
    /// @param proof Merkle or validity proof
    function claim(uint256 amount, bytes32[] calldata proof) external {
        require(block.timestamp <= claimDeadline, "Claim window closed");
        require(!hasClaimed[msg.sender], "Already claimed");
        require(_verify(msg.sender, amount, proof), "Invalid proof");

        hasClaimed[msg.sender] = true;
        totalClaimed += amount;
        rewardToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Recover tokens or access
    function recoverUnclaimed() external {
        require(msg.sender == admin, "Not admin");
        require(block.timestamp > claimDeadline, "Window open");
        
        uint256 remaining = rewardToken.balanceOf(address(this));
        rewardToken.safeTransfer(admin, remaining);
    }

    function _verify(address account, uint256 amount, bytes32[] calldata proof) internal view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(account, amount));
        bytes32 computed = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            computed = keccak256(abi.encodePacked(computed, proof[i]));
        }
        return computed == merkleRoot;
    }

    /// @notice Get time remaining
    function getTimeRemaining() external view returns (uint256) {
        if (block.timestamp >= claimDeadline) return 0;
        return claimDeadline - block.timestamp;
    }
}

// INVARIANT
// The claim window duration must correctly reflect the intended number of days in seconds.

// WHAT BREAKS
// The constructor adds the day count directly to block.timestamp without multiplying by 86400 (1 days). 
// A 30-day claim window becomes 30 seconds. Users cannot claim their rewards in time, and the admin recovers all 
// unclaimed tokens after the accidental 30-second window expires.

// EXPLOIT PATH
// 1. ClaimDistributor is deployed with _claimWindowDays=30, merkleRoot for 1000 eligible users
// 2. claimDeadline = block.timestamp + 30 = ~30 seconds from now
// 3. 500,000 USDC reward tokens are transferred to the contract
// 4. 30 seconds later, the claim window closes. Only 2 users managed to claim
// 5. Admin calls recoverUnclaimed() and retrieves 498,000 USDC that should have gone to 998 users
// 6. Users who try to claim after 30 seconds get 'Claim window closed' revert.
