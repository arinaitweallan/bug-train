// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/// @title RewardsTokenV1
contract RewardsTokenV1 is Initializable, ERC20Upgradeable {
    address public treasury;

    uint256 public maxSupply;
    uint256 public mintCooldown;
    uint256 public lastMintTime; // starts at 0

    mapping(address => bool) public isMinter;

    constructor() {
        treasury = msg.sender;
        maxSupply = 100_000_000e18;
        mintCooldown = 1 days;
        // missing disable initializers in constructor
        //
    }

    /// @notice Initialize contract state
    /// @param name Name value
    /// @param symbol Symbol value
    function initialize(string memory name, string memory symbol) external initializer {
        __ERC20_init(name, symbol);
    }

    /// @notice Mint new tokens or shares
    /// @param to Recipient address
    /// @param amount Token amount
    function mint(address to, uint256 amount) external {
        require(msg.sender == treasury, "Not treasury");
        require(totalSupply() + amount <= maxSupply, "Exceeds max");
        require(block.timestamp >= lastMintTime + mintCooldown, "Cooldown active");

        lastMintTime = block.timestamp;
        _mint(to, amount);
    }

    /// @notice Burn tokens or shares
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Configure a contract parameter
    /// @param minter Minter value
    /// @param status Status value
    function setMinter(address minter, bool status) external {
        require(msg.sender == treasury, "Not treasury");
        isMinter[minter] = status;
    }

    /// @notice Get treasury
    function getTreasury() external view returns (address) {
        return treasury;
    }

    /// @notice Get max supply
    function getMaxSupply() external view returns (uint256) {
        return maxSupply;
    }

    /// @notice Get remaining mintable
    function getRemainingMintable() external view returns (uint256) {
        return maxSupply - totalSupply();
    }
}

// BUG
// treasury, maxSupply, and mintCooldown are set in the constructor. In an upgradeable proxy pattern, the constructor runs on
// the implementation's storage, not the proxy's. The proxy's storage has treasury=address(0), maxSupply=0, and mintCooldown=0.

// IMPACT
// On the proxy: treasury is address(0) so no one can mint. maxSupply is 0 so the supply check always reverts. The token is
// completely non-functional when accessed through the proxy.

// INVARIANT
// All state variables in an upgradeable contract must be set in the initialize function, not the constructor, to affect the
// proxy's storage.

// WHAT BREAKS
// treasury, maxSupply, and mintCooldown are set in the constructor, which only writes to the implementation's storage. On the
// proxy, treasury is address(0), maxSupply is 0, and mintCooldown is 0. The mint function requires msg.sender == address(0)
// (impossible) and totalSupply + amount <= 0 (impossible), making the token permanently unmintable.

// EXPLOIT PATH
// 1. RewardsTokenV1 implementation deployed. Constructor sets treasury=deployer, maxSupply=100Me18, mintCooldown=1day on implementation storage
// 2. ERC1967Proxy deployed pointing to implementation. initialize('Rewards', 'RWD') called via proxy
// 3. On proxy storage: treasury=address(0), maxSupply=0, mintCooldown=0
// 4. Treasury calls proxy.mint(user, 1000e18). Reverts: msg.sender != address(0)
// 5. Even if treasury were set, maxSupply=0 means totalSupply() + amount <= 0 always reverts
// 6. Token is deployed but completely non-functional. Cannot mint any tokens ever.

// WHY MISSED
// The constructor looks correct in isolation. Auditors who are not specifically checking for the upgradeable proxy pattern
// may miss that constructor state only lives on the implementation, not the proxy.
