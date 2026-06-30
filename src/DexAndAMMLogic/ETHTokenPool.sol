// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ETHTokenPool
/// @notice Automated market maker contract that provides on-chain liquidity and swap routing.
contract ETHTokenPool {
    using SafeERC20 for IERC20;

    IERC20 public token;

    uint256 public reserveETH;
    uint256 public reserveToken;
    uint256 public totalLP;

    mapping(address => uint256) public lpBalance;

    constructor(address _token) {
        token = IERC20(_token);
    }

    /// @notice Add liquidity to the pool
    function addLiquidity(uint256 tokenAmount) external payable returns (uint256 lp) {
        require(msg.value > 0 && tokenAmount > 0, "Zero");

        token.safeTransferFrom(msg.sender, address(this), tokenAmount);
        if (totalLP == 0) {
            lp = msg.value + tokenAmount;
        } else {
            uint256 lpETH = (msg.value * totalLP) / reserveETH;
            uint256 lpToken = (tokenAmount * totalLP) / reserveToken;
            lp = lpETH < lpToken ? lpETH : lpToken;
        }

        reserveETH += msg.value;
        reserveToken += tokenAmount;
        lpBalance[msg.sender] += lp;
        totalLP += lp;
    }

    /// @notice Exchange one token for another
    function swapETHForToken() external payable returns (uint256 amountOut) {
        require(msg.value > 0, "Zero ETH");
        amountOut = (msg.value * reserveToken) / (reserveETH + msg.value);
        require(amountOut > 0, "Zero output");

        reserveETH += msg.value;
        reserveToken -= amountOut;
        token.safeTransfer(msg.sender, amountOut);
    }

    /// @notice Exchange one token for another
    // In swapTokenForETH, which happens first: the ETH transfer to msg.sender or the reserve updates?
    function swapTokenForETH(uint256 tokenAmount) external returns (uint256 ethOut) {
        require(tokenAmount > 0, "Zero");
        token.safeTransferFrom(msg.sender, address(this), tokenAmount);
        ethOut = (tokenAmount * reserveETH) / (reserveToken + tokenAmount);
        require(ethOut > 0, "Zero output");

        (bool ok,) = payable(msg.sender).call{value: ethOut}("");
        require(ok, "ETH transfer failed");

        reserveToken += tokenAmount;
        reserveETH -= ethOut;
    }

    /// @notice Get reserves
    function getReserves() external view returns (uint256, uint256) {
        return (reserveETH, reserveToken);
    }
}

// BUG
// In swapTokenForETH, ETH is sent via low-level call at line 59 BEFORE updating reserveToken and reserveETH at lines 62-63. The
// recipient's receive/fallback function can re-enter swapTokenForETH while reserves still reflect the pre-swap state.

// IMPACT
// During reentrancy, the attacker re-enters swapTokenForETH (not swapETHForToken). The stale reserveETH means the pool
// calculates ETH output against the full reserve that has already been partially sent out. Each reentry drains ETH at the same
// favorable rate.

// INVARIANT
// All state updates (reserve changes) must be completed before any external call (ETH transfer, token callback) to prevent
// reentrancy from observing stale state.

// WHAT BREAKS
// The ETH transfer in swapTokenForETH triggers a callback to the recipient before reserves are updated. A malicious contract
// re-enters swapTokenForETH again, which reads stale (pre-swap) reserves, and extracts more ETH than the constant-product
// invariant allows.

// EXPLOIT PATH
// 1. Pool: reserveETH=100, reserveToken=100,000
// 2. Attacker contract calls swapTokenForETH(10,000 tokens). ethOut = 10,000 * 100 / (100,000 + 10,000) = 9.09 ETH. ETH is sent to attacker
// 3. At this point reserves are STALE: reserveETH still 100, reserveToken still 100,000 (updates at lines 62-63 have not executed yet)
// 4. Attacker's receive() re-enters swapTokenForETH(10,000 tokens). ethOut = 10,000 * 100 / (100,000 + 10,000) = 9.09 ETH again (same stale reserves). ETH is sent to attacker again
// 5. Total ETH received: 18.18 ETH. With correct reserves after first swap (reserveETH=90.91, reserveToken=110,000), second swap should yield: 10,000 * 90.91 / (110,000 + 10,000) = 7.58 ETH
// 6. Excess extraction: 18.18 - (9.09 + 7.58) = 1.51 ETH stolen per double-entry. Multiple reentries compound this, draining the pool's ETH.

// WHY MISSED
// The swap function uses SafeERC20 for token transfers (correct) but sends native ETH via low-level call. Auditors may focus on
// token transfer safety and overlook that .call{value:} triggers recipient code execution. The checks-effects-interactions
// violation is classic but remains common in ETH-handling pool contracts.
