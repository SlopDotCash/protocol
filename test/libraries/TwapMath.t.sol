// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TwapMath} from "../../src/libraries/TwapMath.sol";

contract TwapMathTest is Test {
    function test_PositiveCumulativeWrap() public pure {
        assertEq(TwapMath.averageTick(type(int48).max - 9, type(int48).min + 10, 2), 10);
    }

    function test_NegativeCumulativeWrapFloors() public pure {
        assertEq(TwapMath.averageTick(type(int48).min + 9, type(int48).max - 10, 3), -7);
    }

    function testFuzz_ModularAverageMatchesWideDelta(int48 older, int24 tick, uint32 window) public pure {
        // Exercise supported windows and arbitrary accumulator offsets, including wrap.
        window = uint32(bound(window, 1, uint256(uint48(type(int48).max)) / 887272));
        tick = int24(bound(int256(tick), -887272, 887272));
        int256 delta = int256(tick) * int256(uint256(window));
        int48 newer = int48(int256(older) + delta);
        assertEq(TwapMath.averageTick(older, newer, window), tick);
    }
}
