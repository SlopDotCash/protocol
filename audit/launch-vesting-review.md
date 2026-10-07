# Launch, vesting, validation and yield security review

Baseline reviewed: `ac59fdff2c8603ad642f2e73772871e6e0b79807`.

This is a source and local-test review; it does not attest to deployed bytecode, existing grants, attestor behavior or economic security under every liquidity configuration.

## Findings

### LV-01 — Failed auctions have no recovery or relaunch path (High availability / asset lock)

`UmiaLBP.migrate` reads `lbpInitializationParams` at line 183. The pinned CCA refuses this for auctions below their minimum raise (`ContinuousClearingAuction.sol:134-137`). The only CCA unsold-token sweep is recipient-only (`:687-698`), and the recipient is the LBP. The LBP only invokes that sweep inside successful migration. Its own token sweep requires `migrated` (`UmiaLBP.sol:323-325`). Consequently the auction supply and the separate LP reserve are both unreachable following non-graduation. A zero-bid auction with zero required raise instead reaches `NoCurrencyRaised` (`:199`) and has the same outcome.

Precondition: an otherwise valid launch receives insufficient bids; no attacker privilege is needed. Bidder currency remains refundable under CCA rules, but the launch allocation cannot be reused. This is a permanent lock in the LBP lifecycle, not theft of bidder funds. Returning the tokens only to Venture is insufficient by itself: the unmigrated venture has no spot pool with which to create ordinary governance markets.

Regression: `test/security/LaunchAuditRecovery.t.sol`, using the real pinned CCA and LBP and no bids. Verifies final non-graduation, failed ordinary migration/sweep, rejected outsider CCA sweep, and recovery of all 1,000 launch tokens through the new fixed-recipient recovery function. A separate relaunch or treasury-rescue policy is still required to make an unsuccessful venture usable under ordinary governance.

### LV-02 — Milestone removal changes the price/cliff associated with a surviving award (Medium; potentially large premature payout)

The adapter's ladder is immutable by array index. `forward` previously forwarded all milestone amendments. MetaVesT `BaseAllocation.removeMilestone` (`lib/metavest/src/BaseAllocation.sol:263-271`) moves the final award into the removed slot. `UmiaTwapMilestoneCondition.checkCondition` reads the unchanged ladder using the new slot. Removing a low-threshold first milestone therefore makes a large final milestone claimable at the first milestone's lower price and/or earlier cliff. Appending a price milestone similarly produces an index with no registered threshold.

Precondition: authorized governance proposes and executes an ordinary milestone removal, with required grantee consent. This is not an unauthenticated governance bypass; the unintended consequence is altering an unrelated surviving milestone's release conditions. That prerequisite supports Medium severity despite potentially large grant impact.

Fix: adapter now rejects add/remove operations for allocations with a registered price program. Grants without a registered price program retain amendment support. Price-program restructuring must use atomic termination and reissue with a new ladder. Existing grants/adapters require redeployment or migration because the adapter is not upgradeable.

Tests: `LaunchAuditMilestone.t.sol` tests both rejected structural mutations and preserved non-price forwarding. `LaunchAuditVendorIndex.t.sol` demonstrates the actual vendored swap-pop plus early payout, using a fixed indexed-condition fixture to isolate the identity mismatch from oracle movement.

### LV-03 — Non-vesting grant types require authority actions the adapter cannot execute (Medium integration limitation)

The adapter accepts all `createMetavest` types. Token options require `TokenOptionAllocation.recoverForfeitTokens` (direct `onlyAuthority`) to recover unexercised forfeited tokens after termination. Restricted token awards require direct `RestrictedTokenAward.repurchaseTokens` (`onlyAuthority`). The adapter is the authority, can forward only to the controller, and explicitly cannot transfer authority away. Neither direct action has a corresponding controller forwarding method. These grant types therefore had incomplete recovery semantics under the original adapter. The concurrent fix adds treasury-only `recoverForfeitedOptions` and `repurchaseRestrictedTokens`, restricts them to allocations funded through this adapter with the expected type and original registered funding token, rejects liquidation, and clears exact temporary repurchase allowances before returning proceeds. Source peer review found no new authority expansion beyond the intended treasury; separate lifecycle test results are maintained by the parent reviewer.

### Validation proof front-running (coordinated with governance reviewer)

The original public `Reclaim.verifyProof` consumed a global proof identifier. A copied pending proof could therefore be consumed directly before `UmiaValidationHook` registered the user. Governance reviewer owns the verifier fix. The hook now retains its own consumed-identifier mapping so a repeated public verifier call cannot deny registration, while a previously used proof cannot undo `unregister`. Permissionless pre-registration still permits the victim bid through the already-verified path. `LaunchAuditValidationReplay.t.sol` covers these three properties.

## Individual coverage

| Contract | Review focus and result |
| --- | --- |
| UmiaLBP | Supply split, initializer authentication, sweep recipients, block-number domain, net currency raise, fee split, bootstrap allowances, migration atomicity and failed lifecycle. LV-01. |
| UmiaLBPFactory | Hub-only creation, caller-bound CREATE2 salt, totalSupply narrowing, SSTORE2 creation code. No independent unauthorized deployment/control issue found. |
| CCAExitHelper | Reads the CCA block-number domain; CCA refunds stored bid owner rather than helper/caller. No custody or approval surface. |
| UmiaValidationHook | Paired CCA caller gate, owner/sender binding, credential dispatch, monotonic step eligibility, nonce consumption, amount/domain binding, step/global caps, provider/identity handling. Reclaim composition issue above; other configuration risks below. |
| VentureVestingAuthority | Genesis ownership, two-step controller handoff, treasury binding, grant funding, allowances, clawback sweep, liquidation admin gating, immutable ladders, selector forwarding. LV-02 and LV-03. |
| UmiaTwapMilestoneCondition | Allocation-controller-authority resolution, cliff gate, full-window oracle fail-closed behavior, token order, Q96 reciprocal and saturation. No independent unauthenticated threshold overwrite found. Depends on oracle economic security. |
| YieldPositionGuardian | Owner-only exits, fixed venture recipient/onBehalf, ERC20 allowance boundaries, permissionless sweep, liquidation interaction. No arbitrary-recipient drain found. Original liquidation composition concern is addressed by the concurrent SimpleLiquidator patch taking custody of listed backing before snapshots; guardian allowances remain scoped to the former treasury. |
| Relevant interfaces and MetaVesT integration | ABI layout/selector consistency; BaseAllocation confirmation, deletion and withdrawals; controller authority/consent; vesting/option/restricted lifecycle. Coverage is integration-focused, not a separate exhaustive audit of every vendored dependency. |

## Cross-contract and rejected hypotheses

* Migration external callbacks do not expose a free reentrant migration: `migrate` is guarded, trusted VentureToken has no arbitrary recipient callback, and a revert rolls back treasury distribution, vault deployment and pool initialization.
* CCA net protocol fees are subtracted in `lbpInitializationParams`; the LBP does not erroneously require gross raised currency. The read requires a finalized checkpoint; anyone can checkpoint, so a missing checkpoint is recoverable operationally.
* Front-running `onTokensReceived` cannot select another auction configuration; configuration and recipients are validated. Canonical factory creation occurs atomically with token transfer and initialization through the Hub.
* Canonical native-currency launches are rejected by `Venture.initialize` (`moneyToken == address(0)`), so the LBP's ERC20-only bootstrap does not create a reachable native-currency trap through normal Hub creation.
* A hostile caller cannot make CCAExitHelper receive another bidder's refund. The CCA records its owner independently of `msg.sender`.
* Guardian operator input can select arbitrary external protocols, but supported exit functions have fixed treasury destinations and do not create arbitrary ERC20 approvals. This did not produce a standalone operator drain. Liquidation is a separate concern.
* Registered ladder thresholds/cliffs cannot be overwritten by strangers. A fake allocation/controller can only spoof its own condition result, not mutate a real allocation's controller or registry.
* Relative thresholds read live CCA clearing price, but real pool availability begins only after the auction ends and migrates, so the condition cannot normally release against a transient pre-end clearing price.

## Remaining design/operational constraints

* A proof with no `extractedParameters` skips the sybil gate by design. The identity hash includes the entire raw JSON object; semantic identity uniqueness therefore depends on trusted attestors producing canonical, stable fields. No confirmed attacker ability to obtain differently serialized valid proofs was established here; do not label this a proven critical exploit.
* Unpaired hooks and disabled/unconfigured steps are open by design. Configure and pair before bidding opens.
* Per-step zk caps count only while the cap is nonzero, unlike global caps. Enabling a cap mid-step is not retroactive to uncapped volume. Treat as documented configuration semantics or change accounting if retroactive caps are expected.
* Approved money tokens must have compatible exact-transfer, non-rebasing behavior; approval of arbitrary ERC20 implementations is a trusted registry decision.
* Hub registry owner, vesting administrator and governance have explicitly powerful roles. Their intended authority alone is not an exploit.
* TWAP windows reduce instantaneous manipulation but do not guarantee economically unmanipulable prices in thin pools.

## Validation status

Focused Forge command: `forge test --match-path 'test/security/LaunchAudit*.t.sol' --out out-launch-audit --cache-path cache-launch-audit -vv`.
Initial attempt was blocked by uninitialized nested pinned dependencies; parent restored them. The first compiled snapshot passed 62 tests (1 actual CCA lock reproducer, 1 actual vendored milestone-reindex demonstration, and 60 authority tests including 3 structural-mutation regressions). A rerun for the latest recovery/hook changes is in progress; final current-tree results will replace this paragraph. The initial pass is not evidence for source changed afterward.

## Group review of concurrent fixes

Reviewed the updated `ConditionalMarketOracle`, `UmiaMarketCore` update ordering, `GovernanceActions` liquidation transition, and `SimpleLiquidator` escrow custody as a second reader.

**Outstanding oracle cadence dependence:** the new clamp limits the accepted endpoint according to elapsed time but accrues that endpoint over the entire elapsed interval. For a seed price of 1 and a raw price held at 2.5 for 60 seconds, one update at 60 seconds accrues 150 price-seconds (TWAP 2.5). Sixty one-second updates accrue approximately 98.974 price-seconds (TWAP 1.64957). At a two-second block cadence the same effect remains approximately 50%. Dust reserve-changing operations can choose the cadence independently for each proposal. The same-second ratchet is prevented, but the cumulative score is not invariant to economically negligible updates and can differ enough to change a close winner. This is an arithmetic/source review with a numerical calculation, not a newly run chain simulation. Exact integration of a persistent accepted-price ramp would remove this dependency; any alternative must specify and test its cadence semantics.

**Liquidation custody review:** no additional normal-path correctness issue found in the combination of burning treasury-held venture tokens before determining claimable supply and moving listed claim backing to the liquidator before recording balances. This prevents both post-snapshot circulation of excluded claim tokens and post-snapshot use of old treasury ERC20 approvals against escrowed backing. Native payouts use the liquidator's new receive path and direct transfers; ERC20 snapshots use actual received balances. Duplicate assets and malformed native-token entries are already rejected by governance-plan validation. Both initialization and claiming are guarded against reentrancy. Guardian approvals over the Venture cannot spend assets now held by the liquidator. Omitted assets, later donations/yield accrual, and transfer/rebase behavior outside the supported token assumptions remain inventory/asset-model limitations, not evidence that the repaired escrow is fully universal.

## Consolidated follow-up

The primary review includes subsequent exact-integration oracle correction, default spot history provisioning, fail-closed token identity migration and pending-execution ordering changes. Final remediation and validation supersede intermediate observations in [SECURITY_REVIEW.md](SECURITY_REVIEW.md) and [VALIDATION.md](VALIDATION.md).

## LV-04 — Restricted collateral can alias freely claimable repurchase currency (High)

The pinned `RestrictedTokenAward.claimRepurchasedTokens` at `lib/metavest/src/RestrictedTokenAllocation.sol:152` transfers the entire payment-token balance to the grantee. Controller creation accepts the same token as both allocation collateral and payment currency. The grantee can therefore take all collateral before vesting starts. This is a concrete supported-configuration bypass, rather than a authority-key compromise. The adapter rejects aliasing in common post-create registration, atomically covering every supported create path. Recovery registration also records the original funding token, preserving recovery of non-venture genesis grants. Current regression and validation evidence is maintained in the consolidated ledger.
