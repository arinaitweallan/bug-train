// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title StakingRewardToken
contract StakingRewardToken is ERC20 {
    address public stakingContract;
    address public governance;

    constructor(address _governance) ERC20("Staked Reward", "sRWD") {
        governance = _governance;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    /// @notice Configure a contract parameter
    function setStakingContract(address _staking) external onlyGovernance {
        require(_staking != address(0), "Zero address");
        stakingContract = _staking;
    }

    /// @notice Mint new tokens or shares
    /// @param to Recipient address
    /// @param amount Token amount
    function mint(address to, uint256 amount) external {
        require(amount > 0, "Zero amount");
        require(to != address(0), "Zero address");
        _mint(to, amount);
    }

    /// @notice Burn tokens or shares
    /// @param from Source address
    /// @param amount Token amount
    function burn(address from, uint256 amount) external {
        require(amount > 0, "Zero amount");
        require(balanceOf(from) >= amount, "Insufficient");
        _burn(from, amount);
    }

    /// @notice Transfer tokens to recipient
    /// @param to Recipient address
    /// @param amount Token amount
    function transfer(address to, uint256 amount) public override returns (bool) {
        return super.transfer(to, amount);
    }

    /// @notice Total circulating
    function totalCirculating() external view returns (uint256) {
        return totalSupply();
    }
}

// INVARIANT
// Only the authorized staking contract can mint new reward tokens.

// WHAT BREAKS
// The mint function lacks caller verification. Anyone can call mint(attackerAddress, 1_000_000e18) to create 1 million tokens,
// then sell them on a DEX to steal value from legitimate stakers.

// EXPLOIT PATH
// 1. StakingRewardToken is deployed with governance set. stakingContract is set to the legitimate staking pool
// 2. Token trades at $1.00 on a DEX with $500,000 liquidity
// 3. Attacker calls mint(attackerAddress, 10_000_000e18) minting 10M tokens
// 4. Attacker swaps 10M tokens on the DEX, extracting up to $500,000
// 5. Token price crashes to near zero; all stakers lose their position value.

// WHY MISSED
// The stakingContract variable is set via a governance-protected setter, creating a false sense that the mint integration is
// complete. Auditors see the governance pattern and assume the authorization flow covers mint, but the
// require(msg.sender == stakingContract) guard was never added to mint itself.
