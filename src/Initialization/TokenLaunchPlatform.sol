// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TokenLaunchPlatform
contract TokenLaunchPlatform {
    using SafeERC20 for IERC20;

    address public deployer; // init in constructor
    address public launchToken; // config
    address public paymentToken; // config

    uint256 public tokenPrice; // config
    uint256 public totalRaised;

    bool public configured; // config
    bool public launched; // launch

    mapping(address => uint256) public contributions;

    constructor() {
        deployer = msg.sender;
    }

    /// @notice Configure
    /// @param _launchToken Launch token value
    /// @param _paymentToken Payment token value
    /// @param _price Price value
    function configure(address _launchToken, address _paymentToken, uint256 _price) external {
        require(msg.sender == deployer, "Not deployer");
        require(!configured, "Already configured");

        launchToken = _launchToken;
        paymentToken = _paymentToken;
        tokenPrice = _price;
        configured = true;
    }

    /// @notice Register a new entry
    // q what does this function do?
    function registerForLaunch() external {
        require(configured, "Not configured");
        require(!launched, "Already launched");

        contributions[msg.sender] = 0;
    }

    // q which of these functions should be called first?

    /// @notice Launch
    // q shouldn't this be protected to be called after a certain period of time?
    // a user can call it after deployment and dos registration
    // but still a user can contribute without registering for launch
    function launch() external {
        require(configured, "Not configured");
        require(!launched, "Not yet");

        launched = true;
    }

    /// @notice Contribute
    function contribute(uint256 amount) external {
        require(launched, "Not launched");

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), amount);
        contributions[msg.sender] += amount;
        totalRaised += amount;
    }

    /// @notice Claim accumulated rewards
    function claim() external {
        require(launched, "Not launched");
        uint256 amount = contributions[msg.sender];
        require(amount > 0, "Nothing to claim");

        uint256 tokens = (amount * 1e18) / tokenPrice;
        contributions[msg.sender] = 0;
        IERC20(launchToken).safeTransfer(msg.sender, tokens);
    }

    /// @notice Withdraw tokens from the contract
    function withdrawRaised() external {
        require(msg.sender == deployer, "Not deployer");

        uint256 bal = IERC20(paymentToken).balanceOf(address(this));
        IERC20(paymentToken).safeTransfer(deployer, bal);
    }
}

// BUG
// The launch() function has no access control. Anyone can call it to transition the platform to the launched state before 
// the deployer has finished setup (e.g., before funding the contract with launch tokens).

// IMPACT
// If launched before the contract holds launch tokens, users contribute payment tokens but claim() reverts because there are 
// no launch tokens to distribute. Users' payment tokens are locked, and the deployer gets the raised funds without delivering 
// tokens.

// INVARIANT
// Each step in the bootstrap sequence must be callable only by the authorized deployer and only when prerequisites are met.

// WHAT BREAKS
// The launch() function lacks access control. An attacker calls launch() immediately after the deployer calls configure(), 
// before launch tokens are transferred to the contract. Users contribute payment tokens, but claim() reverts because the 
// contract has no launch tokens. Payment tokens are stranded.

// EXPLOIT PATH
// 1. Deployer calls configure(TOKEN, USDC, 1e18) setting up the launch platform
// 2. Deployer plans to transfer 1,000,000 TOKEN to the contract next, then call launch()
// 3. Attacker calls launch() immediately after configure. launched = true
// 4. Users see the launch is active and contribute 500,000 USDC via contribute()
// 5. Users call claim() but it reverts because the contract holds 0 TOKEN
// 6. 500,000 USDC is stuck. Deployer can call withdrawRaised() to take it, but no tokens are distributed.

// WHY MISSED
// The configure function has proper access control, creating the impression that the bootstrap flow is protected. Auditors 
// verify the deployer-restricted functions and overlook that launch() is a critical state transition without any caller 
// restriction.
