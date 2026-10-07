# ConditionalMarketOracle

Source: `src/periphery/ConditionalMarketOracle.sol`

## Purpose

Per-proposal TWAP oracle used by market settlement.

- Maintains a cumulative price value in Uniswap-v2-style Q112.112 form.
- Anchors each proposal's scoring window at `tradingStart` with a zero cumulative baseline.
- Calculates TWAP from `tradingStart` to the current block timestamp (frozen at `tradingEnd`).

## Interface

The three-function interface is the upgrade seam: the Hub owner can point the core at a
replacement oracle implementing the same interface (see `docs/UPGRADES.md`) without changing
`UmiaMarketCore`. `winningThresholdBps` is accepted (and validated) at `initialize` so a future
implementation can calibrate its clamp to the same threshold settlement uses; this implementation's
fixed seed-relative slew rate does not consume it.

- `initialize(proposalId, reserve0, reserve1, tradingStart, tradingEnd, winningThresholdBps)` —
  one call at market creation: validates inputs, records the seed observation, anchors
  `lastTimestamp` at `tradingStart`. Reverts with `AlreadyInitialized` if repeated.
- `update(proposalId, reserve0, reserve1)` — called before every reserve mutation, so the elapsed
  interval is credited at the price that actually held over it. No-op before `tradingStart`,
  within the same second, after the `tradingEnd` freeze, or for degenerate (zero) reserves — a
  degenerate interval is credited by the next well-formed update instead.
- `calculateTWAP(proposalId, reserve0, reserve1)` — view; extrapolates the current interval at the
  full ramp and plateau toward the passed reserve price.

## Key state

- `oracleStates[proposalId]`:
  - `price0CumulativeLast` — ∫ observation dt, scored from `tradingStart`
  - `lastPrice0X112` — last accepted observation
  - `tradingStart`, `tradingEnd` — scoring window
  - `lastTimestamp` — last recorded time; anchored at `tradingStart` on init
  - `initialized`

## Access control

- `initialize` and `update` are `onlyMarketCore`.

## Elapsed-time price filter

At initialization, the oracle fixes `rate = ceil(seedPriceX112 / 40)` Q112 price units per second.
The accepted price approaches the price actually held over each interval at this constant absolute
rate. From the seed, a sufficiently high held target reaches approximately 2.5 times the seed after
60 seconds. This is a linear seed-relative rate, not a compounding multiplicative band; downward
movement uses the same absolute rate and stops at the actual target (at least one Q112 unit).

The full path is integrated. With elapsed seconds `dt`, movement `d = min(abs(target - start), rate * dt)`,
and accepted endpoint `end`, the interval area is:

```
rising:  end * dt - d^2 / (2 * rate)
falling: end * dt + d^2 / (2 * rate)
```

These formulas include the flat target-price period after a ramp finishes. The fractional numerator
is retained in `cumulativeRemainder`, whose denominator is always `2 * priceSlewRate`; this prevents
rounding differences from accumulating when an interval is divided into additional updates.
The existing `oracleStates` getter ABI is unchanged. The separate public mappings expose the rate
and remainder. More frequent updates cannot accelerate the filter or change its cumulative area
for the same reserve-price path. If spot returns to normal, the accepted price recovers during a
quiet gap instead of scoring a stale clamped price over the entire gap.

Raw prices and accepted endpoints are bounded to `[1, 2^208]`. Full-precision multiplication/division
handles full-width reserves and squared movements. The maximum integrated area over the uint32
scoring window is below `2^240`. This filter reduces short-spike influence; it does not prevent a
well-funded trader from sustaining a manipulated price, and the rate remains an economic parameter
that must be assessed against liquidity, market duration, and the winning threshold.

## Trading end freeze

Both `update()` and `calculateTWAP()` cap their effective timestamp at `min(block.timestamp, tradingEnd)` via `_effectiveTimestamp()`.

This means:
- After `tradingEnd`, no further price accumulation occurs regardless of when `update()` is called.
- `calculateTWAP()` returns the same value whether called at `tradingEnd` or hours later.
- Settlement delay cannot dilute or extend the TWAP window beyond the trading period.
- Last-block manipulation at `tradingEnd - 1` gets at most one block of influence rather than being extended by the settlement gap.

## Notes

- `calculateTWAP` reverts with `ProposalNotInitialized` for unknown proposals and
  `TradingNotStarted` before the scoring window opens.
- Queried in the first second of the window, `calculateTWAP` returns the anchored observation
  rather than the raw spot of the passed reserves (which would be same-block manipulable).
