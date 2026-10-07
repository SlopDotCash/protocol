# Umia protocol security review and remediation

Date: October 6, 2026. Repository: [umiafinance/protocol](https://github.com/umiafinance/protocol). Initial review baseline: `ac59fdff2c8603ad642f2e73772871e6e0b79807`.

## Assessment

The baseline had material weaknesses in oracle scoring, liquidation isolation, failed launch recovery, and vesting integrations. The coordinated review also examined concurrent token-pinning and execution-order changes and found weaknesses in their initial migration and pause handling. The source remediation addresses these mechanisms and adds regression coverage. No conclusion of “100% secure” follows from this review, passing tests, or any number of agent reviews.

This is an engineering security review with local and hosted test validation. It is not an independent professional audit certificate, formal proof of the complete system, verification of live contract bytecode, or an economic guarantee. Source changes pushed to GitHub do not update deployed immutable contracts or proxies.

## Scope and method

All 52 first-party Solidity files under `src/` and all 14 Solidity deployment/upgrade scripts were assigned or reviewed. The source includes interfaces, shared libraries, and the vendored Reclaim adaptation under `src/reclaim`. External dependencies were pinned and examined where their behavior affected first-party integrations; the approximately 1,500 dependency Solidity files were not individually audited.

Three agents reviewed individual contracts in market/accounting, governance/treasury, and launch/vesting groups. The primary reviewer covered the spot vault, hook, oracle library, deployment and tooling. A second pass composed launch/migration, price observation, virtual accounting, governance execution, liquidation, vesting, and identity consumption. Peer review rejected the first elapsed-time oracle repair because its cumulative still depended on sampling cadence; it also identified the reversible-pause loophole in the concurrent execution-order change.

Suspected findings were assessed for authority, capital, timing, asset compatibility and configuration prerequisites. Critical/high requires meaningful asset loss, wrong consequential governance selection or persistent asset lock. Powerful documented owner or governance authority alone is not a vulnerability. Regression examples using mocked boundaries are identified as such; pinned real CCA and MetaVesT fixtures exercise their integration behavior directly.

Detailed individual coverage and rejected hypotheses are in:

- [Decision market review](markets-review.md).
- [Governance, treasury and Reclaim review](governance-review.md).
- [Launch, vesting and validation review](launch-vesting-review.md).
- [Spot and deployment review](spot-deployment-review.md).

## Findings

| ID | Final assessment | Weakness | Remediation |
| --- | --- | --- | --- |
| H-01 | High | A transient reserve displacement left an accepted conditional price above restored spot and credited that phantom value across a quiet market. | Fixed-rate elapsed-time slew with exact ramp/plateau integration and fractional carry. |
| H-02 | High, standing-approval prerequisite | Liquidation assets remained spendable through old treasury approvals; treasury tokens excluded from the denominator could re-enter circulation and overclaim. | Retire treasury claim tokens before snapshot; escrow listed backing in the liquidator before snapshot. |
| H-03 | High availability | Failed or zero-raise CCA launches permanently locked the reserve and unsold launch supply. | Finalize the auction and recover unsold supply to the fixed Venture treasury, preserving bidder refunds. |
| H-04 | High availability; adapter integration | Option/restricted grants needed direct authority operations that the adapter could not perform, stranding recoverable collateral. | Treasury-only, registered-allocation/type-bound recovery and repurchase methods with exact temporary allowances. |
| H-05 | High, own-venture upgrade prerequisite | Live asset getters on an upgradeable Venture could redirect shared market/stake escrow payouts toward another venture’s token. | Pin original assets in Hub at creation; fail closed for unpinned legacy ventures; migrate from immutable vault assets or owner-verified creation records. |
| H-06 | High, accepted same-token grant configuration | Restricted awards could freely pay out all vesting collateral as repurchase currency when both token addresses matched. | Reject that alias atomically in the common allocation-registration path. |
| M-01 | Medium, authorized amendment + consent | MetaVesT swap-pop milestone removal reassigned an unchanged price/cliff ladder to a different award. | Reject structural amendments of registered price ladders; terminate and reissue instead. |
| M-02 | Medium availability | Permissionless verification consumed a proof globally before its application could register the user. | Repeatable signature verification; replay consumption retained within each hook. |
| M-03 | Medium; retired-key compromise can have High impact | Epoch rotation did not bound the timestamps signed by retired witnesses or provide explicit revocation. | Validate epoch/time boundaries and add permanent owner-controlled revocation. |
| M-04 | Medium conditional identity hardening | Substring context extraction selected nested user fields before the authoritative top-level fields. | Match only top-level JSON keys while respecting string/escape and nesting state. |
| M-05 | Medium, approved nonstandard-token prerequisite | Requested deposits could create virtual/share credit larger than received backing. | Assert exact received balance changes before crediting split positions or vault shares. |
| M-06 | Medium availability | The 100-slot default spot ring could lose the 30-minute history and deny settlement/withdrawal after cheap frequent observations. | Bootstrap 2,048 fine slots and allocate them lazily, avoiding eager storage gas limits. |
| M-07 | Medium execution consistency | Older unexecuted winning actions could run against treasury state used by a newer market; a reversible pause initially bypassed the new ordering guard. | Block a new market until the old payload executes or expires; a pause stays pending; enforce a seven-day execution window. |
| L-01 | Low in ordinary configured ranges | An intermediate reserve × Q112 product could overflow although the final price was representable. | Full-precision ratio division with saturation before overflow. |
| L-02 | Low reproducibility/tooling | Standalone checkout lacked required dependencies, hosted validation, and current ABI exports. | Restore exact pinned sources, add hosted test/size/license/ABI checks, and export corrected interfaces. |

Commit prefixes reflect the conservative severity at remediation time. Some integration-only findings were reassessed Medium after confirming the required governance/consent conditions; the detailed reports describe those prerequisites. No independently demonstrated Critical finding is asserted.

### H-01: Conditional oracle contamination and cadence dependence

Affected baseline: `src/periphery/ConditionalMarketOracle.sol`, consumed by `UmiaMarketCore._beforeSwap/_syncOracle` and `SettlementLib.settle`.

The old 2.5×/0.4× clamp was applied per update. A trader could hold a displaced price across a few timestamps, advance the accepted anchor, restore raw reserves in the same timestamp, and leave the proposal quiet. A later settlement applied only one downward clamp and credited the still-elevated accepted value across nearly the entire remaining window. This can select the wrong existing signed proposal, including a proposal carrying treasury actions.

The trader needs a signed/open market, temporary capital, fees and a quiet proposal. They do not acquire authority to submit an unsigned governance payload. The displacement spans timestamps, so this is not established as a single-transaction flash-loan attack. A configured execution delay and guardian can mitigate consequences operationally but do not repair scoring.

The first repair used elapsed-time bounds but multiplied the endpoint by the whole interval. Peer review showed identical raw prices produced TWAP 2.5 with one update versus approximately 1.65 with 60 updates. That repair was replaced. The final model fixes a per-proposal absolute slew rate at `ceil(seedPriceX112 / 40)`, integrates its linear ramp and target plateau, and carries fractional area with denominator `2 * rate`. This makes partitioning a constant-price interval exactly additive.

Tests cover independent start/target/carry partition identities, both directions, unfinished and completed ramps, extreme ratios, read/write agreement and end freeze. All future reserve mutations must retain the existing update-before-mutation contract. The chosen smoothing rate is a policy change and still requires economic calibration for intended market sizes.

### H-02: Liquidation backing and excluded claim supply

Affected baseline: `GovernanceActions._executeLiquidation`, `SimpleLiquidator.initialize/claim`, and Venture’s terminal authorization.

Snapshotting assets in the treasury did not revoke ERC20 allowances. A previously approved spender could transfer backing after the snapshot and make later claims fail. Separately, subtracting treasury-held venture tokens from the denominator without burning them left live claim tokens that could be pulled into circulation through a standing approval and redeemed against the reduced denominator.

The repair first redeems treasury LP shares, burns treasury-held claim tokens, computes outstanding supply, authorizes the liquidator, and atomically transfers listed backing into liquidator custody. Claims burn user tokens and pay from that custody. Transfer-fee input backing is snapshotted at its received balance; this does not make rebasing, sender-extra-fee or blacklistable tokens universally safe.

Tests cover standing approvals for both claim tokens and payout assets, paused claim tokens, native assets, transfer fees, zero-circulating rollback and fuzzed proportional conservation. Custom liquidators still require equivalent isolation. Late/unlisted assets and external positions must be handled before terminal liquidation.

### H-03: Failed launch allocation

Affected baseline: `UmiaLBP.migrate` and successful-migration-only sweeps, composed with the real pinned CCA.

A non-graduated CCA rejects liquidity initialization parameters, so ordinary migration never reaches unsold-token sweeping. A zero-minimum/zero-bid auction formally graduates but also cannot migrate without currency. Both paths previously stranded launch supply.

Recovery checkpoints the final auction and permits the failed/zero-raise cases only after the migration delay. It sweeps unsold tokens as the authorized CCA recipient and transfers the entire available launch balance to the fixed Venture. Successful positive raises remain protected. Bidder currency remains in the CCA for refunds.

The tests use the pinned CCA for insufficient bids, empty zero-minimum graduation, successful-raise rejection, delayed eligibility and refund preservation. Custody recovery does not automatically relaunch a venture: an unmigrated venture lacks ordinary spot-based governance. Its existing trusted Hub-owner/executor mechanism must coordinate a reviewed recovery or relaunch plan. No arbitrary launcher withdrawal privilege was added.

### H-04 / M-01: Vesting adapter lifecycle

Affected: `VentureVestingAuthority`, `UmiaTwapMilestoneCondition`, and pinned MetaVesT controller/allocation implementations.

Option collateral recovery and restricted-token repurchase are direct allocation authority calls. The adapter held that authority but could originally forward only through the controller. New helpers limit recovery to the bound treasury, allocations funded through that adapter, the expected allocation type and recorded funding token, and non-liquidating operation. Genesis can fund other-token allocations, so their recovery uses the same recorded-token identity rather than silently leaving them unsupported. Option recovery waits strictly beyond the exercise deadline so it cannot race an exercise at that deadline. Repurchase grants only the exact payment allowance, clears it and sweeps remaining balances to treasury.

A separate milestone problem involved MetaVesT removal moving the final award into the removed array index. An immutable indexed ladder then applied a different threshold/cliff to that surviving award. Since authorized governance and required consent are prerequisites, this is Medium rather than a public authorization bypass. The adapter blocks add/remove operations for registered price programs; atomic termination and reissue provides a supported restructuring route.

Real allocation tests cover recovery deadlines, exercised-but-unwithdrawn collateral, repurchase payment, residual allowances, registration/type/authentication, non-venture genesis collateral and liquidation guards. A real vendor swap-pop fixture shows the identity mismatch; the vendor itself was not modified.

### H-06: Repurchase currency aliased to vesting collateral

The pinned `RestrictedTokenAward.claimRepurchasedTokens` pays its entire `paymentToken` balance to the grantee without a vesting or repurchase-history check. The controller accepts `paymentToken == allocation.tokenContract`. In that configuration, immediately after funding, all supposedly locked vesting collateral is also freely claimable repurchase currency. A grantee can take the entire balance before vesting starts or milestone conditions pass.

This needs a funded restricted award with the same two token addresses; it does not require a forged proof, governance takeover or manipulation of the pool. The adapter now rejects it in `_emitAllocationFunded`, which is shared by genesis, ordinary forward creation and replacement-grant creation. The transaction reverts atomically, including controller creation, funding and allowances. A real pinned-vendor fixture demonstrates the early payout; an adapter fixture verifies rejection and full funding rollback. Direct users of the vendored allocation outside this adapter still need the same configuration restriction.

### H-05: Shared escrow asset identity

The Hub’s original `ventureTokenById` and `ventureMoneyTokenById` read live upgradeable Venture getters. An authorized implementation change for one venture could change the asset selected by split/merge, settlement claims, fees and stake withdrawals while those contracts held assets for other ventures. Per-venture governance authority must not become authority over pooled escrow assets.

New ventures pin both assets at creation. Legacy unpinned getters fail closed. The one-argument migration obtains immutable vault assets; the explicit owner migration accepts independently verified creation addresses and checks an existing vault for agreement. Zero/noncontract or equal token pairs are rejected, and pinned records cannot be overwritten. Settlement approvals also use the canonical getters.

The mappings consume two slots from the pre-existing Hub gap. Legacy pinning must accompany deployment of the new Hub implementation before resuming escrow activity. Blindly pinning current live Venture getters would preserve the original vulnerability, so the migration deliberately avoids that fallback. Regression tests exercise changed Venture getters, failed legacy reads and verified/invalid migration.

### M-02 / M-03 / M-04: Reclaim and application identity

Proof signatures are checked on every verification, even when an identifier was verified previously. Public verification history is informational, while each validation hook enforces its own consumption policy. Reusing a consumed proof cannot undo unregister, and permissionless preregistration does not grant another user bid authority.

Retired epochs reject fresh out-of-window proofs, and explicit revocation rejects even backdated signatures. The current epoch’s advisory cache end was not turned into an unexpected one-day expiry. Compromised epochs require revocation, not rotation alone, and already-registered identities need an application response separately.

The context extractor now locates top-level keys while skipping nested objects, arrays and string content. This prevents the demonstrated parser ambiguity. Full semantic identity canonicalization and the deployed attestor’s schema remain outside this parser patch. No verified production attestor forgery is claimed.

### M-05 / M-06 / M-07: Accounting, history and execution

Deposits now fail atomically unless received balance changes equal credited amounts. This protects against underfunded credits; compatible non-rebasing tokens are still required.

The new fine ring holds 2,048 observations. At one write per distinct second it retains the 1,800-second window with margin. Growth leaves unused slots uninitialized, while write initializes one on demand; lookup ordering and oldest-observation fallback still rely on `initialized`. This shifts roughly 15,000 additional storage gas to each first-use slot instead of forcing thousands of eager writes into bootstrap. Coarse history still needs provisioning for long milestone windows. Existing immutable pools need separate capacity/history recovery.

For execution ordering, an unexecuted non-empty winning payload blocks a new market until it executes or passes its snapshotted delay plus seven days from settlement. A reversible breaker cannot release that obligation. Expired consequential execution is rejected, and a superseded legacy winner cannot revive after a newer market has replaced its active pointer. Registry replacement remains a privileged migration requiring pending execution and claim obligations to be reconciled; retaining the same core address through UUPS is the recommended path.

## Remaining security boundaries

1. **Live deployment is unverified.** No mainnet transaction, upgrade or redeployment was broadcast. Map each affected deployed contract to its upgrade/redeployment path and verify bytecode, registry pointers, ownership and storage before use.
2. **Trusted roles are powerful.** Hub owner, market signer, beacon governance, per-venture governance, vesting administrator and emergency operator need appropriate key custody and operational review. New checks do not remove intended treasury CALL/upgrades or owner registry control.
3. **Economic manipulation remains possible.** Time filters and full-range liquidity do not establish a minimum manipulation cost or sufficient price discovery. Thin pools, concentrated token ownership, capital advantage and deliberately quiet markets need separate economic stress testing.
4. **Token restrictions remain.** Negative rebases, freezes, sender-side fees and malicious callbacks can impair availability. Fee-transfer rejection and received-balance snapshots are bounded defenses. Governance must approve compatible assets.
5. **Liquidation snapshots are terminal and finite.** Omitted assets, late deposits, inaccessible contract-held claim tokens and external positions require a complete wind-down plan. Claims across multiple assets are atomic; one failing asset can block a claimant.
6. **Stateful registry replacements require migration.** A fresh conditional oracle does not contain old proposal history. A new market core does not contain old virtual balances or pending execution. Administrative replacement must preserve or finish these obligations.
7. **Existing immutable contracts retain old behavior.** LBP, hook, vesting adapter, guardian and liquidator fixes require replacement/migration plans. Updating the repository has no effect on those instances.
8. **Identity uniqueness depends on schema and attestors.** Raw extracted JSON is not canonical semantic identity. Missing extracted parameters skip the sybil gate under existing design. No production attestor behavior was verified.
9. **Time and formal verification limits.** uint32 timestamps assume operation before the 2106 wrap; liquidity-time accumulator ranges are finite. Certora specs were reviewed but not executed, and their NONDET external summaries do not prove integrations.
10. **Fork acceptance is separate.** Tests requiring deployment registries or RPC configuration may be skipped in the default suite. That is not proof of compatibility with live Aave, Morpho, Permit2, pool addresses, existing grants or current chain state.

## Verification and delivery ledger

The final verification record is maintained in [VALIDATION.md](VALIDATION.md), including the source revision, terminal hosted run, test totals/skips, deployment-size checks, ABI checks and any remaining failed gates. Do not treat intermediate local build snapshots or superseded runs as acceptance of the final source.

Dependency restoration was independently exercised into a fresh destination and all 1,587 restored Solidity files matched the initial review dependency tree. Reclaim parser tests passed with clean isolated artifacts; shared build artifacts had produced stale-library false failures and were not accepted as evidence. The combined launch/Reclaim regression snapshot passed 100 tests. Final source validation includes the subsequently arriving Hub/execution changes and spot history repair.

The hosted workflow installs immutable dependency revisions, runs Foundry tests/invariants, checks deployable first-party contract sizes, verifies published ABIs and source licenses, and preserves compilation artifacts. SDK raw and typed ABI exports are synchronized and typechecked. Address generation does not authorize changing deployment records.

Primary external reference consulted: [Solidity’s official known compiler bugs list](https://docs.soliditylang.org/en/latest/bugs.html). The pinned compiler and vendored dependencies remain additional review surfaces; no exhaustive compiler/dependency certification is asserted.
