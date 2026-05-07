// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Desynchronized Withdrawal Counter Locks Vault Funds

/// @title WithdrawalQueue
contract WithdrawalQueue {
    IERC20 public asset;

    struct Request {
        address user;
        uint256 amount;
        uint256 requestId;
    }

    Request[] public requests;
    uint256 public nextRequestId;
    uint256 public lastFinalizedId;

    mapping(address => uint256) public deposits;

    uint256 public totalDeposits;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    /// @notice Deposit tokens into the contract
    function deposit(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        deposits[msg.sender] += amount;
        totalDeposits += amount;
    }

    // deposits[0x12] = 100
    // totalDeposits = 12000
    /// @notice Submit a new request
    function requestWithdrawal(uint256 amount) external {
        require(deposits[msg.sender] >= amount, "Insufficient");

        deposits[msg.sender] -= amount;
        totalDeposits -= amount;
        requests.push(Request(msg.sender, amount, nextRequestId)); // requestId = 10
        nextRequestId++; // nextRequestId = 11
    }

    /// @notice Finalize the current state
    function finalize(uint256 count)
        external /**
                  * onlyOwner
                  */

    {
        uint256 end = lastFinalizedId + count;
        if (end > nextRequestId) end = nextRequestId;
        lastFinalizedId = end;
    }

    /// @notice Claim accumulated rewards
    function claim(uint256 requestIndex) external {
        Request storage req = requests[requestIndex];
        require(msg.sender == req.user, "Not owner");
        require(req.requestId < lastFinalizedId, "Not finalized");
        require(req.amount > 0, "Already claimed");

        uint256 amount = req.amount;
        req.amount = 0;
        require(asset.transfer(msg.sender, amount), "Transfer failed");
    }

    /// @notice Get queue length
    function getQueueLength() external view returns (uint256) {
        return requests.length;
    }
}

// INVARIANT
// Every finalized withdrawal request must be claimable by its owner

// WHAT BREAKS
// The finalize function sets lastFinalizedId = end directly. If the operator calls finalize(5) when only 3 requests exist,
// lastFinalizedId = min(5, 3) = 3. Later, 2 more requests are added (IDs 3 and 4). The operator calls finalize(1) intending
// to finalize request 3, but lastFinalizedId goes from 3 to 4, only finalizing ID 3. Request ID 4 is stuck. The operator must
// track exact counts precisely. Any miscalculation permanently blocks claims for skipped IDs because finalize only moves
// forward.

// EXPLOIT PATH
// 1. Users create 3 withdrawal requests: IDs 0, 1, 2. nextRequestId = 3
// 2. Operator calls finalize(3). lastFinalizedId = 3. All 3 are claimable
// 3. User creates request ID 3 (amount = 500e18). nextRequestId = 4
// 4. Operator calls finalize(0) by mistake (count = 0). lastFinalizedId stays at 3
// 5. User calls claim(3) for requestIndex 3. req.requestId = 3. require(3 < 3) fails
// 6. Operator realizes the mistake but has no way to finalize exactly request 3 without also advancing past 4
// 7. If another request (ID 4) is added before finalize, the operator might over-finalize or under-finalize
// 8. With repeated miscounts, multiple requests become permanently unclaimable. 500e18 tokens locked.

// WHY MISSED
// The sequential ID and array index alignment looks correct under normal flow. The desync only manifests when finalize counts
// do not perfectly match the pending request batch, which is an operational error that auditors may consider out of scope.
