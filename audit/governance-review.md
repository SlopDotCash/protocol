# Governance, treasury, liquidation and Reclaim security review

Reviewed baseline: `ac59fdff2c8603ad642f2e73772871e6e0b79807` in the reviewed checkout. Baseline references below refer to that commit; remediation references refer to the working tree under coordinated review. This is a source review, not a guarantee of security or verification of a deployed address.

## Findings

### GOV-H1 — Standing approvals can invalidate liquidation backing and introduce excluded claim tokens

**Severity:** High, conditional on an existing treasury approval and liquidation without its revocation. This prerequisite was already explicitly documented in `docs/GOVERNANCE_TREASURY_LAYER.md`; it is not an approval bypass or a permissionless theft from an unapproved treasury.

**Baseline locations:** `src/libraries/GovernanceActions.sol:245-248,268-276`; `src/liquidation/SimpleLiquidator.sol:107-113,138-150`; `src/core/Venture.sol:246-252,337-349`.

The original liquidator snapshots assets but leaves them in the Venture. ERC20 `transferFrom` does not call Venture and is unaffected by `liquidationActive`. An approved spender can therefore spend assets after they have been committed to claims; later claimants fail due to insufficient backing. Governance cannot revoke the approval through the normal executor after entering the terminal liquidation state.

There is a second consequence beyond the documented withdrawal of backing: the denominator excludes treasury-held venture tokens while those tokens remain live. A standing approval on the venture token lets a spender move these excluded tokens into circulation after the snapshot and use them as liquidation claims. For example, 100 circulating tokens plus 100 excluded treasury tokens gives a 100-token denominator. Pulling the excluded 100 tokens lets a spender claim all backing before the legitimate holder. No approval to the underlying payout asset is necessary.

**Remediation under peer review:** `GovernanceActions.sol:267-272` burns all treasury-held venture tokens after redeeming treasury LP shares, then snapshots actual outstanding supply. `SimpleLiquidator.sol:112-119` takes custody of listed assets during initialization and snapshots the received amounts. Its `claim` transfers directly from that custody. These two changes close different mechanisms and both are needed.

**Peer review result:** The order is correct: redeem LP, burn excluded tokens, compute supply, authorize liquidator, atomically collect and snapshot assets. Initializer and claims share a reentrancy guard. Failure to collect any asset rolls back the entire liquidation transaction. Old Venture approvals cannot spend assets held by SimpleLiquidator. Burning remains available while VentureToken transfers are paused. Transfers of existing circulating tokens between holders do not increase aggregate claim supply.

**Residual boundaries:** Custom liquidators must supply equivalent custody protection or require approval revocation. Governance must close external positions and list the resulting assets before liquidation; omitted assets and assets arriving later are not included in a fixed snapshot. Rebasing, blacklistable and sender-extra-fee tokens can still impair payouts; received-balance accounting alone does not make every nonstandard token safe. The whole claim is atomic across assets, so one reverting asset blocks that claimant's entire claim. No universal recovery mechanism exists for late assets.

**Local test status:** `test/security/GovernanceAuditPoC.t.sol` originally encoded the excluded-token mechanism. That test's expected behavior must change after the burn remediation: treasury venture-token balance is zero, attempted `transferFrom` fails, and the legitimate holder can claim. Parent coordinates the final test updates and execution. This reviewer did not claim a passing execution of the original PoC.

### GOV-M1 — Anyone can consume another application's Reclaim proof

**Severity:** Medium availability issue; no signature forgery required.

**Baseline locations:** `src/reclaim/Reclaim.sol:172-175,215-217`; consumer `src/periphery/UmiaValidationHook.sol:393` at baseline.

`verifyProof` is permissionless but originally treated its global `usedProofs[identifier]` entry as consumable authorization. A caller observing a legitimate proof can directly verify it before the application's transaction, setting the bit without registering the user in the validation hook. The hook's later verifier call reverts. Reissuing a signature with another timestamp does not necessarily repair the same claim: the replay key hashes claim information, rather than the complete signed claim. An attacker can repeat the denial against new public proof submissions.

**Remediation implemented:** `Reclaim.sol:179-233` still validates every signature on every invocation, but successful verification is repeatable. The existing `usedProofs` getter and `ProofUsed` event are retained as informational history for ABI compatibility; they are no longer an application-wide nonce. The hook now records consumption locally (`UmiaValidationHook.sol:399-401` in the reviewed working tree), so direct calls to the verifier do not consume hook authorization. Keeping consumption local also preserves the intended inability to undo `unregister` using the same old proof.

**Integration boundary:** Permissionless registration for a user can still arrive ahead of that user's inline bid. Registration benefits the same bound user; an inline bid carrying the already-consumed proof can revert and should be retried without the proof. Different application instances need their own domain-specific replay rules if the same credentials should not be reusable across those applications.

### GOV-M2 — Rotating Reclaim witnesses does not retire their signing authority

**Severity:** Medium by default; potentially High for an identity-gated launch if a retired witness key is compromised. An attacker needs a selected retired witness key (or the relevant threshold), not merely a public proof.

**Baseline locations:** `src/reclaim/Reclaim.sol:124-129,185-188,225-254`.

The verifier selects witnesses using the claim's caller-supplied signed epoch, but originally did not check the signed timestamp against that epoch, the current time, or an explicit revocation list. Replacing the witness set left the old key able to sign fresh identities with its historical epoch indefinitely. Epoch rotation is therefore not a response to a compromised old key. Merely checking timestamps would still allow a compromised key to backdate forged proofs.

**Remediation implemented:** `Reclaim.sol:181-190` rejects epoch zero, unknown epochs, future timestamps, timestamps predating the epoch, and timestamps beyond a retired epoch's finalized end. The current epoch's end remains advisory because the original contract explicitly defines it as a cache duration; enforcing it as hard expiry would unexpectedly disable the default witness after one day. `Reclaim.sol:238-243` adds owner-only permanent epoch revocation, which rejects backdated proofs too.

**Operational requirement:** Rotate and explicitly revoke compromised epochs. Rotation alone intentionally leaves authentic historical proofs valid within their recorded epoch window. Already-registered application users are not automatically unregistered when the witness is revoked; revocation prevents subsequent verification only. The default hardcoded attestor and verifier owner remain trusted dependencies.

## Other weaknesses and operational boundaries

1. **Terminal liquidation requires a complete asset and position inventory.** Assets omitted from the list, later yield, future vesting refunds, or late market proceeds are not automatically distributed. The SimpleLiquidator supports only native/ERC20 assets while the generic action validator accepts NFT assets for other strategies. A plan can be structurally valid but incompatible with a selected liquidator. Close positions and simulate the actual winning action plan before starting liquidation. This is an operational/design limitation, not a proven permissionless theft.
2. **One-time full claims constrain contract-held tokens.** The caller must own and burn its entire current balance. Tokens held by staking, vesting, liquidity, bridges, or other contracts need a functioning release or claim route. Tokens received by an already-claimed address require onward transfer to a fresh address; a paused token can prevent that transfer. A user-selectable recipient and amount would improve recoverability but are a separate product change.
3. **Manager replacement can strand settled governance plans.** `UmiaHub.sol:629-636` prevents replacement only while unsettled markets exist. `GovernanceExecutor.executeProposal` trusts only the current manager. Replacing the manager after settlement but before execution prevents the old manager from executing its still-pending plans. This is privileged configuration risk; preserve manager identity through UUPS upgrades or separately account for pending execution before replacement.
4. **Powerful trusted keys remain.** Hub owner can replace the executor, upgrade Hub, select the Venture beacon, approve tokens and alter governance parameters. An approved winning CALL can transfer token ownership, grant pull access or call arbitrary contracts. These are documented capabilities, not access-control bypasses. Beacon governance can alter Ventures that have not opted out. Security of those roles is part of the system's security.
5. **The signed-context parser is not a canonical JSON validator.** Claims searches for substrings and StringUtils accepts noncanonical hex input; identity hashing uses verbatim JSON bytes. The hook's identity uniqueness depends on the attestor consistently generating a fixed schema and canonical extracted identity data. A missing extractedParameters object explicitly skips the sybil gate. No evidence established that an untrusted user can make the deployed attestor sign chosen equivalent encodings; do not present this as a verified high-severity exploit.
6. **Documentation requires synchronization.** Baseline `docs/SECURITY.md` says execution has no delay, but Hub and MarketCore already implement a configured execution delay and veto guardian. Baseline treasury docs describe custody in Venture and mandatory revocation; they must describe the new SimpleLiquidator custody separately from custom strategy requirements. `AllowanceSet` is not emitted by raw CALL approval, so that event alone cannot enumerate every approval.

## Individual-file coverage

| File | Review performed and result |
| --- | --- |
| `src/core/UmiaHub.sol` | Initializer, UUPS authorization, registry setters, circuit breaker roles, vault registration, approved-token/factory constraints, two-phase Venture creation, and active-market replacement gate. No unprivileged registry or createVenture access bypass found. Zero owner/pointer mistakes remain deployment/configuration risks. |
| `src/core/Venture.sol` | Two-phase initialization, dynamic executor lookup, mint/burn, treasury withdrawals, arbitrary call, NFT receivers, calendar allowance, PEGGED/ERC4626 sources, pause callback, liquidation transition, and UUPS authorization. Claims require the authorized liquidator. Budget sources debit the common underlying allowance before transfer and use a shared reentrancy guard. |
| `src/core/VentureProxy.sol` | Beacon/default implementation resolution, immutable beacon, ERC1967 direct opt-out, initialization delegatecall. No public setter or initialization race in atomic Hub deployment identified. Upgrades remain authorized through Venture. |
| `src/core/GovernanceExecutor.sol` | Current-manager-only entry, per-Venture executor binding, liquidation check, plan validation, atomic action execution, reentrancy guard. No cross-Venture execution access bypass identified. |
| `src/tokens/VentureToken.sol` | Owner-only mint/burn/pause and OZ ERC20 inheritance; transfer pause deliberately permits owner-controlled burns. Arbitrary holder burns require privileged Venture call pathways. |
| `src/liquidation/SimpleLiquidator.sol` | Hub-bound initialization, authorized-liquidator binding, supported asset types, snapshot arithmetic, burned-claim accounting, payout ordering, reentrancy, and new custody collection. GOV-H1 and residual token/custody limits above. |
| `src/libraries/GovernanceActions.sol` | Every action's validation and execution dispatch, action version, zero-value restrictions, duplicate liquidation assets, self-CALL restriction, upgrades, allowances, LP redemption and claim supply. New burn ordering peer-reviewed. |
| `src/libraries/GovernancePayloadValidator.sol` | Plan version decoding, ABI decode, actual decoded version validation, 20-action cap and terminal-liquidation position. A malicious dynamic ABI offset does not bypass actual decoded version validation. |
| `src/libraries/GovernanceTypes.sol` | Enum ordering, payload parameter representations and versioning; no executable authority or accounting. Existing enum ordinals must remain stable for stored proposal payloads. |
| `src/libraries/CalendarLib.sol` | UTC month conversion, leap-year divisions, month boundaries and budget synchronization callers. No exploit identified at realistic chain timestamps; giant synthetic timestamp overflow is not a chain-accessible issue. |
| `src/reclaim/Reclaim.sol` | Public proof consumption, claim hash binding, witness selection, duplicate signer rejection, admin rotation, timestamp/epoch trust and new revocation. GOV-M1/M2 above. |
| `src/reclaim/Claims.sol` | EIP-191 serialization, OZ ECDSA recovery, signed claim hashing, duplicate handling in consumer, substring and JSON object extraction. Parser canonicalization caveat above. |
| `src/reclaim/StringUtils.sol` | Hex formatting, numeric conversion, substring/index limits and permissive inverse decoding. Malformed input can revert or parse noncanonically; no attestor-independent forgery established. |
| `src/reclaim/BytesUtils.sol` | Four-byte seed load and bounds check. The unusual load offset aligns the last four bytes of the loaded word with the requested four data bytes; it is not an out-of-bounds randomness substitution. |

## Rejected hypotheses and group review

- Direct calls to executor, Venture mint/withdraw, or liquidator initialization do not work for arbitrary callers: manager/executor/authorized-liquidator checks reject them.
- Replay of a normal liquidation claim through fresh addresses does not create new supply because claims burn tokens; the excluded treasury-token exception was separately identified and repaired.
- Including the venture token as a liquidation payout asset does not permit claim recycling: SimpleLiquidator explicitly skips that asset.
- Token/native callbacks cannot reenter a claim or the patched initialization because they share a reentrancy guard; a failed asset transfer rolls back token burning and claim status.
- The beacon-mode UUPS context relaxation does not remove executor authorization. Calling the implementation directly fails the delegatecall context check and initializers are disabled.
- Malformed plan version offsets do not bypass validation of the actual decoded plan version.
- Arbitrary governance CALL and centralized executor replacement are intended trust assumptions, not findings based solely on their power.
- Shared analysis with the launch/vesting reviewer identified the local hook replay requirement, identity-canonicalization assumptions, and post-liquidation guardian exits. Custody isolates listed snapshot shares from a guardian's old approval. Vesting termination already guards liquidation.

## Validation evidence and limits

This reviewer added `test/security/GovernanceAuditPoC.t.sol` with repeatable verification, retired-witness timestamp rejection, backdated revocation, advisory current-epoch end, owner-only revocation and excluded treasury-token coverage. `test/reclaim/Reclaim.t.sol` now expects repeated public verification to succeed and places the historical attestor fixture at its signed timestamp.

Initial local test attempts failed at dependency resolution: the checkout initially lacked pinned libraries, and a subsequent attempt still lacked nested `blocknumberish`/`permit2` dependencies. Parent restored dependencies and owns final integrated builds. On instruction, this reviewer stopped source/test changes and independent test execution while those builds ran. Consequently this document does not label tests as passed without the parent's final output. No deployed contract calls, external transactions, or fund movements were performed.

## Consolidated follow-up

The primary review includes subsequent exact-integration oracle correction, default spot history provisioning, fail-closed token identity migration and pending-execution ordering changes. Final remediation and validation supersede intermediate observations in [SECURITY_REVIEW.md](SECURITY_REVIEW.md) and [VALIDATION.md](VALIDATION.md).
