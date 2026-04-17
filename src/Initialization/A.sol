// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.19;

// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// /// @title StakingVaultV2
// contract StakingVaultV2 is Initializable, PausableUpgradeable, ReentrancyGuardUpgradeable {
//     using SafeERC20 for IERC20;

//     address public owner;
//     IERC20 public stakingToken;
//     uint256 public totalStaked;

//     mapping(address => uint256) public stakes;

//     /// @notice Initialize contract state
//     /// @param _owner Token owner address
//     /// @param _token Token contract address
//     function initialize(address _owner, address _token) external initializer {
//         owner = _owner;
//         stakingToken = IERC20(_token);
//         __Pausable_init();
//     }

//     modifier onlyOwner() {
//         require(msg.sender == owner, "Not owner");
//         _;
//     }

//     /// @notice Stake tokens to earn rewards
//     function stake(uint256 amount) external whenNotPaused nonReentrant {
//         stakingToken.safeTransferFrom(msg.sender, address(this), amount);
//         stakes[msg.sender] += amount;
//         totalStaked += amount;
//     }

//     /// @notice Unstake and reclaim tokens
//     function unstake(uint256 amount) external nonReentrant {
//         require(stakes[msg.sender] >= amount, "Insufficient");

//         stakes[msg.sender] -= amount;
//         totalStaked -= amount;
//         stakingToken.safeTransfer(msg.sender, amount);
//     }

//     /// @notice Pause contract operations
//     function pause() external onlyOwner {
//         _pause();
//     }

//     /// @notice Resume contract operations
//     function unpause() external onlyOwner {
//         _unpause();
//     }

//     /// @notice Get total staked
//     function getTotalStaked() external view returns (uint256) {
//         return totalStaked;
//     }
// }

// BUG
// The initialize function calls __Pausable_init() but omits __ReentrancyGuard_init(). The ReentrancyGuardUpgradeable _status 
// variable is never initialized from its default value of 0.

// IMPACT
// ReentrancyGuardUpgradeable expects _status to be initialized to _NOT_ENTERED (1). With _status=0, the nonReentrant modifier 
// may not function correctly, potentially allowing reentrancy attacks on stake and unstake.

// INVARIANT
// All inherited initializable contracts must have their __init() functions called during initialization to activate their 
// protections.

// WHAT BREAKS
// The ReentrancyGuard _status variable remains at its default value 0 instead of being set to _NOT_ENTERED (1). Depending on 
// the OpenZeppelin version, this can either cause all nonReentrant functions to revert (bricking the contract) or render the 
// reentrancy guard ineffective, exposing stake and unstake to reentrancy.

// EXPLOIT PATH
// 1. StakingVaultV2 is deployed behind a proxy. initialize(owner, WETH) is called
// 2. __Pausable_init() runs correctly but __ReentrancyGuard_init() is never called
// 3. _status remains 0 (default) instead of 1 (_NOT_ENTERED)
// 4. User calls stake(100e18). nonReentrant checks _status == 1, but _status is 0
// 5. In OZ v4.x: function reverts with 'ReentrancyGuard: reentrant call' - all staking is bricked
// 6. Alternatively, if the guard is bypassed, a malicious token's transferFrom callback can reenter unstake.

// WHY MISSED
// Auditors verify that inherited contracts appear in the inheritance list and that the initializer modifier is present, but do 
// not systematically diff the inheritance chain against the __init() calls to catch missing parent 
