// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";
import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";

/// @notice Settlement returns the decision market's excess to the spot vault. Settlement is
///         permissionless, so a caller can move spot anywhere inside the vault's 1000-tick sandwich
///         band, settle, and swap back — harvesting the divergence loss on the re-added liquidity.
///         The add is now gated on a ~100-tick band; outside it the return stays idle and settlement
///         still succeeds.
contract SettlementReAddSandwichTest is DecisionMarketBase {
    using PoolIdLibrary for PoolKey;

    ISpotLiquidityVault internal vault;
    PoolId internal poolId;
    int24 internal anchorTick;

    function setUp() public override {
        super.setUp();
        _createVentureAndMarket();
        vault = ISpotLiquidityVault(hub.ventureLiquidityVault(venture));
        poolId = vault.getPoolKey().toId();
        // Trading ends; spot has sat still long enough for the 30-minute TWAP to equal it.
        vm.warp(_marketById(marketId).tradingEnd + 1 hours);
        anchorTick = _spotTick();
    }

    function _spotTick() internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), poolId);
    }

    function _deviation() internal view returns (int24) {
        int24 t = _spotTick();
        return t > anchorTick ? t - anchorTick : anchorTick - t;
    }

    /// @dev Same-block buys until spot sits at least `minTicks` from the TWAP anchor. The fixture
    ///      pool is thin, so step in 0.01 USDC increments to land inside a band, not leap past it.
    function _pushSpot(int24 minTicks) internal {
        for (uint256 i; i < 2000 && _deviation() < minTicks; ++i) {
            _swapSpot(venture, 1e4, true);
        }
        assertGe(_deviation(), minTicks, "spot not displaced");
    }

    function _idle() internal view returns (uint256 v, uint256 m) {
        v = IERC20(vault.ventureToken()).balanceOf(address(vault));
        m = IERC20(vault.moneyToken()).balanceOf(address(vault));
    }

    function test_settle_inBandReAddsLiquidity() public {
        uint128 liqBefore = vault.currentLiquidity();
        mm.settleMarket(marketId);
        assertGt(vault.currentLiquidity(), liqBefore, "in-band return folds into the position");
    }

    function test_settle_displacedSpotLeavesReturnIdle() public {
        _pushSpot(200);
        assertLt(_deviation(), 1000, "inside the legacy sandwich band");

        uint128 liqBefore = vault.currentLiquidity();
        (uint256 idleVBefore, uint256 idleMBefore) = _idle();
        mm.settleMarket(marketId);

        assertEq(vault.currentLiquidity(), liqBefore, "no liquidity added at a displaced spot");
        (uint256 idleV, uint256 idleM) = _idle();
        assertGt(idleV + idleM, idleVBefore + idleMBefore, "returned excess held idle");
        assertEq(vault.totalDeployedVenture() + vault.totalDeployedMoney(), 0, "deployment record cleared");
    }

    function test_settle_succeedsBeyondLegacyBand() public {
        // Previously `returnFromDecisionMarket` reverted SpotPriceDeviationTooHigh here, so anyone
        // holding spot >10% off TWAP could block settlement and every claim.
        _pushSpot(1100);
        uint128 liqBefore = vault.currentLiquidity();
        mm.settleMarket(marketId);
        assertEq(vault.currentLiquidity(), liqBefore, "no add outside the band");
    }

    function test_addIdleLiquidity_revertsWhileDisplaced() public {
        _pushSpot(200);
        mm.settleMarket(marketId);
        vm.expectRevert(ISpotLiquidityVault.SpotPriceDeviationTooHigh.selector);
        vault.addIdleLiquidity();
    }

    function test_addIdleLiquidity_foldsOnceTwapCatchesUp() public {
        _pushSpot(200);
        mm.settleMarket(marketId);
        uint128 liqBefore = vault.currentLiquidity();

        // Spot holds at the new level: once the TWAP converges, anyone can fold the idle return.
        vm.warp(block.timestamp + 1);
        _swapSpot(venture, 1e6, true); // dust swap records the displaced tick
        vm.warp(block.timestamp + 31 minutes);

        assertGt(vault.addIdleLiquidity(), 0, "idle folded");
        assertGt(vault.currentLiquidity(), liqBefore, "position grew");
    }
}
