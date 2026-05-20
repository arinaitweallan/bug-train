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
