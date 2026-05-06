// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Order Cycling Grief Drains Counterparty Collateral Window

/// @title OrderBook
contract OrderBook {
    struct Order {
        address maker;
        uint256 collateral;
        uint256 amount;
        bool active;
    }

    IERC20 public token;
    Order[] public orders;

    mapping(address => uint256) public activeOrderCount;
    uint256 public constant MAX_ACTIVE_ORDERS = 100;

    constructor(address _token) {
        token = IERC20(_token);
    }

    /// @notice Create a new entry or position
    /// @param collateral Collateral token address
    /// @param amount Token amount
    function createOrder(uint256 collateral, uint256 amount) external {
        require(activeOrderCount[msg.sender] < MAX_ACTIVE_ORDERS, "Too many orders");
        require(token.transferFrom(msg.sender, address(this), collateral), "Transfer failed");

        orders.push(Order(msg.sender, collateral, amount, true));
        activeOrderCount[msg.sender]++;
    }

    /// @notice Cancel a pending operation
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        require(order.maker == msg.sender, "Not maker");
        require(order.active, "Not active");

        order.active = false;
        activeOrderCount[msg.sender]--;
        require(token.transfer(msg.sender, order.collateral), "Transfer failed");
    }

    /// @notice Fill order
    function fillOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        require(order.active, "Not active");
        require(msg.sender != order.maker, "Cannot self-fill");

        order.active = false;
        activeOrderCount[order.maker]--;

        require(token.transferFrom(msg.sender, order.maker, order.amount), "Transfer failed");
        require(token.transfer(msg.sender, order.collateral), "Transfer failed");
    }

    /// @notice Get order count
    function getOrderCount() external view returns (uint256) {
        return orders.length;
    }
}

// INVARIANT
// Order creation must have a non-trivial cost or cooldown to prevent free cycling that degrades the order book

// WHAT BREAKS
// An attacker repeatedly calls createOrder(1e18, 1e18) then cancelOrder(id) in rapid succession. Each cycle adds a dead Order
// entry to the orders array (cancelled entries are deactivated but never deleted). After 100,000 cycles, the orders array has
// 100,000 entries. Any on-chain iteration over orders to find active ones (e.g., a batch fill function or view function)
// becomes prohibitively expensive. Off-chain indexers processing the array are flooded with noise.

// EXPLOIT PATH
// 1. Attacker approves 1e18 tokens to contract
// 2. In a loop (or via a helper contract), attacker calls createOrder(1e18, 1e18) then cancelOrder(orderId) 1,000 times per block
// 3. Each cycle: token transferred in then out (net cost = 0 tokens, only gas)
// 4. After 100 blocks: orders.length = 100,000. All entries have active = false
// 5. Legitimate maker creates order at index 100,001
// 6. Taker scanning from index 0 to find active orders must read 100,000 dead entries first. Gas for iterating: 100,000 * 2,100 (SLOAD) = 210M gas
// 7. No on-chain function can iterate the full order book. Legitimate orders are effectively hidden in a sea of dead entries.

// WHY MISSED
// The MAX_ACTIVE_ORDERS limit looks like sufficient protection against spam. Auditors verify the per-user cap but miss that
// cancelled orders still occupy array space permanently. The attack uses only 1 active order at any time (well within the limit)
// but generates unlimited dead entries.
