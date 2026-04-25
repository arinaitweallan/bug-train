1. All state variables participating in the first operational cycle must be explicitly initialized, including historical previous-epoch data.
2. Only the legitimate deployer can initialize the bridge registry and set the guardian and relayer roles.
3. The claim window duration must correctly reflect the intended number of days in seconds.
4. Deterministic addresses for bridged tokens must include chain-specific and deployer-specific entropy to prevent cross-chain address collisions.
5. Reinitializer versions must increment sequentially (1, 2, 3...) with no gaps, ensuring every migration step executes exactly once.
6. The implementation contract behind a proxy must never be initializable independently.
7. The interest rate must be set to a valid non-zero value at deployment so that all borrows accrue protocol fees.
8. Pool initialization price must be validated against a trusted oracle or restricted to authorized callers to prevent manipulation.
9. Clone creation and initialization must happen atomically in the same transaction to prevent front-running.
10. Staking should not be possible before the reward distribution period begins, preventing disproportionate reward capture.
11. All state variables in an upgradeable contract must be set in the initialize function, not the constructor, to affect the proxy's storage.
12. User deposits should not be accepted before the system start time to ensure fair reward distribution from the beginning.
13. The initialize function must execute exactly once and only by the authorized deployer.
14. All inherited initializable contracts must have their __init() functions called during initialization to activate their protections.
15. Each step in the bootstrap sequence must be callable only by the authorized deployer and only when prerequisites are met.
16. Only the intended deployer should be able to initialize the proxy and claim ownership of the staking pool.
17. The deployer must be set as owner during initialization so that admin functions are accessible.
18. Upgradeable contract storage layouts must be append-only; new variables must be placed after all existing variables to preserve slot assignments.
19. A wallet's configuration (owner, guardian, daily limit) must only be set during initial creation and never overwritten without proper authorization.