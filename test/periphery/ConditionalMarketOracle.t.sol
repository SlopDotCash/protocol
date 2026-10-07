// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConditionalMarketOracle} from "../../src/periphery/ConditionalMarketOracle.sol";
import {IConditionalMarketOracle} from "../../src/interfaces/IConditionalMarketOracle.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";

/// @notice Test harness that exposes internal functions and bypasses the access control
contract ConditionalMarketOracleHarness is ConditionalMarketOracle {
    constructor(address _hub) ConditionalMarketOracle(_hub) {}

    /// @dev One full clamp period: the bound is exactly 2.5x / 0.4x.
    function exposed_clampPrice(uint256 rawPrice, uint256 lastPrice) external pure returns (uint256) {
        return _clampPrice(rawPrice, lastPrice, 60);
    }

    function exposed_clampPrice(uint256 rawPrice, uint256 lastPrice, uint32 timeElapsed)
        external
        pure
        returns (uint256)
    {
        return _clampPrice(rawPrice, lastPrice, timeElapsed);
    }
}

/// @notice Minimal mock hub that returns msg.sender as market manager
contract MockHub {
    address public umiaMarketCore;

    constructor(address _mm) {
        umiaMarketCore = _mm;
    }
}

contract ConditionalMarketOracleTest is Test {
    ConditionalMarketOracleHarness oracle;
    MockHub hub;

    uint256 constant Q112 = 2 ** 112;
    uint256 constant MAX_PRICE_X112 = 1 << 208;
    uint16 constant THRESHOLD_BPS = 200;
    uint32 constant DURATION = 3 days;

    // Realistic reserves: 18-decimal venture token vs 6-decimal USDC
    uint256 constant RESERVE_VENTURE = 200_000e18;
    uint256 constant RESERVE_USDC = 200_000e6;

    event OracleInitialized(
        uint256 indexed proposalId,
        uint32 tradingStart,
        uint32 tradingEnd,
        uint256 initialPriceX112,
        uint16 winningThresholdBps
    );

    function setUp() public {
        hub = new MockHub(address(this));
        oracle = new ConditionalMarketOracleHarness(address(hub));
        vm.warp(1000);
    }

    /// @dev Initialize `proposalId` with the standard reserves, trading starting now.
    function _init(uint256 proposalId) internal returns (uint32 tradingStart, uint32 tradingEnd) {
        return _initWithReserves(proposalId, RESERVE_VENTURE, RESERVE_USDC);
    }

    function _initWithReserves(uint256 proposalId, uint256 reserve0, uint256 reserve1)
        internal
        returns (uint32 tradingStart, uint32 tradingEnd)
    {
        tradingStart = uint32(block.timestamp);
        tradingEnd = tradingStart + DURATION;
        oracle.initialize(proposalId, reserve0, reserve1, tradingStart, tradingEnd, THRESHOLD_BPS);
    }

    function _seedPrice() internal pure returns (uint256) {
        return (RESERVE_USDC * Q112) / RESERVE_VENTURE;
    }

    // ═══════════════════════════════════════════════════════════
    // _clampPrice unit tests
    // ═══════════════════════════════════════════════════════════

    function test_clampPrice_withinRangeUnchanged() public view {
        uint256 lastPrice = 1000 * Q112;
        uint256 rawPrice = 1500 * Q112;
        uint256 clamped = oracle.exposed_clampPrice(rawPrice, lastPrice);
        assertEq(clamped, rawPrice, "Price within 2.5x range should pass through");
    }

    function test_clampPrice_clampedAtMax() public view {
        uint256 lastPrice = 1000 * Q112;
        uint256 rawPrice = 5000 * Q112;
        uint256 clamped = oracle.exposed_clampPrice(rawPrice, lastPrice);
        uint256 expectedMax = (lastPrice * 5) / 2;
        assertEq(clamped, expectedMax, "Price above 2.5x should be clamped to max");
    }

    function test_clampPrice_clampedAtMin() public view {
        uint256 lastPrice = 1000 * Q112;
        uint256 rawPrice = 100 * Q112;
        uint256 clamped = oracle.exposed_clampPrice(rawPrice, lastPrice);
        uint256 expectedMin = (lastPrice * 2 + 4) / 5;
        assertEq(clamped, expectedMin, "Price below 0.4x should be clamped to min");
    }

    function test_clampPrice_exactlyAtBoundary() public view {
        uint256 lastPrice = 1000 * Q112;

        uint256 exactMax = (lastPrice * 5) / 2;
        assertEq(oracle.exposed_clampPrice(exactMax, lastPrice), exactMax, "Exactly at max boundary");

        uint256 exactMin = (lastPrice * 2 + 4) / 5;
        assertEq(oracle.exposed_clampPrice(exactMin, lastPrice), exactMin, "Exactly at min boundary");
    }

    function test_clampPrice_symmetricRatio() public view {
        uint256 lastPrice = 1000 * Q112;
        uint256 maxPrice = oracle.exposed_clampPrice(type(uint256).max, lastPrice);
        uint256 minPrice = oracle.exposed_clampPrice(0, lastPrice);

        // max / lastPrice = 2.5, lastPrice / min = 2.5
        assertEq(maxPrice, (lastPrice * 5) / 2, "Max should be 2.5x last");
        assertEq(minPrice, (lastPrice * 2 + 4) / 5, "Min should be 0.4x last");

        // max * min ≈ lastPrice^2 (within rounding)
        uint256 product = (maxPrice / Q112) * (minPrice / Q112);
        uint256 lastSquared = (lastPrice / Q112) * (lastPrice / Q112);
        assertEq(product, lastSquared, "max * min should equal lastPrice^2");
    }

    function test_clampPrice_worksWithLargeQ112Values() public view {
        // price when reserve0(6-dec) << reserve1(18-dec): ratio is 1e12 scaled by Q112
        uint256 lastPrice = (RESERVE_VENTURE * Q112) / RESERVE_USDC;
        assertGt(lastPrice, 1e44, "Inverse price should be very large in Q112");

        uint256 rawDouble = lastPrice * 2;
        uint256 clamped = oracle.exposed_clampPrice(rawDouble, lastPrice);
        assertEq(clamped, rawDouble, "2x should be within 2.5x range");

        uint256 rawTriple = lastPrice * 3;
        uint256 clampedTriple = oracle.exposed_clampPrice(rawTriple, lastPrice);
        assertEq(clampedTriple, (lastPrice * 5) / 2, "3x should be clamped to 2.5x");
    }

    function test_clampPrice_worksWithSmallQ112Values() public view {
        // price0 when reserve0(18-dec) >> reserve1(6-dec): ratio is 1e-12 scaled by Q112
        uint256 lastPrice = (RESERVE_USDC * Q112) / RESERVE_VENTURE;
        assertGt(lastPrice, 1e20, "Forward price should be in Q112 scale");

        uint256 clamped = oracle.exposed_clampPrice(1, lastPrice);
        assertEq(clamped, (lastPrice * 2 + 4) / 5, "Tiny raw should clamp to min");
    }

    function test_clampPrice_neverReturnsZero() public view {
        assertEq(oracle.exposed_clampPrice(0, 1), 1, "min clamp rounds up to 1");
        assertEq(oracle.exposed_clampPrice(0, 2), 1, "min clamp rounds up to 1");
        assertGt(oracle.exposed_clampPrice(0, 1000 * Q112), 0, "clamped observation is never zero");
    }

    function test_clampPrice_saturatesToMaxPrice() public view {
        // A raw price beyond the saturation cap is truncated before the band check.
        uint256 lastPrice = MAX_PRICE_X112;
        uint256 clamped = oracle.exposed_clampPrice(type(uint256).max, lastPrice);
        assertEq(clamped, MAX_PRICE_X112, "Observation saturates at MAX_PRICE_X112");
    }

    // ═══════════════════════════════════════════════════════════
    // initialize()
    // ═══════════════════════════════════════════════════════════

    function test_initialize_revertsIfNotMarketCore() public {
        MockHub hub2 = new MockHub(address(0xdead));
        ConditionalMarketOracleHarness oracle2 = new ConditionalMarketOracleHarness(address(hub2));

        vm.expectRevert(ConditionalMarketOracle.OnlyMarketCore.selector);
        oracle2.initialize(1, 100, 100, 1000, 2000, THRESHOLD_BPS);
    }

    function test_initialize_setsSeedStateAndEmits() public {
        uint32 tradingStart = uint32(block.timestamp + 100);
        uint32 tradingEnd = tradingStart + DURATION;

        vm.expectEmit(true, false, false, true);
        emit OracleInitialized(1, tradingStart, tradingEnd, _seedPrice(), THRESHOLD_BPS);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, tradingStart, tradingEnd, THRESHOLD_BPS);

        (uint256 cum0, uint256 lastP0, uint32 start, uint32 end, uint32 lastTs, bool initialized) =
            oracle.oracleStates(1);

        assertTrue(initialized, "initialized flag set");
        assertEq(cum0, 0, "cumulative starts at zero");
        assertEq(lastP0, _seedPrice(), "seed observation recorded");
        assertEq(start, tradingStart, "tradingStart stored");
        assertEq(end, tradingEnd, "tradingEnd stored");
        assertEq(lastTs, tradingStart, "anchored at tradingStart");
    }

    function test_initialize_revertsIfAlreadyInitialized() public {
        _init(1);
        vm.expectRevert(ConditionalMarketOracle.AlreadyInitialized.selector);
        _init(1);
    }

    function test_initialize_revertsOnZeroReserves() public {
        uint32 start = uint32(block.timestamp);
        vm.expectRevert(ConditionalMarketOracle.InvalidReserves.selector);
        oracle.initialize(1, 0, RESERVE_USDC, start, start + DURATION, THRESHOLD_BPS);

        vm.expectRevert(ConditionalMarketOracle.InvalidReserves.selector);
        oracle.initialize(1, RESERVE_VENTURE, 0, start, start + DURATION, THRESHOLD_BPS);
    }

    function test_initialize_revertsOnEmptyTradingWindow() public {
        uint32 start = uint32(block.timestamp);
        vm.expectRevert(ConditionalMarketOracle.InvalidTradingWindow.selector);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, start, start, THRESHOLD_BPS);

        vm.expectRevert(ConditionalMarketOracle.InvalidTradingWindow.selector);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, start, start - 1, THRESHOLD_BPS);
    }

    function test_initialize_revertsOnInvalidThreshold() public {
        uint32 start = uint32(block.timestamp);
        vm.expectRevert(ConditionalMarketOracle.InvalidWinningThreshold.selector);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, start, start + DURATION, 0);

        vm.expectRevert(ConditionalMarketOracle.InvalidWinningThreshold.selector);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, start, start + DURATION, 10_001);
    }

    function test_initialize_seedNeverZero() public {
        // Reserve skew that floors the raw seed price to zero must anchor at 1, not 0.
        uint32 start = uint32(block.timestamp);
        oracle.initialize(1, 1 << 140, 1, start, start + DURATION, THRESHOLD_BPS);

        (, uint256 lastP0,,,,) = oracle.oracleStates(1);
        assertEq(lastP0, 1, "zero seed price is floored to 1");
    }

    function test_initialize_seedSaturatedToMaxPrice() public {
        uint32 start = uint32(block.timestamp);
        oracle.initialize(1, 1, 1 << 100, start, start + DURATION, THRESHOLD_BPS);

        (, uint256 lastP0,,,,) = oracle.oracleStates(1);
        assertEq(lastP0, MAX_PRICE_X112, "extreme seed price saturates at MAX_PRICE_X112");
    }

    // ═══════════════════════════════════════════════════════════
    // update() — access control & lifecycle guards
    // ═══════════════════════════════════════════════════════════

    function test_update_revertsIfNotMarketCore() public {
        MockHub hub2 = new MockHub(address(0xdead));
        ConditionalMarketOracleHarness oracle2 = new ConditionalMarketOracleHarness(address(hub2));

        vm.expectRevert(ConditionalMarketOracle.OnlyMarketCore.selector);
        oracle2.update(1, 100, 100);
    }

    function test_update_noOpWhenUninitialized() public {
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);

        (uint256 cum0, uint256 lastP0,,, uint32 lastTs, bool initialized) = oracle.oracleStates(1);
        assertFalse(initialized, "update must not initialize");
        assertEq(cum0, 0);
        assertEq(lastP0, 0);
        assertEq(lastTs, 0);
    }

    function test_update_noOpBeforeTradingStart() public {
        uint32 tradingStart = uint32(block.timestamp + 100);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, tradingStart, tradingStart + DURATION, THRESHOLD_BPS);

        // Before trading start the anchor must not move, whatever reserves are pushed.
        oracle.update(1, RESERVE_VENTURE / 2, RESERVE_USDC * 2);

        (uint256 cum0, uint256 lastP0,,, uint32 lastTs,) = oracle.oracleStates(1);
        assertEq(cum0, 0, "no accumulation before trading start");
        assertEq(lastP0, _seedPrice(), "seed observation untouched");
        assertEq(lastTs, tradingStart, "anchor untouched");
    }

    function test_update_sameSecondNoOp() public {
        _init(1);

        // Same second as the anchor, different reserves — should not accumulate
        oracle.update(1, RESERVE_VENTURE / 2, RESERVE_USDC * 2);

        (uint256 cum0, uint256 lastP0,,,,) = oracle.oracleStates(1);
        assertEq(cum0, 0, "Same-second update should not change cumulative");
        assertEq(lastP0, _seedPrice(), "Same-second update should not change observation");
    }

    // ═══════════════════════════════════════════════════════════
    // update() — accumulation & clamping
    // ═══════════════════════════════════════════════════════════

    function test_update_accumulatesCumulativePrices() public {
        _init(1);

        vm.warp(vm.getBlockTimestamp() + 100);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);

        (uint256 cum0,,,, uint32 lastTs,) = oracle.oracleStates(1);
        assertEq(cum0, _seedPrice() * 100, "Delta cumulative should be price * timeElapsed");
        assertEq(lastTs, uint32(vm.getBlockTimestamp()), "lastTimestamp advanced");
    }

    function test_update_clampsLargeJump() public {
        _init(1);

        vm.warp(vm.getBlockTimestamp() + 60);

        // 100x price change — should be clamped to 2.5x
        oracle.update(1, RESERVE_VENTURE / 100, RESERVE_USDC);

        (, uint256 lastP0,,,,) = oracle.oracleStates(1);
        uint256 expectedClamped = (_seedPrice() * 5) / 2;
        assertEq(lastP0, expectedClamped, "100x jump should be clamped to 2.5x");
    }

    function test_update_clampsLargeDrop() public {
        _init(1);

        vm.warp(vm.getBlockTimestamp() + 60);

        // 10x price drop — should be clamped to 0.4x
        oracle.update(1, RESERVE_VENTURE * 10, RESERVE_USDC);

        (, uint256 lastP0,,,,) = oracle.oracleStates(1);
        uint256 expectedClamped = (_seedPrice() * 2 + 4) / 5;
        assertEq(lastP0, expectedClamped, "10x drop should be clamped to 0.4x");
    }

    function test_update_multiBlockManipulationBounded() public {
        (uint32 tradingStart,) = _init(1);
        uint256 initialP0 = _seedPrice();

        // 10 consecutive blocks, each trying to push price up 100x
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(vm.getBlockTimestamp() + 12);
            oracle.update(1, RESERVE_VENTURE / 100, RESERVE_USDC);
        }

        (, uint256 finalP0,,, uint32 finalTs,) = oracle.oracleStates(1);
        assertEq(finalTs, tradingStart + 120, "All ten distinct updates advanced the oracle clock");

        // The bound scales with elapsed time, not update count: 120s of updates allow at most
        // 2.5^(120/60) = 6.25x however many updates land in that window.
        assertGt(finalP0, initialP0 * 2, "Multiple clamped blocks should accumulate beyond 2x");
        assertLe(finalP0, (initialP0 * 625) / 100 + 1, "Growth bounded by 2.5x per 60s of elapsed time");
    }

    /// @dev Regression: a per-update clamp let a few back-to-back updates ratchet the anchor to ~16x and
    ///      then scored a multi-day quiet interval at 0.4x of that anchor (~6x the real price). The
    ///      time-scaled bound must let a quiet interval catch up to the real price.
    function test_update_spikeDoesNotPersistThroughQuietInterval() public {
        (uint32 tradingStart, uint32 tradingEnd) = _init(1);
        uint256 seed = _seedPrice();

        // Attacker holds a 16x price for three 2-second blocks, updating every block.
        vm.warp(uint256(tradingStart) + 1 hours);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(vm.getBlockTimestamp() + 2);
            oracle.update(1, RESERVE_VENTURE / 16, RESERVE_USDC);
        }

        (,,,, uint32 spikeEnd,) = oracle.oracleStates(1);
        assertEq(spikeEnd, tradingStart + 1 hours + 6, "Three distinct two-second updates occurred");

        // Price is restored and the pool goes quiet until the end of trading.
        vm.warp(tradingEnd);
        uint256 twap = oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);
        assertLe(twap, (seed * 10_001) / 10_000, "A seconds-long spike must not move a 3-day TWAP by 1bp");
    }

    function test_clampPrice_boundScalesWithElapsedTime() public view {
        uint256 lastPrice = 1000 * Q112;
        uint256 raw = 1_000_000 * Q112;
        assertLt(oracle.exposed_clampPrice(raw, lastPrice, 2), (lastPrice * 104) / 100, "2s allows ~3%");
        assertEq(oracle.exposed_clampPrice(raw, lastPrice, 120), (lastPrice * 25) / 4, "120s allows exactly 6.25x");
        assertEq(oracle.exposed_clampPrice(raw, lastPrice, 30 minutes), raw, "Past the horizon the spot is taken");
        assertEq(oracle.exposed_clampPrice(Q112, lastPrice, 30 minutes), Q112, "Unbounded downward too");
        assertEq(oracle.exposed_clampPrice(0, lastPrice, 30 minutes), 1, "Never zero");
    }

    function test_update_zeroReservesCreditedByNextUpdate() public {
        (uint32 tradingStart,) = _init(1);

        // A degenerate-pool update records nothing and leaves the anchor in place …
        vm.warp(uint256(tradingStart) + 60);
        oracle.update(1, 0, RESERVE_USDC);

        (uint256 cumAfterZero,,,, uint32 tsAfterZero,) = oracle.oracleStates(1);
        assertEq(cumAfterZero, 0, "Zero reserves should skip price accumulation");
        assertEq(tsAfterZero, tradingStart, "Zero-reserve update must not consume the interval");

        // … so the next well-formed update credits the full interval.
        vm.warp(uint256(tradingStart) + 120);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);

        (uint256 cumAfterGood,,,,,) = oracle.oracleStates(1);
        assertEq(cumAfterGood, _seedPrice() * 120, "Full interval credited at the next well-formed update");
    }

    function test_update_observationFrozenAfterTradingEnd() public {
        (, uint32 tradingEnd) = _init(1);

        vm.warp(tradingEnd);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);

        (uint256 cumAtEnd, uint256 obsAtEnd,,, uint32 tsAtEnd,) = oracle.oracleStates(1);

        // Post-freeze updates with wildly different reserves must not touch any state.
        vm.warp(uint256(tradingEnd) + 1 hours);
        oracle.update(1, RESERVE_VENTURE / 100, RESERVE_USDC);

        (uint256 cumAfter, uint256 obsAfter,,, uint32 tsAfter,) = oracle.oracleStates(1);
        assertEq(obsAfter, obsAtEnd, "Observation frozen after tradingEnd");
        assertEq(cumAfter, cumAtEnd, "Cumulative frozen after tradingEnd");
        assertEq(tsAfter, tsAtEnd, "Timestamp frozen after tradingEnd");
    }

    /// @dev The invariants the overflow-safety argument rests on: whatever reserves are pushed, every
    ///      stored observation stays in [1, MAX_PRICE_X112], the cumulative never decreases, the clock
    ///      never passes the freeze, and the settlement read never reverts.
    function testFuzz_update_invariants(
        uint256[8] calldata reserves0,
        uint256[8] calldata reserves1,
        uint32[8] calldata dts
    ) public {
        (uint32 tradingStart, uint32 tradingEnd) = _init(1);

        uint256 ts = tradingStart;
        uint256 prevCum;
        for (uint256 i = 0; i < 8; i++) {
            ts += bound(uint256(dts[i]), 0, 1 days);
            vm.warp(ts);

            // Zeros exercise the degenerate-pool path; 2^140 keeps reserve1 * Q112 inside uint256
            // while still driving raw prices far past MAX_PRICE_X112.
            uint256 r0 = bound(reserves0[i], 0, 1 << 140);
            uint256 r1 = bound(reserves1[i], 0, 1 << 140);
            oracle.update(1, r0, r1);
            oracle.calculateTWAP(1, r0, r1);

            (uint256 cum, uint256 obs,,, uint32 lastTs,) = oracle.oracleStates(1);
            assertGe(obs, 1, "observation never zero");
            assertLe(obs, MAX_PRICE_X112, "observation saturated");
            assertGe(cum, prevCum, "cumulative monotone");
            assertLe(lastTs, tradingEnd, "timestamp never beyond the freeze");
            prevCum = cum;
        }
    }

    function test_update_stopsAccumulatingAfterTradingEnd() public {
        (, uint32 tradingEnd) = _init(1);

        vm.warp(tradingEnd);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);

        (uint256 cumAtEnd,,,,,) = oracle.oracleStates(1);

        // Update well after tradingEnd — cumulative should not change
        vm.warp(uint256(tradingEnd) + 3000);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);

        (uint256 cumAfter,,,, uint32 lastTs,) = oracle.oracleStates(1);
        assertEq(cumAfter, cumAtEnd, "Cumulative should not grow after tradingEnd");
        assertEq(lastTs, tradingEnd, "Timestamp capped at tradingEnd");
    }

    // ═══════════════════════════════════════════════════════════
    // calculateTWAP()
    // ═══════════════════════════════════════════════════════════

    function test_twap_revertsWhenUninitialized() public {
        vm.expectRevert(ConditionalMarketOracle.ProposalNotInitialized.selector);
        oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);
    }

    function test_twap_revertsBeforeTradingStart() public {
        uint32 tradingStart = uint32(block.timestamp + 100);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, tradingStart, tradingStart + DURATION, THRESHOLD_BPS);

        vm.expectRevert(ConditionalMarketOracle.TradingNotStarted.selector);
        oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);
    }

    function test_twap_returnsAnchoredObservationWhenZeroTimeElapsed() public {
        _init(1);

        // Same second as trading start — nothing to average yet. The anchored observation is
        // returned, not the (manipulable) raw spot of the passed reserves.
        uint256 twap = oracle.calculateTWAP(1, RESERVE_VENTURE / 100, RESERVE_USDC);
        assertEq(twap, _seedPrice(), "Zero elapsed time should return the anchored observation");
    }

    function test_twap_stableReservesMaintainsConstant() public {
        _init(1);

        // Several updates with same reserves
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        }

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 twap = oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);
        assertEq(twap, _seedPrice(), "TWAP with constant reserves should equal the seed price");
    }

    function test_twap_sustainedSpikeUsesActualDuration() public {
        _init(1);

        uint256 basePrice = _seedPrice();

        // 23 hours of normal trading
        for (uint256 i = 0; i < 23; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        }

        // A sustained hour at the higher price has real elapsed-time weight.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        oracle.update(1, RESERVE_VENTURE / 100, RESERVE_USDC);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 twap = oracle.calculateTWAP(1, RESERVE_VENTURE / 100, RESERVE_USDC);

        // The high price actually lasted two hours. Long intervals must not retain a
        // stale per-update cap; score precisely the price held over each interval.
        uint256 highPrice = (RESERVE_USDC * Q112) / (RESERVE_VENTURE / 100);
        assertEq(twap, (23 * basePrice + 2 * highPrice) / 25, "Only actual duration weights the spike");
    }

    function test_twap_viewExtrapolatesWithClamping() public {
        _init(1);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);

        // A swap checkpoints the old price before changing reserves. Query two seconds
        // later to exercise the short-interval clamp without fabricating an hour of history.
        vm.warp(vm.getBlockTimestamp() + 2);
        uint256 twapNormal = oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);
        uint256 twapManipulated = oracle.calculateTWAP(1, RESERVE_VENTURE / 100, RESERVE_USDC);

        // The manipulated extrapolation should be clamped
        uint256 diff = twapManipulated > twapNormal ? twapManipulated - twapNormal : twapNormal - twapManipulated;
        uint256 maxDiff = twapNormal; // At most 100% deviation (actually much less)
        assertLt(diff, maxDiff, "Extrapolated TWAP should be bounded by clamping");
    }

    function test_twap_isolatedPerProposal() public {
        // Proposal 1: normal price. Proposal 2: double price.
        _initWithReserves(1, RESERVE_VENTURE, RESERVE_USDC);
        _initWithReserves(2, RESERVE_VENTURE / 2, RESERVE_USDC);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        oracle.update(2, RESERVE_VENTURE / 2, RESERVE_USDC);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 twap1 = oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);
        uint256 twap2 = oracle.calculateTWAP(2, RESERVE_VENTURE / 2, RESERVE_USDC);

        assertGt(twap2, twap1, "Proposal with higher price should have higher TWAP");
        assertEq(twap2 / twap1, 2, "TWAPs should reflect 2x price difference");
    }

    // ═══════════════════════════════════════════════════════════
    // Sustained manipulation scenario
    // ═══════════════════════════════════════════════════════════

    function test_twap_sustainedManipulationOver3Days() public {
        _init(1);
        uint256 basePrice = _seedPrice();

        // Days 1-2: Normal trading (48 hours)
        for (uint256 i = 0; i < 48; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        }

        // Day 3: Attacker manipulates for 24 hours, each update trying a 100x jump
        for (uint256 i = 0; i < 24; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            oracle.update(1, RESERVE_VENTURE / 100, RESERVE_USDC);
        }

        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 twap = oracle.calculateTWAP(1, RESERVE_VENTURE / 100, RESERVE_USDC);

        // 48h of base price + 24h of escalating clamped prices
        // Even sustained manipulation only affects the last 24h/72h of the total window
        // The TWAP should still be substantially anchored by the first 48h
        assertGt(twap, basePrice, "TWAP should be above base due to 24h manipulation");

        // But it should not reach the attacker's target (100x)
        assertLt(twap, basePrice * 50, "TWAP should be far below attacker's 100x target");
    }

    // ═══════════════════════════════════════════════════════════
    // Edge cases
    // ═══════════════════════════════════════════════════════════

    function test_update_veryAsymmetricReserves() public {
        // 18-decimal token with tiny USDC amount (extreme price disparity)
        uint256 bigReserve = 1_000_000_000e18;
        uint256 tinyReserve = 1e6;

        _initWithReserves(1, bigReserve, tinyReserve);
        (, uint256 lastP0,,,,) = oracle.oracleStates(1);
        assertGt(lastP0, 0, "seed observation should be set even with extreme ratio");

        // Update should not overflow
        vm.warp(vm.getBlockTimestamp() + 60);
        oracle.update(1, bigReserve, tinyReserve);
    }

    function test_initialize_singleWeiReserves() public {
        _initWithReserves(1, 1, 1);
        (, uint256 lastP0,,,,) = oracle.oracleStates(1);
        assertEq(lastP0, Q112, "1:1 reserves should give Q112 price");
    }

    function test_twap_correctAfterLongGap() public {
        _init(1);

        // Long gap with no trades (2 days, within the trading window)
        vm.warp(vm.getBlockTimestamp() + 2 days);

        // calculateTWAP should extrapolate the anchored observation
        uint256 twap = oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);
        assertEq(twap, _seedPrice(), "TWAP after long gap should equal extrapolated seed price");
    }

    function test_twap_correctAfterGapThenManipulation() public {
        _init(1);

        // 2 days of no trades
        vm.warp(vm.getBlockTimestamp() + 2 days);

        // The production core checkpoints the unchanged reserves before a swap.
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        uint256 twapNormal = oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);
        uint256 twapSameBlock = oracle.calculateTWAP(1, RESERVE_VENTURE / 100, RESERVE_USDC);
        assertEq(twapSameBlock, twapNormal, "A new spot price cannot rewrite the preceding quiet interval");

        vm.warp(vm.getBlockTimestamp() + 2);
        uint256 twapBad = oracle.calculateTWAP(1, RESERVE_VENTURE / 100, RESERVE_USDC);
        assertLe(twapBad, (twapNormal * 10_001) / 10_000, "Two seconds cannot rewrite two days of history");
    }

    // ═══════════════════════════════════════════════════════════
    // tradingEnd freeze — calculateTWAP()
    // ═══════════════════════════════════════════════════════════

    function test_twap_frozenAfterTradingEnd() public {
        (, uint32 tradingEnd) = _init(1);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);

        vm.warp(tradingEnd);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        uint256 twapAtEnd = oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);

        // Hours later, TWAP should be identical
        vm.warp(uint256(tradingEnd) + 3 hours);
        uint256 twapLater = oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);
        assertEq(twapLater, twapAtEnd, "TWAP should be frozen after tradingEnd");

        // Even much later, and with manipulated reserves
        vm.warp(uint256(tradingEnd) + 30 days);
        uint256 twapMuchLater = oracle.calculateTWAP(1, RESERVE_VENTURE / 100, RESERVE_USDC);
        assertEq(twapMuchLater, twapAtEnd, "TWAP should remain frozen regardless of delay and reserves");
    }

    function test_twap_normalBeforeTradingEnd() public {
        _init(1);

        vm.warp(vm.getBlockTimestamp() + 1000);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        uint256 twap1 = oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);

        vm.warp(vm.getBlockTimestamp() + 1000);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        uint256 twap2 = oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);

        assertEq(twap1, _seedPrice(), "TWAP should work normally before tradingEnd");
        assertEq(twap2, _seedPrice(), "TWAP should work normally before tradingEnd");
    }
}
