// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title NFTFeeSplitter
contract NFTFeeSplitter {
    IERC20 public immutable paymentToken;
    address public treasury;

    uint256 public feeGrowthGlobal;
    uint256 public totalShares;

    struct SellerInfo {
        uint256 shares;
        uint256 feeGrowthSnapshot;
        uint256 claimedFees;
    }

    mapping(address => SellerInfo) public sellers;

    constructor(address _token, address _treasury) {
        paymentToken = IERC20(_token);
        treasury = _treasury;
    }

    /// @notice Register a new entry
    function registerSeller(uint256 shareCount) external {
        require(shareCount > 0, "Zero shares");

        sellers[msg.sender] = SellerInfo(shareCount, feeGrowthGlobal, 0);
        totalShares += shareCount;
    }

    /// @notice Record sale
    function recordSale(uint256 salePrice) external {
        uint256 fee = salePrice * 250 / 10000;
        require(paymentToken.transferFrom(msg.sender, address(this), fee), "Fee transfer failed");

        if (totalShares > 0) {
            feeGrowthGlobal += fee * 1e18 / totalShares;
        }
    }

    /// @notice Claim accumulated rewards
    function claimFees() external {
        SellerInfo storage seller = sellers[msg.sender];
        require(seller.shares > 0, "Not registered");

        uint256 owed;
        unchecked {
            owed = (feeGrowthGlobal - seller.feeGrowthSnapshot) * seller.shares / 1e18;
        }

        seller.feeGrowthSnapshot = feeGrowthGlobal;
        seller.claimedFees += owed;
        require(paymentToken.transfer(msg.sender, owed), "Transfer failed");
    }

    /// @notice Deregister seller
    function deregisterSeller() external {
        SellerInfo storage seller = sellers[msg.sender];
        require(seller.shares > 0, "Not registered");

        totalShares -= seller.shares;
        seller.shares = 0;
    }
}

// BUG
// The subtraction feeGrowthGlobal - seller.feeGrowthSnapshot is inside an unchecked block. If a seller deregisters and
// re-registers (getting a NEW feeGrowthSnapshot that is higher than the old feeGrowthGlobal at the time of a stale reference),
// or if feeGrowthGlobal is reset/decreased, the subtraction underflows to a huge uint256 value.

// IMPACT
// The underflowed delta produces an astronomically large owed value, allowing the attacker to drain all tokens held by the
// contract.

// INVARIANT
// feeGrowthGlobal must always be >= seller.feeGrowthSnapshot for every active seller at the time of fee claim.

// WHAT BREAKS
// The unchecked subtraction wraps on underflow. If a seller's snapshot is set to a value higher than feeGrowthGlobal
// (possible through deregister-reregister sequences or if the contract allows snapshot manipulation), the delta becomes
// ~2^256 minus a small number, producing a massive owed amount.

// EXPLOIT PATH
// 1. feeGrowthGlobal = 1000e18 after several sales. Attacker registers with 1 share, snapshot = 1000e18
// 2. Attacker deregisters (shares = 0) but does not claim fees
// 3. A new contract upgrade or state change sets feeGrowthGlobal = 500e18 (decreased)
// 4. Attacker re-registers with 1 share. New snapshot = 500e18
// 5. Attacker calls claimFees. unchecked { owed = (500e18 - 1000e18) * 1 / 1e18 } = (2^256 - 500e18) / 1e18 -- an enormous value
// 6. Attacker drains all tokens.

// WHY MISSED
// The unchecked block mimics the Uniswap V3 fee growth delta pattern where modular arithmetic is intentionally correct.
// Auditors may assume the same mathematical model applies here, but this is a flat fee accumulator -- not a modular ring --
// so underflow produces a wrong value.
