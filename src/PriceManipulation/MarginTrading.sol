// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/// @title MarginTrading
contract MarginTrading {
    IERC20 public immutable baseToken;
    IERC20 public immutable quoteToken;
    IUniswapV3Pool public immutable pool;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    uint256 public constant LIQUIDATION_THRESHOLD = 120;

    constructor(address _base, address _quote, address _pool) {
        baseToken = IERC20(_base);
        quoteToken = IERC20(_quote);
        pool = IUniswapV3Pool(_pool);
    }

    /// @notice Get current price
    function getCurrentPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
    }

    /// @notice Deposit tokens into the contract
    function depositCollateral(uint256 amount) external {
        require(baseToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        collateral[msg.sender] += amount;
    }

    /// @notice Open a new position
    function openLeverage(uint256 borrowAmount) external {
        uint256 price = getCurrentPrice();
        uint256 collateralValue = (collateral[msg.sender] * price) / 1e18;
        require(
            (collateralValue * 100) / (debt[msg.sender] + borrowAmount) >= LIQUIDATION_THRESHOLD, "Under-collateralized"
        );

        debt[msg.sender] += borrowAmount;
        require(quoteToken.transfer(msg.sender, borrowAmount), "Transfer failed");
    }

    /// @notice Liquidate an undercollateralized position
    function liquidate(address user) external {
        uint256 price = getCurrentPrice();
        uint256 collateralValue = (collateral[user] * price) / 1e18;
        require((collateralValue * 100) / debt[user] < LIQUIDATION_THRESHOLD, "Not liquidatable");
        uint256 seized = collateral[user];
        collateral[user] = 0;
        debt[user] = 0;
        require(baseToken.transfer(msg.sender, seized), "Transfer failed");
    }
}

// BUG
// getCurrentPrice() reads from pool.slot0(), which returns the instantaneous spot price. This price can be manipulated within a
// single transaction via a large swap or flash loan, making all margin calculations exploitable.

// IMPACT
// An attacker can manipulate the spot price to either borrow against inflated collateral or trigger unfair liquidations of
// healthy positions.

// INVARIANT
// Price used for collateral valuation and liquidation must not be manipulable within a single transaction.

// WHAT BREAKS
// getCurrentPrice() reads the instantaneous sqrtPriceX96 from Uniswap V3 slot0(). Any actor can manipulate this price
// atomically using a flash loan to execute a large swap, distort the price, exploit the margin contract, then swap back.

// EXPLOIT PATH
// 1. Attacker takes a flash loan of 10,000 ETH
// 2. Attacker swaps 10,000 ETH into the Uni V3 pool, pushing sqrtPriceX96 from $3,000 to $6,000
// 3. getCurrentPrice() now returns $6,000. Attacker's 100 ETH collateral is valued at $600,000 instead of $300,000
// 4. Attacker calls openLeverage(400000), borrowing $400,000 against the inflated collateral
// 5. Attacker swaps back, price returns to $3,000, repays flash loan. Net profit: $400,000 - $300,000 collateral = $100,000.

// WHY MISSED
// The Uniswap V3 pool interface is legitimate and slot0() is a commonly used function. Auditors unfamiliar with the distinction
// between spot price and TWAP may see the pool integration as standard practice without recognizing the manipulation surface.
