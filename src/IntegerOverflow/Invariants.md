1. The _pow(totalSupply, EXPONENT) must always fit within uint256 for the bonding curve to remain functional.
2. The intermediate product user.amount * accRewardPerShare must always fit within uint256 (< 2^256) for all users.
3. The sum of all balances must equal totalSupply. No balance should wrap around during transfers.
4. Collateral and debt value calculations must never revert due to overflow, especially during extreme market conditions when liquidations are critical.
5. When marketId wraps to 0, the Market struct at markets[0] is overwritten. The original market 0's liquidity is lost, and the pairToMarket mapping for the old pair still points to ID 0 but now returns the wrong market data.
6. feeGrowthGlobal must always be >= seller.feeGrowthSnapshot for every active seller at the time of fee claim.
7. Payout must never exceed the trader's margin. If PnL is more negative than margin, payout must be zero (loss exceeds collateral).
8. Each leaf index in the Merkle tree must be used exactly once. No leaf may be overwritten after deposit.
9. user.rewardDebt must always equal the full precision value of (stakedAmount * accRewardPerShare / 1e12) at the time of the last state change.
10. processedCount must always equal the actual number of processed entries in the queue. processWithdrawals must not increment processedCount for entries that are already marked as processed.
11. yieldAccumulator * max_deposit must fit within uint256 to ensure _claimYield never overflows.
