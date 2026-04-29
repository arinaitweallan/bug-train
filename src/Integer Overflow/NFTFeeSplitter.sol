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
