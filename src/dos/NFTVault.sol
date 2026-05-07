// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// Unsolicited NFT Callback Inflates Vault Token Array

/// @title NFTVault
contract NFTVault is IERC721Receiver {
    IERC721 public nftCollection;

    uint256[] public heldTokenIds;

    mapping(uint256 => address) public depositor;

    address public manager;

    constructor(address _nft) {
        nftCollection = IERC721(_nft);
        manager = msg.sender;
    }

    /// @notice Deposit tokens into the contract
    function depositNFT(uint256 tokenId) external {
        nftCollection.safeTransferFrom(msg.sender, address(this), tokenId);
        depositor[tokenId] = msg.sender;
    }

    /// @notice Withdraw tokens from the contract
    function withdrawNFT(uint256 tokenId) external {
        require(depositor[tokenId] == msg.sender, "Not depositor");

        depositor[tokenId] = address(0);
        for (uint256 i = 0; i < heldTokenIds.length; i++) {
            if (heldTokenIds[i] == tokenId) {
                heldTokenIds[i] = heldTokenIds[heldTokenIds.length - 1];
                heldTokenIds.pop();
                break;
            }
        }
        nftCollection.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /// @notice On erc721 received
    /// @param address Address value
    /// @param address Address value
    /// @param tokenId Token identifier
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external override returns (bytes4) {
        heldTokenIds.push(tokenId);
        return this.onERC721Received.selector;
    }

    /// @notice Get held count
    function getHeldCount() external view returns (uint256) {
        return heldTokenIds.length;
    }

    /// @notice Distribute tokens to recipients
    function distributeRewards() external {
        require(msg.sender == manager, "Not manager");
        for (uint256 i = 0; i < heldTokenIds.length; i++) {
            address owner = depositor[heldTokenIds[i]];
            if (owner != address(0)) {
                // distribute reward to owner
            }
        }
    }
}

// INVARIANT
// Only NFTs deposited through the official depositNFT function should be tracked in heldTokenIds

// WHAT BREAKS
// An attacker mints 10,000 cheap NFTs from any ERC721 collection and calls safeTransferFrom(attacker, vault, tokenId) for each
// one. The vault's onERC721Received callback at line 45 pushes each tokenId to heldTokenIds. After 10,000 entries,
// withdrawNFT's linear scan at line 28 and distributeRewards' loop at line 55 both exceed gas limits. Legitimate depositors
// cannot withdraw their NFTs.

// EXPLOIT PATH
// 1. Attacker deploys a free-mint ERC721 contract and mints 10,000 NFTs
// 2. Attacker calls nft.safeTransferFrom(attacker, vault, tokenId) for each of the 10,000 NFTs
// 3. Each transfer triggers onERC721Received. Line 45: heldTokenIds.push(tokenId) adds each token
// 4. heldTokenIds.length = 10,000+ (original deposits + 10,000 spam)
// 5. Legitimate user calls withdrawNFT(originalTokenId)
// 6. Loop at line 28 iterates 10,000+ entries searching for originalTokenId. ~5,000 gas per iteration * 10,000 = 50M gas. Exceeds block gas limit
// 7. withdrawNFT reverts. All legitimately deposited NFTs are permanently locked.

// WHY MISSED
// IERC721Receiver is required for safe transfers and auditors verify the selector is returned correctly. The assumption that
// only the expected collection sends NFTs is implicit -- the callback accepts any ERC721 transfer from any source, and this is
// easy to miss.
