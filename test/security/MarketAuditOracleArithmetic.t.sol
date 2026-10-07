// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConditionalMarketOracle} from "../../src/periphery/ConditionalMarketOracle.sol";

contract MarketAuditOracleHub {
    address public umiaMarketCore;

    constructor(address core) {
        umiaMarketCore = core;
    }
}

contract MarketAuditOracleArithmeticTest is Test {
    ConditionalMarketOracle internal oracle;
    uint256 internal constant Q112 = 1 << 112;
    uint256 internal constant CAP = 1 << 208;

    function setUp() public {
        vm.warp(1000);
        oracle = new ConditionalMarketOracle(address(new MarketAuditOracleHub(address(this))));
    }

    function test_largeReservesPreserveRepresentableRatioThroughSettlement() public {
        uint256 reserve = 1 << 200;
        oracle.initialize(1, reserve, reserve, 1000, 2000, 200);
        vm.warp(1500);
        oracle.update(1, reserve, reserve);
        assertEq(oracle.calculateTWAP(1, reserve, reserve), Q112);
        vm.warp(2000);
        oracle.update(1, reserve, reserve);
        assertEq(oracle.calculateTWAP(1, reserve, reserve), Q112);
    }

    function test_unrepresentableRawRatioSaturatesBeforeMultiplication() public {
        oracle.initialize(1, 1, type(uint256).max, 1000, 2000, 200);
        vm.warp(2000);
        oracle.update(1, 1, type(uint256).max);
        assertEq(oracle.calculateTWAP(1, 1, type(uint256).max), CAP);
    }

    function testFuzz_allPositiveReservePairsRemainReadable(uint256 reserve0, uint256 reserve1) public {
        reserve0 = bound(reserve0, 1, type(uint256).max);
        reserve1 = bound(reserve1, 1, type(uint256).max);
        oracle.initialize(1, reserve0, reserve1, 1000, 2000, 200);
        vm.warp(1500);
        oracle.update(1, reserve0, reserve1);
        vm.warp(2000);
        uint256 twap = oracle.calculateTWAP(1, reserve0, reserve1);
        assertGt(twap, 0);
        assertLe(twap, CAP);
    }
}
