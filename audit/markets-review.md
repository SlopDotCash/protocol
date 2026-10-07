# Decision markets security review

Review baseline: `ac59fdff2c8603ad642f2e73772871e6e0b79807`. Scope: the decision-market core, stake escrow, conditional oracle, seven supporting libraries, and the directly consumed interfaces. Reviewed individually first, then composed market creation, trading, oracle updates, settlement, claims, spot-vault return, and governance execution. The source review does not establish that deployed contracts use this source or that any economic system is completely secure.

## H-MARKET-01: A brief pump can leave a phantom high TWAP throughout a quiet market

**Severity: High. Status: corrected in working source; final Solidity validation is coordinated by the parent reviewer.**

Baseline locations: `src/periphery/ConditionalMarketOracle.sol:136-142`, `:162-166`, and `:190-195`. The affected consumption paths are `UmiaMarketCore._beforeSwap/_syncOracle` and `SettlementLib.settle`'s TWAP winner comparison.

The original oracle clamps every observation against the previous *accepted* observation, independent of elapsed time, and multiplies that single value by the full interval. A trader can push a proposal's reserve price above 6.25 times its seed, allow two time-separated pre-swap updates to record 2.5 and 6.25 times the seed, then reverse the pump in the timestamp of the second update. The reverse swap sees no additional elapsed time. If no one trades that proposal again until settlement, restored raw reserves are still clamped upward to 0.4 * 6.25 = 2.5 times the seed. This phantom price is then credited across essentially the entire remaining market window, even though the actual price was restored after only seconds.

The attacker needs an already approved market, enough capital for the temporary reserve displacement and trading fees, and a sufficiently quiet target market. They do not need the market signer or owner role to trade. It is not a single-transaction flash-loan attack: the displaced reserves must survive between timestamps. Other traders updating the same proposal can reduce the stale anchor, so the quiet-market precondition matters. The resulting false winner can select an existing signed proposal with consequential treasury powers; the attack does not manufacture an unsigned governance payload. The execution delay/circuit breaker offers a response window, but does not correct the result.

Correction: a fixed absolute linear rate `ceil(seedPriceX112 / 40)` is established at initialization. Each interval integrates the accepted-price ramp plus the target-price plateau, including recovery after spot returns to normal. The integral carries fractions in a constant denominator, `2 * rate`, making the result independent of update frequency. Existing `oracleStates` tuple shape is preserved with separate rate/remainder mappings. `calculateTWAP` and `update` use the same integration routine.

Regression requirements: sparse versus dense observations of an identical held-price path must produce exactly identical endpoint, cumulative, and fractional remainder; rising and falling paths must both agree; a two-second pump followed by a three-day quiet recovery must add only the bounded triangular excess, not days of phantom price. Unit tests implement these expectations. The parent reviewer owns final integrated trading/settlement validation.

## Mathematical review of the correction

For movement `d = min(abs(target - start), rate * dt)`, the accepted endpoint is `start +/- d`. The integral is `endpoint * dt - d^2/(2*rate)` for a rising path, and `endpoint * dt + d^2/(2*rate)` for a falling path. These expressions remain valid when the target is reached partway through the interval and the rest is flat.

The rising branch converts a negative fractional triangle to a nonnegative fractional remainder by subtracting one whole unit and retaining `denominator - fraction`. The falling branch retains its positive fraction. Adding the prior remainder can carry at most one unit because both remainders are below the fixed denominator. Endpoints are integer Q112 units and `rate` is an integer, so splitting at integer timestamps before reaching a fixed target does not lose endpoint precision.

Prices are in `[1, 2^208]`, the time interval is at most `2^32-1`, and each area is below `2^240`. `rate * dt` is below `2^236`. The potentially 416-bit `d*d` is evaluated through `FullMath.mulDiv` and `mulmod`, never a plain product. Its quotient fits because `d <= rate * dt`. The full window's cumulative is also below `2^240`. The remainder sum stays below `4*rate`. Independent Python arbitrary-precision evaluation passed 20,000 random partition identities, including extreme seeded values; this is auxiliary mathematical evidence, not a Solidity test result.

The rate is an explicit changed economic policy: about 150% of the original seed per minute in either absolute direction. It does not compound or preserve the old 0.4x downward band. With tiny seeds integer granularity matters. Sustained manipulation and weak market liquidity remain economic risks; the filter cannot guarantee a correct governance outcome.

## M-MARKET-02: Intermediate reserve-price multiplication can revert before saturation

**Severity: Medium robustness issue, conditional on extreme supported token magnitudes. Status: corrected by the parent reviewer and retained in the final oracle.**

Baseline locations: `ConditionalMarketOracle.sol:107`, `:137`, `:163`. `(reserve1 * Q112) / reserve0` can overflow when `reserve1 >= 2^144`, even when the final ratio is representable or should be saturated. This can reject market creation or future oracle updates/settlement for unusually large supply tokens. It is not demonstrated against the ordinary six-decimal stablecoin configuration, and no realistic capital route to such quantities is asserted.

The replacement `_reservePrice` detects ratios at or above the power-of-two cap before calculating, then uses full-precision division. Tests cover `uint256.max` reserves, saturated and tiny prices, and arbitrary full-width reserve values.

## Lower severity and residual observations

- **Token behavior assumption:** `UmiaMarketCore._split` credits requested deposit amounts without checking the actual balance delta. The permissioned money-token allowlist therefore must exclude fee-on-transfer and negatively rebasing assets; otherwise internal accounting can overstate real collateral and shared custody increases the impact. Venture tokens are protocol-controlled conventional tokens. This is a conditional integration risk, not an established permissionless exploit against the configured assets.
- **Post-settlement transfers:** `UmiaMarketCore.transfer` remains available after settlement, while `SettlementLib.claim` permits one claim per recipient. Tokens transferred to an address that already claimed cannot be claimed there, but can be forwarded to a fresh address. This is a recoverable usability issue, not duplicate redemption or permanent theft. Burning claims prevents the one-claim flag from being a source of additional supply.
- **Settlement accounting getters:** `SettleAcct.real*Balance` is historical accounting after settlement; return-to-vault, claims, and fees do not decrement those fields. No later redemption uses the fields to authorize a second settlement, but consumers must not treat those getters as current escrow balances. Do not apply pre-settlement solvency assertions to already settled markets.
- **Timestamp horizon:** oracle timestamps use uint32, including narrowing block timestamps. Correct operation assumes dates before the uint32 Unix wrap in 2106. This is not a near-term issue; a future implementation migration must address it.
- **Stake configuration changes:** `verifyAndLockStake` requires equality with current minimum stake. An existing deposit can become temporarily ineligible when the owner changes the requirement; the user can withdraw after the lock and redeposit. The trusted configuration surface should account for this UX.
- **Settlement/spot coupling:** settlement atomically requires successful return to the spot vault, including its oracle guard. This deliberately prevents partial settlement but inherits the vault's availability constraints. It needs operational oracle-history provisioning and separate spot-layer review.
- **No signature expiry for creation:** market approval includes a nonce but no deadline, and past requested start times become the current time. This is a signer workflow/revocation consideration; a caller still needs a valid approved payload and correct nonce.

## Individual coverage and findings disposition

| File | Reviewed properties | Result |
|---|---|---|
| `src/core/UmiaMarketCore.sol` | Initialization/UUPS ownership, virtual IDs and ledger, caller-only transfer, creation digest/nonce, permit attribution and nonce consumption, split/merge conservation, seeded LP shares, liquidity additions, swap movements/fees, pre-mutation oracle synchronization, settlement and execution lifecycle, reentrancy boundaries | H-MARKET-01 propagates into settlement; no independent critical/high accounting or authorization exploit established. Lower observations above. |
| `src/core/UmiaMarketStake.sol` | Deposit amount, withdrawal CEI, current-core-only locking, current minimum, lock expiry, venture-token identity | No independent critical/high finding under the conventional venture-token and trusted-core assumptions. |
| `src/periphery/ConditionalMarketOracle.sol` | Initialization, access control, start anchor, reserve-price arithmetic, update frequency, accepted-price persistence, read/write parity, end freeze, overflow | H-MARKET-01 and M-MARKET-02; corrected as described. |
| `src/libraries/MarketCreationLib.sol` | One unsettled market per venture, bounded proposals/duration, seed pull, two-sided liquidity, governance payload static validation, token mint backing, non-user baseline LP shares, oracle setup and fee/threshold snapshots | No independent critical/high finding. Library delegatecall entry points operate on core-provided storage; standalone library state is not an alternate authorization route. |
| `src/libraries/SettlementLib.sol` | Highest-TWAP selection and no-op threshold, winning-only liabilities and fees, collective LP reserve reservation, dust buffer, individual proportional claims, burns/CEI, atomic excess return, one settlement | False oracle output changes winner; no independent double-claim or fee-drain path found. Historical counters observation above. |
| `src/libraries/LedgerLib.sol` | Mint/burn supply, checked debit sufficiency, unchecked subtraction preconditions, self-transfer behavior, movement to core | No independent critical/high finding. Transfer to core/zero is rejected at public boundary; internal moves maintain supply. |
| `src/libraries/CPMM.sol` | Exact-input/output rounding, insufficient reserves, price-impact and slippage checks, liquidity ratio/rounding, price precision | No independent critical/high finding. Very large unsupported products can revert, but no realistic ordinary-token exploit established. |
| `src/libraries/CPMMWithFee.sol` | Net/gross input conversion, fee rounding, protocol versus pool conservation, exact-output gross slippage, quote consistency | No independent critical/high finding; relies on Hub-constrained basis-point configuration. |
| `src/libraries/TwapMath.sol` | Signed average and flooring for negative ticks, nonzero-window caller obligation, cast ranges | No independent critical/high finding in intended bounded-window use; spot-history wrap behavior is part of spot-layer review. |
| `src/libraries/MarketCoreTypes.sol` | Storage layout semantics, timestamp widths, immutable per-market snapshots and settlement fields | No standalone executable surface; reviewed invariants and compatibility assumptions. |
| `src/interfaces/IUmiaMarketCore.sol` | Permit and creation structs, external signatures, enum/errors, getters versus implementation | No interface mismatch establishing an exploit found. |
| `src/interfaces/IUmiaMarketStake.sol` | Stake tuple and lock/deposit/withdraw API consistency | Consistent with implementation. |
| `src/interfaces/IConditionalMarketOracle.sol` | Pre-mutation update contract, anchor and freeze semantics, winning-threshold parameter, ABI replacement seam | Consistent with corrected implementation; threshold remains validated but does not set the fixed rate. |
| Consumed `IUmiaHub`, `IVenture`, `IGovernanceExecutor`, `ISpotLiquidityVault` declarations | Registry resolution, treasury dispatch and vault-return call signatures used by the above files | Reviewed composition; full implementations independently assigned to peer reviewers. |

## Cross-contract adversarial composition

Reviewed complete creation -> split -> swap -> merge / add liquidity -> oracle selection -> excess return -> LP/token claim -> fee collection -> delayed governance execution paths. Each proposal holds a separate conditional liability backed by the same real collateral, and only the winning proposal redeems. Merge burns every proposal's matching token quantity. Seeded protocol LP shares are included in the denominator but are never minted to a user, preventing first-depositor capture. User LP claims and protocol fees are reserved before returning spot excess. Per-user virtual burns, rather than the claim flag alone, prevent redemption duplication through transfers to fresh addresses. Public swaps cannot select a different victim payer; signed swaps bind all trade terms and consume signer nonces.

The oracle is the material cross-layer weakness identified in this scope: an otherwise well-accounted market can still choose the wrong signed treasury action when its price signal is false. The corrected filter requires all reserve-changing paths to preserve the existing pre-mutation synchronization contract. No deployed operations, deployment verification, or mainnet fork exploit tests were performed by this reviewer.

## Validation handoff

The corrected `test/periphery/ConditionalMarketOracle.t.sol` retains the baseline non-clamp-specific lifecycle suite as `ConditionalMarketOracleLifecycleTest`, and replaces obsolete per-update-band expectations with exact integration tests in `ConditionalMarketOracleTest`. Coverage includes fractional target arrival, unfinished ramps, carry, both recovery directions, sparse/dense equality, fuzz partition equality, full-width reserve arithmetic, access, anchors, zero-reserve handling, and end freeze. Parent reviewer will record terminal Solidity results and the exact final commit; this report intentionally does not assert tests that this reviewer did not execute.

## Consolidated follow-up

The primary review includes subsequent exact-integration oracle correction, default spot history provisioning, fail-closed token identity migration and pending-execution ordering changes. Final remediation and validation supersede intermediate observations in [SECURITY_REVIEW.md](SECURITY_REVIEW.md) and [VALIDATION.md](VALIDATION.md).
