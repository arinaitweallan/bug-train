// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
