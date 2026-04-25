// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title NFTAuction
contract NFTAuction {
    using SafeERC20 for IERC20;

    IERC20 public paymentToken;
    IERC721 public nftContract;

    struct Auction {
        address seller;
        uint256 highBid;
        address highBidder;
        uint256 endTime;
    }
    mapping(uint256 => Auction) public auctions;

    constructor(address _nft, address _payment) {
        nftContract = IERC721(_nft);
        paymentToken = IERC20(_payment);
    }

    /// @notice Create a new entry or position
    /// @param tokenId Token identifier
    /// @param startPrice Start price value
    /// @param duration Time duration in seconds
    function createAuction(uint256 tokenId, uint256 startPrice, uint256 duration) external {
        require(duration >= 1 hours, "Too short");

        nftContract.transferFrom(msg.sender, address(this), tokenId);
        auctions[tokenId] = Auction(msg.sender, startPrice, address(0), block.timestamp + duration);
    }

    /// @notice Place a bid in the auction
    /// @param tokenId Token identifier
    /// @param amount Token amount
    function bid(uint256 tokenId, uint256 amount) external {
        Auction storage auction = auctions[tokenId];
        require(block.timestamp < auction.endTime, "Ended");
        require(amount > auction.highBid, "Bid too low");

        if (auction.highBidder != address(0)) {
            paymentToken.safeTransfer(auction.highBidder, auction.highBid);
        }

        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        auction.highBid = amount;
        auction.highBidder = msg.sender;
    }

    /// @notice Cancel a pending operation
    function cancelAuction(uint256 tokenId) external {
        Auction storage auction = auctions[tokenId];
        require(block.timestamp < auction.endTime, "Already ended");
        require(auction.highBidder == address(0), "Has bids");
        nftContract.transferFrom(address(this), auction.seller, tokenId);
        delete auctions[tokenId];
    }

    /// @notice Settle a pending transaction
    function settleAuction(uint256 tokenId) external {
        Auction storage auction = auctions[tokenId];
        require(block.timestamp >= auction.endTime, "Not ended");
        require(auction.highBidder != address(0), "No bids");
        paymentToken.safeTransfer(auction.seller, auction.highBid);
        nftContract.transferFrom(address(this), auction.highBidder, tokenId);
        delete auctions[tokenId];
    }
}

// BUG
// cancelAuction accepts a tokenId but never checks that msg.sender == auction.seller. Any external caller can cancel
// any auction that has no bids.

// IMPACT
// An attacker can cancel legitimate auctions by calling cancelAuction before anyone bids, returning the NFT to the seller
// and disrupting the marketplace. The seller loses their auction listing and potential sale revenue.

// INVARIANT
// Only the auction seller should be able to cancel their own auction.

// WHAT BREAKS
// cancelAuction checks that the auction has not ended and has no bids, but never verifies that the caller is the auction
// seller. Any address can cancel any auction that has zero bids, disrupting legitimate sellers' listings and preventing sales.

// EXPLOIT PATH
// 1. Alice creates an auction for a rare NFT (tokenId=42) with startPrice=10 ETH and 24-hour duration
// 2. Attacker calls cancelAuction(42) immediately, before any bids are placed
// 3. Function passes: timestamp < endTime (true), highBidder == address(0) (true)
// 4. NFT is transferred back to Alice. Auction is deleted
// 5. Attacker can repeatedly grief Alice every time she relists, preventing her from ever completing a sale
// 6. A competitor marketplace operator could systematically cancel all auctions to drive users away.

// WHY MISSED
// The function has two sensible guards (time check, no-bids check) that create an impression of thoroughness.
// Auditors often focus on financial impacts and may deprioritize griefing attacks, missing that the ownership check is
// the most critical guard that is absent.

