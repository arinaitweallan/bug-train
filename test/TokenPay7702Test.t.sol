// SPDX-License-Identifier: MIT
pragma solidity 0.8.24; // Note: EIP-7702 requires a compiler version supporting Prague EVM features (e.g., 0.8.24+)

import {Test} from "forge-std/Test.sol";
import {TokenPay7702} from "src/TokenPay7702.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {EIP7702Invoker} from "src/TokenPay7702.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// interface IERC20 {
//     function mint(address to, uint256 amount) external;
//     function balanceOf(address account) external view returns (uint256);
//     function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
// }

contract Token is ERC20 {
    constructor() ERC20("Token", "TKN") {}

    function mint(address user, uint256 value) external {
        _mint(user, value);
    }
}

contract TokenPay7702Test is Test {
    address eoa = address(0x122);
    uint256 dealAmount = 10 ether;

    TokenPay7702 implementation;
    Aave aave;
    Token token;

    EIP7702Invoker invoker;

    // function setUp() external {
    //     vm.deal(eoa, dealAmount);

    //     invoker = new EIP7702Invoker();

    //     implementation = new TokenPay7702(address(invoker));

    //     token = new Token();
    //     aave = new Aave(address(token));

    //     token.mint(eoa, 1000 ether);

    //     // ----------------------------------------------------
    //     // THE EIP-7702 DELEGATION MAGIC
    //     // ----------------------------------------------------
    //     // construct the 23-byte pointer bytecode: 0xef0100 + 20 bytes of implementation address
    //     bytes memory delegationBytecode = abi.encodePacked(hex"ef0100", address(implementation));

    //     // etch the pointer into the EOA's address slot
    //     vm.etch(eoa, delegationBytecode);
    // }

    // function test_SingleShot_ApproveAndDeposit() public {
    //     uint256 depositAmount = 500 ether;

    //     // prepare the underlying DeFi interaction calldata (Aave deposit)
    //     bytes memory aaveCalldata = abi.encodeWithSelector(Aave.deposit.selector, depositAmount);

    //     // package all execution arguments into the single-shot struct
    //     EIP7702Invoker.ExecutionArgs memory args = EIP7702Invoker.ExecutionArgs({
    //         token: address(token),
    //         spender: address(aave),
    //         amount: depositAmount,
    //         target: address(aave),
    //         data: aaveCalldata
    //     });

    //     // mock dummy authorization bytes for testing
    //     bytes memory mockAuth = abi.encodePacked(hex"00", hex"112233");

    //     // execute everything in a single call to the Invoker as the EOA
    //     vm.prank(eoa);
    //     invoker.executeSingleShot(mockAuth, eoa, args);

    //     // verify everything cleared in one transaction
    //     assertEq(aave.balances(eoa), depositAmount);
    //     assertEq(token.balanceOf(address(aave)), depositAmount);
    // }

    // function test_AaveErrorSingleShotApproveAndDeposit() public {
    //     uint256 depositAmount = 20_000_000 ether;
    //     token.mint(eoa, depositAmount);

    //     // prepare the underlying DeFi interaction calldata (Aave deposit)
    //     bytes memory aaveCalldata = abi.encodeWithSelector(Aave.deposit.selector, depositAmount);

    //     // package all execution arguments into the single-shot struct
    //     EIP7702Invoker.ExecutionArgs memory args = EIP7702Invoker.ExecutionArgs({
    //         token: address(token),
    //         spender: address(aave),
    //         amount: depositAmount,
    //         target: address(aave),
    //         data: aaveCalldata
    //     });

    //     // mock dummy authorization bytes for testing
    //     bytes memory mockAuth = abi.encodePacked(hex"00", hex"112233");

    //     // execute everything in a single call to the Invoker as the EOA
    //     vm.prank(eoa);
    //     vm.expectRevert(IAave.AmountOutOfRange.selector);
    //     invoker.executeSingleShot(mockAuth, eoa, args);

    //     // verify everything cleared in one transaction
    //     // assertEq(aave.balances(eoa), depositAmount);
    //     // assertEq(token.balanceOf(address(aave)), depositAmount);
    // }
}

interface IAave {
    error AmountOutOfRange();

    function deposit(uint256 amount) external;
}

contract Aave is IAave {
    IERC20 public token;
    mapping(address => uint256) public balances;

    constructor(address _token) {
        token = IERC20(_token);
    }

    function deposit(uint256 amount) external {
        balances[msg.sender] += amount;
        token.transferFrom(msg.sender, address(this), amount);

        if (amount > 10_000_000e18) {
            revert AmountOutOfRange();
        }
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "insufficient balance");

        balances[msg.sender] -= amount;
        token.transferFrom(msg.sender, address(this), amount);
    }
}
