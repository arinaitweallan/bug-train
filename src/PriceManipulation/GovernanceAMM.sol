// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV3Pool {
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
    function liquidity() external view returns (uint128);
}

/// @title GovernanceAMM
contract GovernanceAMM {
    IUniswapV3Pool public immutable priceOracle;
    IERC20 public immutable govToken;
    IERC20 public immutable stablecoin;

    uint32 public constant TWAP_WINDOW = 1800;
    uint256 public constant MIN_COLLATERAL_RATIO = 200;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    constructor(address _oracle, address _gov, address _stable) {
        priceOracle = IUniswapV3Pool(_oracle);
        govToken = IERC20(_gov);
        stablecoin = IERC20(_stable);
    }

    // q The TWAP uses a 30-minute window. Is this sufficient if the oracle pool has very low liquidity?
    /// @notice Get twapprice
    function getTWAPPrice() public view returns (uint256) {
        uint32[] memory secs = new uint32[](2); // [, ]
        secs[0] = TWAP_WINDOW; // [1800, ]
        secs[1] = 0; // [1800, 0]

        (int56[] memory ticks,) = priceOracle.observe(secs);
        int24 avgTick = int24((ticks[1] - ticks[0]) / int56(int32(TWAP_WINDOW)));
        uint256 price = uint256(int256(avgTick) + 100000) * 1e14;
        return price;
    }

    /// @notice Deposit tokens into the contract
    /// @param govAmount Gov amount value
    /// @param borrowAmount Amount to borrow
    function depositAndBorrow(uint256 govAmount, uint256 borrowAmount) external {
        require(govToken.transferFrom(msg.sender, address(this), govAmount), "Transfer failed");

        collateral[msg.sender] += govAmount;
        uint256 price = getTWAPPrice();
        uint256 collateralValue = collateral[msg.sender] * price / 1e18;

        require(
            collateralValue * 100 >= (debt[msg.sender] + borrowAmount) * MIN_COLLATERAL_RATIO, "Under-collateralized"
        );
        debt[msg.sender] += borrowAmount;

        require(stablecoin.transfer(msg.sender, borrowAmount), "Transfer failed");
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(address user) external {
        uint256 price = getTWAPPrice();
        uint256 value = collateral[user] * price / 1e18;
        require(debt[user] * 100 > value * 90, "Healthy");

        uint256 seized = collateral[user];
        collateral[user] = 0;
        debt[user] = 0;

        require(govToken.transfer(msg.sender, seized), "Transfer failed");
    }
}

// BUG
// getTWAPPrice() uses a 30-minute TWAP from a governance token pool that may have very low liquidity. There is no check on pool.
// liquidity() before trusting the TWAP. For low-liquidity pools, even a TWAP can be manipulated at reasonable cost by
// sustaining a price deviation across the observation window.

// IMPACT
// If the governance token pool has only $100K liquidity, sustaining a 2x manipulation for 30 minutes costs ~$100K in arb losses.
// If the protocol secures $10M, the attack is highly profitable.

// INVARIANT
// The cost of manipulating the price oracle must exceed the maximum extractable value from the manipulation.

// WHAT BREAKS
// getTWAPPrice() trusts the Uniswap pool's TWAP without validating pool liquidity. Governance tokens frequently have thin
// liquidity ($50K-$500K), making the TWAP economically manipulable even with a 30-minute window.

// EXPLOIT PATH
// 1. Governance token pool has $100K liquidity. Protocol secures $5M in loans
// 2. Attacker accumulates gov tokens. Over 30 minutes, sustains buy pressure to push TWAP 3x above fair value. Cost: ~$100K in arb losses from pool depth
// 3. At inflated TWAP, attacker deposits 100K gov tokens. collateralValue = 100K * 3x_price = $300K equivalent
// 4. Borrows $150K stablecoins (200% ratio). Fair collateral value: $100K. Excess: $50K
// 5. Attacker defaults. Protocol holds $100K collateral vs $150K debt = $50K bad debt. Net profit: $50K - $100K manipulation cost. At larger scale ($50M protocol, same pool), profit is 10x.

// WHY MISSED
// The TWAP implementation is technically correct with a 30-minute window. The vulnerability is economic: the cost of
// manipulation depends on pool liquidity, which is an external parameter not visible in the code. Auditors reviewing the TWAP
// logic may validate the math without assessing the liquidity of the actual oracle pool.
