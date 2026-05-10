// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title WithdrawalQueue
contract WithdrawalQueue {
    struct WithdrawalRequest {
        address requester;
        uint256 amount;
        uint256 requestTime;
        bool processed;
    }

    WithdrawalRequest[] public queue;

    uint256 public processedCount;
    uint256 public constant LOCK_PERIOD = 7 days;
    address public manager;

    constructor() {
        manager = msg.sender;
    }

    /// @notice Submit a new request
    function requestWithdrawal(uint256 amount) external {
        queue.push(WithdrawalRequest(msg.sender, amount, block.timestamp, false));
    }

    /// @notice Process pending operations
    function processWithdrawals(uint256 maxCount) external {
        require(msg.sender == manager, "Not manager");

        uint256 processed = 0;
        uint256 i = processedCount;

        while (i < queue.length && processed < maxCount) {
            if (block.timestamp >= queue[i].requestTime + LOCK_PERIOD) {
                queue[i].processed = true;
                processedCount++;
                processed++;
            }

            unchecked {
                i++;
            }
        }
    }

    /// @notice Compact
    function compact() external {
        require(msg.sender == manager, "Not manager");

        uint256 writeIdx = 0;
        for (uint256 readIdx = 0; readIdx < queue.length; readIdx++) {
            if (!queue[readIdx].processed) {
                if (writeIdx != readIdx) {
                    queue[writeIdx] = queue[readIdx];
                }

                unchecked {
                    writeIdx++;
                }
            }
        }

        uint256 removed = queue.length - writeIdx;

        for (uint256 k = 0; k < removed; k++) {
            queue.pop();
        }

        unchecked {
            processedCount -= removed;
        }
    }

    // cancelWithdrawal sets processed=true AND increments processedCount. compact removes all processed=true entries and
    // subtracts the removed count from processedCount. What if some processed entries were cancelled rather than actually
    // processed?

    // If 3 entries are in the queue: 1 processed by processWithdrawals, 2 cancelled. processedCount = 3. compact removes all 3
    // (removed = 3). processedCount -= 3 = 0. This case is OK. But what if compact is called after processWithdrawals but
    // BEFORE cancelWithdrawal adjusts processedCount?

    /// @notice Cancel a pending operation
    function cancelWithdrawal(uint256 index) external {
        require(queue[index].requester == msg.sender, "Not requester");
        require(!queue[index].processed, "Already processed");

        queue[index].amount = 0;
        queue[index].processed = true;

        unchecked {
            processedCount++;
        }
    }

    // read all the code to get a better understanding

    /// @notice Get pending count
    function getPendingCount() external view returns (uint256) {
        return queue.length - processedCount;
    }
}

// BUG
// The compact function subtracts 'removed' from processedCount inside unchecked{}. But cancelWithdrawal increments
// processedCount for cancelled entries, which compact also removes (they have processed=true). If there are cancelled entries,
// processedCount includes both truly-processed AND cancelled entries, but 'removed' counts all processed=true entries. The
// subtraction can underflow when cancelled entries are compacted.

// IMPACT
// When processedCount underflows to a huge value inside unchecked{}, getPendingCount returns queue.length - hugeNumber, which
// underflows to a huge uint256. Any logic depending on pending count is broken. processWithdrawals starts iterating from a
// massive processedCount offset, skipping all legitimate queue entries.

// INVARIANT
// processedCount must always equal the actual number of processed entries in the queue. processWithdrawals must not increment
// processedCount for entries that are already marked as processed.

// WHAT BREAKS
// The processWithdrawals function checks only the time condition (block.timestamp >= requestTime + LOCK_PERIOD) but does NOT
// check the processed flag. When cancelWithdrawal marks an entry as processed=true and increments processedCount, a subsequent
// processWithdrawals call encounters that cancelled entry, the time check passes, and it increments processedCount again for
// the same entry. This double-counting corrupts processedCount, causing permanently stuck withdrawals and getPendingCount()
// reverts.

// EXPLOIT PATH
// 1. Alice submits 3 withdrawal requests [0,1,2]. processedCount = 0
// 2. Alice cancels entry 2 via cancelWithdrawal(2). Entry 2 marked processed=true, processedCount = 1
// 3. Time passes beyond LOCK_PERIOD. Manager calls processWithdrawals(10)
// 4. Loop starts at i = processedCount = 1. Entry 0 is NEVER examined
// 5. i=1: not processed, time OK. Marked processed=true, processedCount = 2
// 6. i=2: already cancelled (processed=true), but time check passes. processedCount incremented to 3 (DOUBLE COUNT)
// 7. Manager calls compact(). Entries 1,2 are processed. removed=2, processedCount = 3 - 2 = 1. Queue = [entry0]
// 8. Manager calls processWithdrawals(10). Starts at i = processedCount = 1, but queue.length = 1. Loop doesn't execute
// 9. Entry 0 (Alice's first withdrawal) is permanently stuck — can never be processed
// 10. If Alice cancels entry 0 and compact runs again: processedCount = 2 - 1 = 1, queue.length = 0. getPendingCount() reverts: 0 - 1 underflows.

// WHY MISSED
// Auditors see the unchecked block in compact() and focus on whether removed can exceed processedCount there. They verify the
// subtraction arithmetic but miss that processWithdrawals silently double-counts cancelled entries because it only checks the
// time condition, not the processed flag. The cancel and process functions independently modify processedCount with no
// coordination.

