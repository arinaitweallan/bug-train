1. The recipient on the destination chain must always be the sender (msg.sender) or an explicitly authorized delegate, not a user-controlled parameter.
2. Only the authorized deployer should be able to initialize the contract and set admin/relayer roles.
3. Privileged admin functions that wire external dependencies must either (a) validate the dependency's identity on-chain, or (b) be guarded by a multi-sig + timelock so the misconfiguration window is reviewable before execution.
4. Only the governor should be able to trigger execution of module actions, and delegatecall targets must not be able to modify critical governance state.
5. During emergency pause, all state-changing user operations including liquidation must be halted to prevent exploitation of frozen market conditions.
6. The withdraw function accepts an arbitrary owner address parameter but never checks that msg.sender == owner or that msg.sender is approved by the owner.
7. Only the authorized rebalancer should be able to set reserve values during rebalancing.
8. Critical vault management functions must be callable by at least one authorized address after deployment.
9. Only the auction seller should be able to cancel their own auction.
10. Only the nonce owner can invalidate their own nonce to cancel pending orders.
11. Only the owner or operator should be able to manage pools in the registry.
12. Administrative functions must verify the direct caller (msg.sender), not the transaction originator (tx.origin).
13. A user's lock expiry can only be extended by their own actions or with their explicit consent.
14. Only the authorized staking contract can mint new reward tokens.