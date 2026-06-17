// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

contract TokenPay7702 {
    error Unauthorized();
    error ERC20ApprovalFailed();
    error TargetExecutionFailed();

    address public invoker;

    constructor() {}

    // Allows execution if the trusted Invoker is calling it
    modifier requireInvoker() {
        if (msg.sender != invoker) {
            revert Unauthorized();
        }
        _;
    }

    function setInvoker(address _invoker) external {
        require(invoker == address(0), "already set");
        invoker = _invoker;
    }

    /// @notice Approves a protocol to spend tokens and immediately triggers a follow up action.
    /// @param token The address of the ERC-20 token.
    /// @param spender The contract address being approved
    /// @param amount The number of tokens to approve.
    /// @param target The contract to call immediately after approval (often the same as spender)
    /// @param data The function call data to execute on the target contract
    function approveAndCall(address token, address spender, uint256 amount, address target, bytes calldata data)
        external
        payable
        requireInvoker
        returns (bytes memory)
    {
        // approve tokens
        bool approveSuccess = IERC20(token).approve(spender, amount);
        if (!approveSuccess) revert ERC20ApprovalFailed();

        // execute the interaction
        (bool targetSuccess, bytes memory returnData) = target.call{value: msg.value}(data);

        if (!targetSuccess) {
            if (returnData.length > 0) {
                BubbleRevert.bubbleRevert(returnData);
            } else {
                revert TargetExecutionFailed();
            }
        }

        return returnData;
    }
}

contract EIP7702Invoker {
    error Unauthorized();
    error SingleShotExecutionFailed();

    struct ExecutionArgs {
        address token;
        address spender;
        uint256 amount;
        address target;
        bytes data;
    }

    TokenPay7702 public implementation;
    address admin;

    constructor(address _impl) {
        implementation = TokenPay7702(_impl);
        admin = msg.sender;
    }

    function setImplementation(address _implementation) external {
        require(msg.sender == admin, "unauthorized");
        implementation = TokenPay7702(_implementation);
    }

    /// @notice The single function a user calls. It applies the 7702
    /// delegation and executes the approve-and-call in one go
    /// @param authorization The EIP-7702 signed authorization payload
    // @param eoa The address of the EOA being updated
    /// @param args The token execution parameters
    function executeSingleShot(
        bytes calldata authorization,
        address,
        /**
         * eoa
         */
        ExecutionArgs calldata args
    )
        external
        payable
    {
        // if (msg.sender != eoa) revert Unauthorized();

        // Apply the EIP-7702 Authorization List
        // In a real Prague-hardfork environment, this is handled by passing the authorization
        // list directly in the transaction payload. For an explicit on-chain contract trigger,
        // we use the designated EVM assembly or compiler-supported mechanisms for 7702.
        _apply7702Authorization(authorization);

        // prepare the call targeting the EOA's newly acquired implementation logic
        // bytes memory executionCalldata = abi.encodeWithSignature(
        //     "approveAndCall(address,address,uint256,address,bytes)",
        //     args.token,
        //     args.spender,
        //     args.amount,
        //     args.target,
        //     args.data
        // );

        // bytes memory executionCalldata = abi.encodeWithSelector(
        //     TokenPay7702.approveAndCall.selector, args.token, args.spender, args.amount, args.target, args.data
        // );

        implementation.approveAndCall(args.token, args.spender, args.amount, args.target, args.data);

        // Trigger execution.
        // Note: To pass the 'onlySelf' check in our implementation, the EOA must be the caller.
        // Therefore, the transaction origin or an authorized signature from the EOA must validate this step.
        // If the EOA calls this Invoker directly, msg.sender here is the EOA.

        // (bool success, bytes memory reason) = eoa.call{value: msg.value}(executionCalldata);
        // if (!success) {
        //     if (reason.length > 0) {
        //         BubbleRevert.bubbleRevert(reason);
        //     } else {
        //         revert SingleShotExecutionFailed();
        //     }
        // }
    }

    // Low-level helper mimicking the execution of the authorization tuple processing
    function _apply7702Authorization(bytes calldata auth) internal pure {
        // Internal processing of yParity, r, s, contractAddress to set the EOA pointer.
        // On a production EIP-7702 network, this happens natively at the start of the tx
        // processing frame before contract bytecodes run.
    }
}

library BubbleRevert {
    function bubbleRevert(bytes memory returnData) internal pure {
        assembly {
            let size := mload(returnData)
            revert(add(returnData, 32), size)
        }
    }
}
