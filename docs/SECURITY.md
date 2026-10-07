# Smart Contracts Security Notes

This file summarizes security-relevant behavior in the current contracts.
It is not a replacement for a full audit.

## Threat model (high level)

Key trust assumptions in the current design:

- `UmiaHub.owner()` is trusted to set critical registry pointers:
  - market manager
  - default governance executor
  - swap router
  - TWAP oracle
  - LBP strategy factory
  - market creation signer
- `marketCreationSigner` is trusted to approve market definitions via EIP-712 signatures.
- Winning proposal execution can perform powerful treasury actions (including arbitrary external calls).

## Critical invariants

## 1) Split/merge solvency invariant

`UmiaMarketCore` enforces an internal invariant after split/merge:

- `totalRealVenture >= maxUserVirtualVentureSupply`
- `totalRealMoney >= maxUserVirtualMoneySupply`

where `totalReal*` includes user-deposited backing plus initial LP liquidity removed during market creation.

This invariant is central to settlement safety.

## 2) Single claim per user per market

`hasClaimed[marketId][user]` prevents duplicate settlement claims.

## 3) Single execution per market

`marketExecuted[marketId]` gates repeat execution of winning proposal payloads.

## 4) Liquidation terminal behavior

In `Venture`, `liquidationActive` blocks treasury mutation functions via `whenNotLiquidating`. Claims are handled by an external `ILiquidator` contract set via `venture.setLiquidator()`.

## Access control surfaces

### UmiaHub (`Ownable`)

Owner-only setters control protocol pointers and token approvals.
Compromise impact: broad protocol control.

### UmiaMarketCore

- Swaps are self-custodial; the permit variants recover an EIP-712 signer and consume a per-signer `swapNonces` entry for replay protection.
- Market creation requires valid signer signature and nonce.
- Winning proposal execution uses executor resolved from hub.

### GovernanceExecutor

- Only current market manager may call `executeProposal`.
- Executor must match `HUB.governanceExecutor(venture)`.
- Plan version and action versions are strictly checked.

### Venture

Privilege tiers:
- `onlyHub`: initialization and hub-level operations.
- `onlyExecutor`: mint, burn, withdraw, arbitrary call, team member updates, allowance updates, document uploads, liquidation setup (`setLiquidator`).

## High-risk capabilities to review

1. **Arbitrary call action (`CALL`)**
   - Governance payload can call arbitrary target/value/data through `Venture.executeCall`.
   - Powerful by design; increases blast radius of malicious governance outcomes.

2. **Registry pointer updates in hub**
   - Changing executor/router/oracle/manager can materially alter system behavior.

3. **Market creation signer compromise**
   - Could approve malicious market definitions and payloads.

4. **LP liquidity operations**
   - `createMarket` removes 50% liquidity from venture LP and later re-adds excess.
   - Arithmetic and slippage protections are security-critical.

5. **Liquidation setup**
   - Liquidation is terminal and snapshots balances/supply.
   - Ensure governance process around liquidation is strict.

## Reentrancy and external calls

- `UmiaMarketCore` uses `ReentrancyGuard` on settlement claim and execution flows.
- `GovernanceExecutor` uses `ReentrancyGuard`.
- `Venture` uses `ReentrancyGuard` on transfer/call sensitive methods.
- External call paths include:
  - token transfers,
  - Uniswap helper interactions,
  - `Venture.executeCall` arbitrary targets.

## Oracle manipulation protections

### Spot pool (UmiaHook)

- **Elapsed-time truncated TWAP**: The accepted tick slews toward the pool tick at no more than 4,558 ticks/second (9,116 ticks over a normal two-second Base block), with the ramp and recovery path integrated exactly. Extra writes cannot ratchet the filter faster, and a restored price recovers during quiet time instead of leaking a stale clamped tick across the gap.
- **Operator-only, full-range liquidity enforcement**: `beforeAddLiquidity` and `beforeRemoveLiquidity` reject any caller other than the pool's registered operator (the venture's `SpotLiquidityVault`), and any position that isn't full-range (`minUsableTick` to `maxUsableTick`). Concentrated liquidity would create zero-liquidity tick gaps exploitable for cheap tick manipulation.
- **Spot-vs-TWAP sandwich guard**: `SpotLiquidityVault._requireSpotWithinTwapDeviation` compares the current spot tick against the 30-minute TWAP tick (`TWAP_WINDOW`) and reverts with `SpotPriceDeviationTooHigh` beyond `MAX_TICK_DEVIATION` (1000 ticks, ~10.5%). It runs on deposits, withdrawals, decision-market creation, and settlement. Fail-closed: if the oracle holds fewer than 2 observations or cannot serve the full window (e.g. buffer exhausted by dust swaps), it reverts with `InsufficientOracleHistory` rather than silently allowing the operation. The only skip is an empty position (`currentLiquidity() == 0`), which has no reserves to sandwich and must stay open so a drained vault can be re-bootstrapped.
- **Oracle buffer sizing**: `bootstrapFromLBP` reserves 2,048 fine slots, covering the 30-minute guard window even at one write per distinct one-second timestamp. Growth is lazy: a new slot is initialized on its first observation, so bootstrap and large permissionless growth do not require thousands of eager storage writes. The coarse ring starts at 100 slots and still needs capacity for the configured long vesting window. Old immutable vaults/hooks retain their prior capacity behavior and need permissionless growth plus sufficient accumulated history. See [SPOT_ORACLE.md](SPOT_ORACLE.md).

### Decision markets (ConditionalMarketOracle)

- **Elapsed-time price filtering**: Each proposal fixes a linear slew rate of `ceil(seedPriceX112 / 40)` per second. The oracle integrates the complete ramp and target-price plateau and carries fractional area across updates. Additional updates cannot accelerate the filter or alter its integral for the same price path; restored prices recover during quiet intervals. This reduces short-spike influence but does not eliminate sustained economic manipulation.
- **Trading-start anchor**: The TWAP is anchored at `tradingStart` (with a zero cumulative baseline) by a one-shot `initialize` at market creation, immutable thereafter. No price before trading start affects the average.
- **Swappable implementation**: The oracle is resolved through the Hub registry on every call and its `initialize`/`update`/`calculateTWAP` interface carries the market's winning threshold, so a different implementation can replace this one via `hub.setConditionalMarketOracle()` without touching `UmiaMarketCore`.
- **Trading-end freeze**: Oracle timestamps are capped at `tradingEnd` via `_effectiveTimestamp()`. After trading ends, `update()` stops accumulating and `calculateTWAP()` returns a fixed value. This prevents settlement delay from diluting the TWAP or extending the influence of last-block manipulation.
- **Settlement oracle update**: Oracle is updated at settlement time to include the final price observation before TWAP computation.

## Known operational considerations

- No protocol-wide pause mechanism is present in current code.
- Winning proposal execution uses the configured Hub delay anchored to settlement and can be vetoed by the configured guardian; verify those roles and settings for deployment.
- Oracle correctness depends on manager-triggered updates around swaps/settlement.
- Permit/nonces are per-contract and need replay protection monitoring.

## Recommended review focus for auditors

1. Market accounting and solvency proofs (`split`, `merge`, `settleMarket`, `claimSettlement`).
2. Governance payload decoding/dispatch correctness (`GovernanceExecutor`, `GovernancePayloadValidator`, `GovernanceActions`).
3. Access control and pointer trust model (`UmiaHub`, `Venture` modifiers).
4. Uniswap v4 integration assumptions in LP removal/re-add flow.
5. Liquidation state transitions and proportional payouts.

## Related docs

- `DECISION_MARKET_FLOW.md`
- `GOVERNANCE_TREASURY_LAYER.md`
- `UPGRADES.md`
- `docs/contracts/` references
