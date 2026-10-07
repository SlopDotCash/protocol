// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IConditionalMarketOracle} from "../interfaces/IConditionalMarketOracle.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title ConditionalMarketOracle
/// @notice Per-proposal time-weighted average of the money-per-venture price (Q112.112).
/// @dev Accepted prices approach the held reserve price at a fixed absolute rate of ceil(seed / 40)
///      Q112 units per second. The complete linear ramp and target-price plateau are integrated,
///      with fractional area carried across updates. Sampling more often cannot change the result.
///      The rate is fixed per proposal; it does not compound with accepted prices or update count.
contract ConditionalMarketOracle is IConditionalMarketOracle {
    // ─────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────

    struct OracleState {
        uint256 price0CumulativeLast; // ∫ observation dt, scored from tradingStart
        uint256 lastPrice0X112; // last accepted observation
        uint32 tradingStart;
        uint32 tradingEnd;
        uint32 lastTimestamp; // last recorded time; anchored at tradingStart on init
        bool initialized;
    }

    // ─────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────

    uint256 internal constant Q112 = 2 ** 112;

    /// @dev Every accepted observation is saturated to this price, so `maxPrice` products stay inside
    ///      uint256 under any reserve ratio and a stored observation can never brick a later update or
    ///      settlement read. It sits far above any real money-per-venture price.
    uint256 internal constant MAX_PRICE_X112 = 1 << 208;

    // ─────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────

    IUmiaHub public immutable HUB;

    mapping(uint256 proposalId => OracleState) public oracleStates;
    // Separate mappings preserve the existing oracleStates getter ABI.
    mapping(uint256 proposalId => uint256) public priceSlewRate;
    mapping(uint256 proposalId => uint256) public cumulativeRemainder;

    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error OnlyMarketCore();
    error AlreadyInitialized();
    error ProposalNotInitialized();
    error InvalidReserves();
    error InvalidTradingWindow();
    error InvalidWinningThreshold();
    error TradingNotStarted();

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    event OracleInitialized(
        uint256 indexed proposalId,
        uint32 tradingStart,
        uint32 tradingEnd,
        uint256 initialPriceX112,
        uint16 winningThresholdBps
    );

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    constructor(address _hub) {
        HUB = IUmiaHub(_hub);
    }

    // ─────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────

    modifier onlyMarketCore() {
        if (msg.sender != HUB.umiaMarketCore()) revert OnlyMarketCore();
        _;
    }

    // ─────────────────────────────────────────────────────────
    // External Functions
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IConditionalMarketOracle
    function initialize(
        uint256 proposalId,
        uint256 reserve0,
        uint256 reserve1,
        uint32 tradingStart,
        uint32 tradingEnd,
        uint16 winningThresholdBps
    ) external onlyMarketCore {
        OracleState storage oracle = oracleStates[proposalId];
        if (oracle.initialized) revert AlreadyInitialized();
        if (reserve0 == 0 || reserve1 == 0) revert InvalidReserves();
        if (tradingEnd <= tradingStart) revert InvalidTradingWindow();
        // Unused by this implementation's fixed clamp; validated so the creation path keeps the same
        // revert surface when a threshold-calibrated oracle is swapped in.
        if (winningThresholdBps == 0 || winningThresholdBps > 10_000) revert InvalidWinningThreshold();

        uint256 seedPrice = _reservePrice(reserve0, reserve1);
        if (seedPrice > MAX_PRICE_X112) seedPrice = MAX_PRICE_X112;
        if (seedPrice == 0) seedPrice = 1;

        priceSlewRate[proposalId] = (seedPrice + 39) / 40;
        oracle.lastPrice0X112 = seedPrice;
        oracle.tradingStart = tradingStart;
        oracle.tradingEnd = tradingEnd;
        // Anchor scoring at tradingStart: the cumulative stays 0 until the first post-start update,
        // and no price-changing operation can occur before then (swaps are gated on tradingStart).
        oracle.lastTimestamp = tradingStart;
        oracle.initialized = true;

        emit OracleInitialized(proposalId, tradingStart, tradingEnd, seedPrice, winningThresholdBps);
    }

    /// @inheritdoc IConditionalMarketOracle
    function update(uint256 proposalId, uint256 reserve0, uint256 reserve1) external onlyMarketCore {
        OracleState storage oracle = oracleStates[proposalId];
        if (!oracle.initialized) return;

        uint32 effectiveTs = _effectiveTimestamp(oracle.tradingEnd);
        // Nothing to record before tradingStart, within the same second, or after the end freeze.
        if (effectiveTs <= oracle.lastTimestamp) return;

        // A degenerate pool has no price to record. Leave `lastTimestamp` untouched so the interval is
        // credited by the next well-formed update rather than silently scored as zero.
        if (reserve0 == 0 || reserve1 == 0) return;

        uint32 timeElapsed = effectiveTs - oracle.lastTimestamp;
        uint256 rawPrice0 = _reservePrice(reserve0, reserve1);
        (uint256 area, uint256 price0, uint256 remainder) = _integrate(
            rawPrice0, oracle.lastPrice0X112, timeElapsed, priceSlewRate[proposalId], cumulativeRemainder[proposalId]
        );
        oracle.price0CumulativeLast += area;
        cumulativeRemainder[proposalId] = remainder;
        oracle.lastPrice0X112 = price0;
        oracle.lastTimestamp = effectiveTs;
    }

    /// @inheritdoc IConditionalMarketOracle
    function calculateTWAP(uint256 proposalId, uint256 reserve0, uint256 reserve1)
        external
        view
        returns (uint256 twapX112)
    {
        OracleState memory oracle = oracleStates[proposalId];
        if (!oracle.initialized) revert ProposalNotInitialized();
        if (block.timestamp < oracle.tradingStart) revert TradingNotStarted();

        uint32 effectiveTs = _effectiveTimestamp(oracle.tradingEnd);
        uint256 cumulative = oracle.price0CumulativeLast;

        // effectiveTs >= lastTimestamp always: lastTimestamp was set to an effective timestamp <= its
        // block time, and block time only advances.
        uint32 timeElapsed = effectiveTs - oracle.lastTimestamp;
        if (timeElapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            uint256 rawPrice0 = _reservePrice(reserve0, reserve1);
            (uint256 area,,) = _integrate(
                rawPrice0,
                oracle.lastPrice0X112,
                timeElapsed,
                priceSlewRate[proposalId],
                cumulativeRemainder[proposalId]
            );
            cumulative += area;
        }

        uint32 scored = effectiveTs - oracle.tradingStart;
        // Queried in the first second of the window there is nothing to average yet. Return the
        // anchored observation rather than raw spot, which is unclamped and same-block manipulable.
        if (scored == 0) return oracle.lastPrice0X112;
        twapX112 = cumulative / scored;
    }

    // ─────────────────────────────────────────────────────────
    // Internal Functions
    // ─────────────────────────────────────────────────────────

    /// @dev Divide at full precision and cap before mulDiv when even its result would overflow.
    ///      The integer quotient comparison is exact at the power-of-two saturation boundary.
    function _reservePrice(uint256 reserve0, uint256 reserve1) internal pure returns (uint256) {
        if (reserve1 / reserve0 >= MAX_PRICE_X112 / Q112) return MAX_PRICE_X112;
        return FullMath.mulDiv(reserve1, Q112, reserve0);
    }

    /// @dev Current time capped at the trading-end freeze.
    function _effectiveTimestamp(uint32 tradingEnd) internal view returns (uint32) {
        uint32 ts = uint32(block.timestamp);
        return ts > tradingEnd ? tradingEnd : ts;
    }

    /// @dev Integrates a linear ramp toward the held raw price, followed by a plateau if reached.
    ///      For movement d, area = endpoint * dt +/- d^2/(2*rate). Carrying the remainder in the
    ///      fixed denominator 2*rate makes splitting an interval exactly additive, even when the
    ///      target is reached between integer seconds. All prices <= 2^208, dt <= 2^32-1, so the
    ///      area fits below 2^240; FullMath handles the potentially 416-bit squared movement.
    function _integrate(uint256 rawPrice, uint256 lastPrice, uint32 timeElapsed, uint256 rate, uint256 remainder)
        internal
        pure
        returns (uint256 area, uint256 endpoint, uint256 nextRemainder)
    {
        if (rawPrice > MAX_PRICE_X112) rawPrice = MAX_PRICE_X112;
        if (rawPrice == 0) rawPrice = 1;
        bool rising = rawPrice >= lastPrice;
        uint256 distance = rising ? rawPrice - lastPrice : lastPrice - rawPrice;
        uint256 maxMovement = rate * timeElapsed;
        uint256 movement = distance < maxMovement ? distance : maxMovement;
        endpoint = rising ? lastPrice + movement : lastPrice - movement;
        uint256 denominator = rate * 2;
        uint256 triangle = FullMath.mulDiv(movement, movement, denominator);
        uint256 fraction = mulmod(movement, movement, denominator);
        area = endpoint * timeElapsed;
        if (rising) {
            area -= triangle;
            if (fraction != 0) {
                --area;
                fraction = denominator - fraction;
            }
        } else {
            area += triangle;
        }
        nextRemainder = remainder + fraction;
        if (nextRemainder >= denominator) {
            ++area;
            nextRemainder -= denominator;
        }
    }
}
