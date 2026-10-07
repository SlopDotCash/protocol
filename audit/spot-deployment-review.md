# Spot vault, hook, oracle and deployment review

Review baseline: `ac59fdff2c8603ad642f2e73772871e6e0b79807`. Source-level review of all four assigned spot-layer files and deployment scripts, composed with market settlement and vesting reads. This report does not verify deployed addresses or pool economics.

## Findings and hardening

### SPOT-M1: Deposit credit could exceed tokens actually received

Baseline `SpotLiquidityVault.deposit` minted NAV-priced shares using the requested transfer amounts without checking the received balances. A governance-approved transfer-fee token could underfund the assets represented by those new shares, diluting other LPs. The corresponding `UmiaMarketCore.split` credited virtual positions at the requested amounts and could consume other market backing when tokens transferred less. This requires a nonstandard money token to have been approved; canonical VentureToken transfers exact amounts.

The fix checks balance changes around transfers and rejects any mismatch atomically. Share calculation and the minimum-share constraint remain in place. Dedicated `MarketAuditDepositAccounting.t.sol` regressions exercise both the core split path and a vault deposit with a tax-token fixture. Negative rebases and sender-side additional fees remain unsupported token behavior, rather than being made safe by this check.

Severity: Medium under the approved-nonstandard-token precondition. This hardening does not imply arbitrary token approval is safe.

### SPOT-M2: Default observation capacity could block operational paths

The baseline fine oracle was initialized to 100 slots, while the vault requires two observations and a full 30-minute history. One write per two-second block exhausts that history in about 200 seconds. A busy or deliberately dust-traded pool can therefore block deposits, withdrawals, market creation and settlement until capacity is grown and enough history accumulates. The fail-closed behavior protects accounting from a sandwich bypass; the capacity provisioning is an availability dependency.

Fix: reserve 2,048 fine slots during bootstrap, enough for the 30-minute window even at one distinct timestamp per second. Oracle growth is now lazy: unused slots remain uninitialized and each first write pays its own storage cost, avoiding the chain transaction gas cap that made eager allocation of the full window impractical. The ring's initialized flags and oldest-observation fallback preserve lookup ordering. Regressions check 1,801 successive one-second writes retain a full-window read and a 2,048-slot growth stays below 100,000 gas. Existing immutable pools still need permissionless growth and time to rebuild lost history. Coarse capacity remains a separate long-window provisioning requirement.

Severity: Medium availability. This removes the default dust-write capacity denial for new pools while keeping the guard fail-closed.

## Individual-file coverage

| Source | Review and result |
| --- | --- |
| `src/core/SpotLiquidityVault.sol` | Constructor pool binding, LBP-only bootstrap, full NAV share minting, first/last depositor behavior, idle attribution, fee crystallization, proportional withdrawals, exact-transfer checks, pull/return records, active-market locks, callback caller, direct PoolManager settle/take, spot/TWAP guard and oracle history. SPOT-M1; no additional independent critical/high path identified under canonical token/manager assumptions. |
| `src/periphery/UmiaHook.sol` | Owner-bound one-shot initialization, factory provenance, per-pool launcher/operator registry, PoolId binding, operator-only full-range position modification, manager-only callbacks, pre-swap writes, fine/coarse growth and reads. No unprivileged registry/position authorization bypass established. Keeper/history and thin-pool economics remain assumptions. |
| `src/libraries/SpotMarketOracle.sol` | Fixed tick slew, exact ramp/hold integration, signed fractional carry, same-timestamp deduplication, ring growth/order, oldest-observation selection, interpolation, binary search and counterfactual view behavior. The accepted tick slew limits update-count ratcheting. Sparse historical interpolation remains an approximation between checkpoints; the oracle does not prove a minimum manipulation cost. uint32 timestamp and uint144 liquidity-time accumulators have finite horizons; liquidity-time observations are not used to authorize the reviewed vault or milestone decisions. |
| `src/libraries/PositionAmounts.sol` | Token order, full-range and out-of-range reserve amounts, round-down behavior matching position removal. No independent issue found in the supported tick/liquidity domain. |
| `script/*.sol` | All 14 scripts reviewed for initialization ordering, ownership handoff, CREATE2 hook flags, canonical infrastructure, optional operational roles, hardware-wallet/key paths, upgrade calldata, locked implementations, owner rehearsal and library links. Simulations and scripts do not establish live configuration. No secret material was read or broadcast. |
| Deployment/ABI tooling | Original standalone checkout omitted dependency sources and workflow checks; parent-monorepo paths persisted in some helper scripts. Added pinned source installer and a hosted contracts workflow. Rebuild all exported ABI surfaces after remediation and check bytecode sizes. Operational address verification still requires the deployment registry and RPC access. |

## Composition and trust assumptions

The spot vault's PoolManager callback requires the configured manager; outsiders cannot cause arbitrary liquidity removal through it. The hook admits only the registered vault, so direct concentrated-liquidity insertion is prevented. Share mint/burn and PoolManager operations are guarded; real ERC20 transfers and all external errors roll back the transaction. Fee crystallization precedes share/NAV calculations to keep accrued fees with current LPs. The vault blocks public share changes while decision-market funds are deployed, and settlement clears deployment even when no excess returns.

A price movement within the 1,000-tick guard still affects current NAV. User slippage settings and the underlying liquidity are economically material; the guard is not a promise that MEV or long-lived manipulation is impossible. The milestone oracle likewise cannot make a thin pool economically secure by filtering alone.

Replacing registry contracts requires preserving their state obligations. In particular, the conditional oracle is stateful even though replaced through a registry pointer: a new empty instance does not contain existing proposal history. Drain active market obligations or migrate state before changing it. Immutable LBP, vesting adapters, hooks, and liquidators require new deployments; source pushes do not update deployed contracts.

The official Solidity known-bugs list was consulted for the pinned 0.8.26 compiler with `via-ir` enabled. A complete compiler/dependency audit was not performed. Compiler upgrades must account for exact version pragmas in Uniswap dependencies and bytecode/storage compatibility, rather than silently changing this build's compiler.
