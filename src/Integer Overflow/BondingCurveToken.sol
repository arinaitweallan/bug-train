// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title BondingCurveToken
contract BondingCurveToken {
    string public name = "BondingToken";
    string public symbol = "BOND";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;

    uint256 public totalSupply;
    uint256 public reserveBalance;

    uint256 public constant EXPONENT = 3;
    uint256 public constant BASE_PRICE = 1e15;

    /// @notice Purchase tokens or assets
    function buy() external payable {
        require(msg.value > 0, "Zero value");

        uint256 tokens = calculateBuyReturn(msg.value);
        require(tokens > 0, "Zero tokens");

        balanceOf[msg.sender] += tokens;
        totalSupply += tokens;
        reserveBalance += msg.value;
    }

    /// @notice Sell tokens or assets
    function sell(uint256 tokenAmount) external {
        require(balanceOf[msg.sender] >= tokenAmount, "Insufficient");

        uint256 ethReturn = calculateSellReturn(tokenAmount);

        balanceOf[msg.sender] -= tokenAmount;
        totalSupply -= tokenAmount;
        reserveBalance -= ethReturn;

        (bool ok,) = msg.sender.call{value: ethReturn}("");
        require(ok, "ETH transfer failed");
    }

    /// @notice Calculate buy return
    function calculateBuyReturn(uint256 ethAmount) public view returns (uint256) {
        uint256 newReserve = reserveBalance + ethAmount;
        uint256 newSupply = _nthRoot(newReserve * 1e18 / BASE_PRICE, EXPONENT);

        return newSupply - totalSupply;
    }

    /// @notice Calculate sell return
    function calculateSellReturn(uint256 tokenAmount) public view returns (uint256) {
        uint256 newSupply = totalSupply - tokenAmount;
        // EXPONENT is 3. What is the maximum value of newSupply such that newSupply^3 fits in uint256?
        uint256 newReserve = _pow(newSupply, EXPONENT) * BASE_PRICE / 1e18;

        return reserveBalance - newReserve;
    }

    function _pow(uint256 base, uint256 exp) internal pure returns (uint256) {
        uint256 result = 1;
        for (uint256 i = 0; i < exp; i++) {
            result = result * base;
        }

        return result;
    }

    function _nthRoot(uint256 x, uint256 n) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 guess = x;
        uint256 prev;

        for (uint256 i = 0; i < 255; i++) {
            prev = guess;
            guess = ((n - 1) * guess + x / _pow(guess, n - 1)) / n;
            if (guess >= prev) break;
        }

        return guess;
    }
}

// BUG
// The _pow function computes newSupply^3 using iterative multiplication. When totalSupply grows beyond ~4.8e25
// (cube root of ~1.15e77 / 1e15 * 1e18), newSupply^3 overflows uint256. The checked multiplication in _pow reverts, making all
// sell operations revert.

// IMPACT
// Once totalSupply crosses the overflow threshold, calculateSellReturn reverts for any sell amount. All token holders are unable
// to sell -- their ETH is permanently locked in the contract.

// INVARIANT
// The _pow(totalSupply, EXPONENT) must always fit within uint256 for the bonding curve to remain functional.

// WHAT BREAKS
// The cubic bonding curve computes newSupply^3 in the sell path. As totalSupply grows past ~4.87e25 (about 48.7 million tokens
// at 18 decimals), the cube overflows uint256 under Solidity 0.8 checked math, causing a permanent revert on all sell operations.

// EXPLOIT PATH
// 1. Users buy tokens over time. totalSupply reaches 50 million tokens = 5e25
// 2. User tries to sell 1e18 tokens. newSupply = 5e25 - 1e18 ~ 5e25
// 3. calculateSellReturn calls _pow(5e25, 3). Iteration: result = 1 * 5e25 = 5e25. result = 5e25 * 5e25 = 2.5e51. result = 2.5e51 * 5e25 = 1.25e77
// 4. uint256 max ~ 1.15e77. 1.25e77 > 1.15e77 -- OVERFLOW REVERT
// 5. All sell operations fail. Users cannot exit. ETH is permanently locked.

// WHY MISSED
// The bonding curve math appears correct for small supply values. Auditors may test with typical amounts and not extrapolate to
// the overflow boundary. The cubic growth rate makes the overflow threshold deceptively reachable.
