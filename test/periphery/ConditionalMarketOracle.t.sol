// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConditionalMarketOracle} from "../../src/periphery/ConditionalMarketOracle.sol";

contract ConditionalMarketOracleHarness is ConditionalMarketOracle {
    constructor(address hub) ConditionalMarketOracle(hub) {}

    function integrate(uint256 target, uint256 start, uint32 dt, uint256 rate, uint256 remainder)
        external
        pure
        returns (uint256 area, uint256 endpoint, uint256 nextRemainder)
    {
        return _integrate(target, start, dt, rate, remainder);
    }
}

contract MockHub {
    address public umiaMarketCore;

    constructor(address core) {
        umiaMarketCore = core;
    }
}

contract ConditionalMarketOracleTest is Test {
    ConditionalMarketOracleHarness oracle;
    MockHub hub;
    uint256 constant Q112 = 1 << 112;
    uint256 constant MAX_PRICE = 1 << 208;
    uint32 constant START = 1000;
    uint32 constant END = START + 3 days;

    function setUp() public {
        vm.warp(START);
        hub = new MockHub(address(this));
        oracle = new ConditionalMarketOracleHarness(address(hub));
    }

    function _init(uint256 id) internal {
        oracle.initialize(id, 1, 40, START, END, 200);
    }

    function test_initialize_seedAndRateAndGetterAbi() public {
        _init(1);
        (uint256 cumulative, uint256 price, uint32 start, uint32 end, uint32 ts, bool initialized) =
            oracle.oracleStates(1);
        assertEq(cumulative, 0);
        assertEq(price, 40 * Q112);
        assertEq(oracle.priceSlewRate(1), Q112);
        assertEq(oracle.cumulativeRemainder(1), 0);
        assertEq(start, START);
        assertEq(end, END);
        assertEq(ts, START);
        assertTrue(initialized);
    }

    function test_initialize_validation() public {
        vm.expectRevert(ConditionalMarketOracle.InvalidReserves.selector);
        oracle.initialize(1, 0, 1, START, END, 200);
        vm.expectRevert(ConditionalMarketOracle.InvalidReserves.selector);
        oracle.initialize(1, 1, 0, START, END, 200);
        vm.expectRevert(ConditionalMarketOracle.InvalidTradingWindow.selector);
        oracle.initialize(1, 1, 1, START, START, 200);
        vm.expectRevert(ConditionalMarketOracle.InvalidWinningThreshold.selector);
        oracle.initialize(1, 1, 1, START, END, 0);
        vm.expectRevert(ConditionalMarketOracle.InvalidWinningThreshold.selector);
        oracle.initialize(1, 1, 1, START, END, 10001);
        _init(1);
        vm.expectRevert(ConditionalMarketOracle.AlreadyInitialized.selector);
        _init(1);
    }

    function test_accessControl() public {
        vm.prank(address(123));
        vm.expectRevert(ConditionalMarketOracle.OnlyMarketCore.selector);
        oracle.initialize(1, 1, 1, START, END, 200);
        vm.prank(address(123));
        vm.expectRevert(ConditionalMarketOracle.OnlyMarketCore.selector);
        oracle.update(1, 1, 1);
    }

    function test_uninitializedAndPreStart() public {
        oracle.update(1, 1, 1);
        vm.expectRevert(ConditionalMarketOracle.ProposalNotInitialized.selector);
        oracle.calculateTWAP(1, 1, 1);
        oracle.initialize(1, 1, 40, START + 10, END, 200);
        oracle.update(1, 1, 1000);
        (uint256 cumulative, uint256 price,,, uint32 ts,) = oracle.oracleStates(1);
        assertEq(cumulative, 0);
        assertEq(price, 40 * Q112);
        assertEq(ts, START + 10);
        vm.expectRevert(ConditionalMarketOracle.TradingNotStarted.selector);
        oracle.calculateTWAP(1, 1, 40);
    }

    function test_sameSecondNoEffect() public {
        _init(1);
        oracle.update(1, 1, 1000000);
        assertEq(oracle.calculateTWAP(1, 1, 1000000), 40 * Q112);
        (uint256 cumulative, uint256 price,,,,) = oracle.oracleStates(1);
        assertEq(cumulative, 0);
        assertEq(price, 40 * Q112);
    }

    function test_constantPrice() public {
        _init(1);
        vm.warp(START + 100);
        oracle.update(1, 1, 40);
        (uint256 cumulative,,,,,) = oracle.oracleStates(1);
        assertEq(cumulative, 4000 * Q112);
        vm.warp(END);
        assertEq(oracle.calculateTWAP(1, 1, 40), 40 * Q112);
    }

    function test_exactRampAndPlateau() public view {
        // Rate 3; distance 5 reaches target after 5/3 seconds. Area = 15*10 -25/6.
        (uint256 area, uint256 endpoint, uint256 remainder) = oracle.integrate(15, 10, 10, 3, 0);
        assertEq(area, 145);
        assertEq(endpoint, 15);
        assertEq(remainder, 5);
        // Downward: 10*10 +25/6 = 104 +1/6.
        (area, endpoint, remainder) = oracle.integrate(10, 15, 10, 3, 0);
        assertEq(area, 104);
        assertEq(endpoint, 10);
        assertEq(remainder, 1);
    }

    function test_exactUnfinishedRamp() public view {
        (uint256 area, uint256 endpoint, uint256 remainder) = oracle.integrate(100, 10, 3, 3, 0);
        assertEq(area, 43); // (10+19)/2 *3 =43.5
        assertEq(endpoint, 19);
        assertEq(remainder, 3);
    }

    function test_sparseAndDenseUpdatesIdentical() public {
        _init(1);
        _init(2);
        for (uint32 i = 1; i <= 100; ++i) {
            vm.warp(START + i);
            oracle.update(1, 1, 97);
        }
        oracle.update(2, 1, 97);
        (uint256 c1, uint256 p1,,,,) = oracle.oracleStates(1);
        (uint256 c2, uint256 p2,,,,) = oracle.oracleStates(2);
        assertEq(c1, c2);
        assertEq(p1, p2);
        assertEq(oracle.cumulativeRemainder(1), oracle.cumulativeRemainder(2));
        // Same price path returning to its seed; sparse and dense recovery must also agree.
        for (uint32 i = 101; i <= 200; ++i) {
            vm.warp(START + i);
            oracle.update(1, 1, 40);
        }
        oracle.update(2, 1, 40);
        (c1, p1,,,,) = oracle.oracleStates(1);
        (c2, p2,,,,) = oracle.oracleStates(2);
        assertEq(c1, c2);
        assertEq(p1, p2);
        assertEq(oracle.cumulativeRemainder(1), oracle.cumulativeRemainder(2));
    }

    function testFuzz_integralPartitionInvariant(uint256 seed, uint256 target, uint32 a, uint32 b) public view {
        seed = bound(seed, 1, MAX_PRICE);
        target = bound(target, 1, MAX_PRICE);
        a = uint32(bound(a, 0, 100000));
        b = uint32(bound(b, 0, 100000));
        uint256 rate = (seed + 39) / 40;
        (uint256 allArea, uint256 allEnd, uint256 allRem) = oracle.integrate(target, seed, a + b, rate, 0);
        (uint256 first, uint256 firstEnd, uint256 firstRem) = oracle.integrate(target, seed, a, rate, 0);
        (uint256 second, uint256 secondEnd, uint256 secondRem) = oracle.integrate(target, firstEnd, b, rate, firstRem);
        assertEq(first + second, allArea);
        assertEq(secondEnd, allEnd);
        assertEq(secondRem, allRem);
    }

    function testFuzz_partitionWithCarryAndIndependentStart(
        uint256 seed,
        uint256 start,
        uint256 target,
        uint32 a,
        uint32 b,
        uint256 carry
    ) public view {
        seed = bound(seed, 1, MAX_PRICE);
        start = bound(start, 1, MAX_PRICE);
        target = bound(target, 1, MAX_PRICE);
        a = uint32(bound(a, 0, type(uint32).max / 2));
        b = uint32(bound(b, 0, type(uint32).max / 2));
        uint256 rate = (seed + 39) / 40;
        carry = bound(carry, 0, rate * 2 - 1);
        (uint256 allArea, uint256 allEnd, uint256 allRem) = oracle.integrate(target, start, a + b, rate, carry);
        (uint256 first, uint256 firstEnd, uint256 firstRem) = oracle.integrate(target, start, a, rate, carry);
        (uint256 second, uint256 secondEnd, uint256 secondRem) = oracle.integrate(target, firstEnd, b, rate, firstRem);
        assertEq(first + second, allArea);
        assertEq(secondEnd, allEnd);
        assertEq(secondRem, allRem);
        assertLt(allRem, 2 * rate);
    }

    function test_mixedDirectionFractionalCarryConservesArea() public view {
        (uint256 risingArea, uint256 endpoint, uint256 remainder) = oracle.integrate(15, 10, 10, 3, 0);
        assertEq(remainder, 5);
        (uint256 fallingArea, uint256 finalEndpoint, uint256 finalRemainder) =
            oracle.integrate(10, endpoint, 10, 3, remainder);
        // Equal opposing ramps cancel their triangular areas, including fractions.
        assertEq(risingArea + fallingArea, 250);
        assertEq(finalEndpoint, 10);
        assertEq(finalRemainder, 0);
    }

    function test_restoredPriceDoesNotLeakAcrossQuietGap() public {
        _init(1);
        vm.warp(START + 1);
        oracle.update(1, 1, 1000000);
        vm.warp(START + 2);
        oracle.update(1, 1, 1000000);
        // Restore raw reserves now. The filter recovers for 2 seconds and then stays at the seed.
        vm.warp(END);
        uint256 preview = oracle.calculateTWAP(1, 1, 40);
        oracle.update(1, 1, 40);
        (uint256 cumulative, uint256 endpoint,,,,) = oracle.oracleStates(1);
        assertEq(endpoint, 40 * Q112);
        assertEq(cumulative, 40 * Q112 * (END - START) + 4 * Q112);
        assertEq(preview, cumulative / (END - START));
        assertLt(preview, 40 * Q112 * 10001 / 10000);
    }

    function test_viewAndStoredIntegralAgreeWithRemainder() public {
        oracle.initialize(1, Q112, 101, START, END, 200); // seed101, rate3
        vm.warp(START + 1);
        oracle.update(1, Q112, 200);
        assertEq(oracle.cumulativeRemainder(1), 3);
        vm.warp(START + 17);
        uint256 preview = oracle.calculateTWAP(1, Q112, 103);
        oracle.update(1, Q112, 103);
        assertEq(oracle.calculateTWAP(1, Q112, 103), preview);
    }

    function test_extremeReservesDoNotOverflow() public {
        oracle.initialize(1, type(uint256).max, type(uint256).max, START, END, 200);
        (, uint256 seed,,,,) = oracle.oracleStates(1);
        assertEq(seed, Q112);
        vm.warp(END);
        oracle.update(1, 1, type(uint256).max);
        oracle.calculateTWAP(1, 1, type(uint256).max);
    }

    function test_saturatedSeedAndTinySeed() public {
        oracle.initialize(1, 1, type(uint256).max, START, END, 200);
        oracle.initialize(2, type(uint256).max, 1, START, END, 200);
        (, uint256 high,,,,) = oracle.oracleStates(1);
        (, uint256 low,,,,) = oracle.oracleStates(2);
        assertEq(high, MAX_PRICE);
        assertEq(low, 1);
        assertEq(oracle.priceSlewRate(2), 1);
        vm.warp(END);
        oracle.update(1, type(uint256).max, 1);
        oracle.update(2, 1, type(uint256).max);
    }

    function test_zeroReservesDoNotConsumeInterval() public {
        _init(1);
        vm.warp(START + 50);
        oracle.update(1, 0, 1);
        (uint256 c,,,, uint32 ts,) = oracle.oracleStates(1);
        assertEq(c, 0);
        assertEq(ts, START);
        vm.warp(START + 100);
        oracle.update(1, 1, 40);
        (c,,,,,) = oracle.oracleStates(1);
        assertEq(c, 4000 * Q112);
    }

    function test_freezeAtTradingEnd() public {
        _init(1);
        vm.warp(END);
        oracle.update(1, 1, 100);
        uint256 twap = oracle.calculateTWAP(1, 1, 100);
        uint256 remainder = oracle.cumulativeRemainder(1);
        vm.warp(END + 30 days);
        oracle.update(1, 1, 1);
        assertEq(oracle.calculateTWAP(1, 1, type(uint256).max), twap);
        assertEq(oracle.cumulativeRemainder(1), remainder);
    }

    function testFuzz_update_invariants(uint256[8] calldata r0s, uint256[8] calldata r1s, uint32[8] calldata dts)
        public
    {
        _init(1);
        uint256 ts = START;
        uint256 previous;
        for (uint256 i; i < 8; ++i) {
            ts += bound(dts[i], 0, 1 days);
            vm.warp(ts);
            oracle.update(1, r0s[i], r1s[i]);
            oracle.calculateTWAP(1, r0s[i], r1s[i]);
            (uint256 cumulative, uint256 price,,, uint32 lastTs,) = oracle.oracleStates(1);
            assertGe(cumulative, previous);
            assertGe(price, 1);
            assertLe(price, MAX_PRICE);
            assertLe(lastTs, END);
            assertLt(oracle.cumulativeRemainder(1), 2 * oracle.priceSlewRate(1));
            previous = cumulative;
        }
    }
}

// Oracle lifecycle cases that do not depend on the clamp.
contract ConditionalMarketOracleLifecycleTest is Test {
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
        tradingStart = uint32(vm.getBlockTimestamp());
        tradingEnd = tradingStart + DURATION;
        oracle.initialize(proposalId, reserve0, reserve1, tradingStart, tradingEnd, THRESHOLD_BPS);
    }

    function _seedPrice() internal pure returns (uint256) {
        return (RESERVE_USDC * Q112) / RESERVE_VENTURE;
    }

    // ═══════════════════════════════════════════════════════════
    // _clampPrice unit tests
    // ═══════════════════════════════════════════════════════════

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
        uint32 start = uint32(vm.getBlockTimestamp());
        vm.expectRevert(ConditionalMarketOracle.InvalidReserves.selector);
        oracle.initialize(1, 0, RESERVE_USDC, start, start + DURATION, THRESHOLD_BPS);

        vm.expectRevert(ConditionalMarketOracle.InvalidReserves.selector);
        oracle.initialize(1, RESERVE_VENTURE, 0, start, start + DURATION, THRESHOLD_BPS);
    }

    function test_initialize_revertsOnEmptyTradingWindow() public {
        uint32 start = uint32(vm.getBlockTimestamp());
        vm.expectRevert(ConditionalMarketOracle.InvalidTradingWindow.selector);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, start, start, THRESHOLD_BPS);

        vm.expectRevert(ConditionalMarketOracle.InvalidTradingWindow.selector);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, start, start - 1, THRESHOLD_BPS);
    }

    function test_initialize_revertsOnInvalidThreshold() public {
        uint32 start = uint32(vm.getBlockTimestamp());
        vm.expectRevert(ConditionalMarketOracle.InvalidWinningThreshold.selector);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, start, start + DURATION, 0);

        vm.expectRevert(ConditionalMarketOracle.InvalidWinningThreshold.selector);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, start, start + DURATION, 10_001);
    }

    function test_initialize_seedNeverZero() public {
        // Reserve skew that floors the raw seed price to zero must anchor at 1, not 0.
        uint32 start = uint32(vm.getBlockTimestamp());
        oracle.initialize(1, 1 << 140, 1, start, start + DURATION, THRESHOLD_BPS);

        (, uint256 lastP0,,,,) = oracle.oracleStates(1);
        assertEq(lastP0, 1, "zero seed price is floored to 1");
    }

    function test_initialize_seedSaturatedToMaxPrice() public {
        uint32 start = uint32(vm.getBlockTimestamp());
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
