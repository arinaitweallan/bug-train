// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external returns (uint256);
}

/// @title StrategyCompounder
contract StrategyCompounder {
    IERC20 public immutable rewardToken;
    IERC20 public immutable wantToken;
    ISwapRouter public immutable router;

    address public vault;
    uint24 public constant POOL_FEE = 3000;

    constructor(address _reward, address _want, address _router, address _vault) {
        rewardToken = IERC20(_reward);
        wantToken = IERC20(_want);
        router = ISwapRouter(_router);
        vault = _vault;
    }

    /// @notice Harvest and compound rewards
    // @audit: the harvest function passes 0 for the Router exactInputSingle() amountOutMinimum amount
    // this transaction can be front run to return less than the required token amount when swapping leading
    // to loss of tokens
    function harvest() external {
        uint256 rewardBal = rewardToken.balanceOf(address(this));
        require(rewardBal > 0, "Nothing to harvest");

        rewardToken.approve(address(router), rewardBal);
        uint256 wantReceived = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(rewardToken),
                tokenOut: address(wantToken),
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: rewardBal,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        require(wantToken.transfer(vault, wantReceived), "Transfer failed");
    }

    /// @notice Rescue tokens
    function rescueTokens(address token) external {
        require(msg.sender == vault, "Not vault");
        require(IERC20(token).transfer(vault, IERC20(token).balanceOf(address(this))), "Transfer failed");
    }
}

// BUG
// amountOutMinimum is hardcoded to 0. This means the swap will accept ANY output amount, including near-zero. MEV bots can
// sandwich this transaction to extract maximum value.

// IMPACT
// The vault receives a fraction of the expected wantToken because the swap executes at a manipulated price. This directly
// reduces yield for all vault depositors.

// INVARIANT
// Every swap must enforce a minimum output amount that reflects the fair market exchange rate minus an acceptable slippage
// tolerance.

// WHAT BREAKS
// The harvest() function swaps all reward tokens with amountOutMinimum = 0. Any MEV bot can sandwich the transaction to extract
// the entire price impact as profit.

// EXPLOIT PATH
// 1. Strategy has 1,000 rewardTokens. Fair rate: 1 reward = 2 want tokens. Expected output: 2,000 want
// 2. MEV bot front-runs: buys want token in the pool, raising its price. New rate: 1 reward = 0.5 want
// 3. harvest() executes: swaps 1,000 reward, receives 500 want (amountOutMinimum: 0 accepts this)
// 4. MEV bot back-runs: sells want token, restoring price. Bot profit: ~1,500 want tokens
// 5. Vault receives 500 want instead of 2,000. Depositors lose 75% of the harvest yield.

// WHY MISSED
// The swap call uses the correct router interface and all other fields look reasonable. The amountOutMinimum: 0 is buried among
// 8 struct fields and appears to be a conservative 'let the router decide' approach. Auditors may assume slippage is handled
// elsewhere.
