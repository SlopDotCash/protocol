// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Venture} from "../../src/core/Venture.sol";
import {VentureToken} from "../../src/tokens/VentureToken.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";
import {TradingPauseTest} from "../launchpad/TradingPause.t.sol";

/// @notice While the post-migration trading pause is active, ERC20 transfers of the venture token
///         revert, but the v4 pool could still be traded through ERC6909 claims. Only the buyer then
///         holds sellable inventory, so a pumped price could not be arbitraged back and the spot
///         TWAP — which gates price-milestone vesting — would read the pumped price for as long as
///         the pause lasted. The hook must refuse swaps on a paused venture's pool.
contract PausedPoolSwapGateTest is TradingPauseTest {
    using PoolIdLibrary for PoolKey;

    address internal pumper = makeAddr("pumper");

    function _key(address ventureAddr) internal view returns (PoolKey memory) {
        return ISpotLiquidityVault(hub.ventureLiquidityVault(ventureAddr)).getPoolKey();
    }

    function _buyVentureAsClaims(address ventureAddr, uint256 moneyIn) internal {
        PoolKey memory key = _key(ventureAddr);
        bool ventureIsCurrency0 = Currency.unwrap(key.currency0) == Venture(payable(ventureAddr)).token();
        bool zeroForOne = !ventureIsCurrency0;
        usdc.mint(pumper, moneyIn);
        vm.startPrank(pumper);
        usdc.approve(address(swapRouter), moneyIn);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(moneyIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_pausedPool_rejectsClaimSettledSwaps() public {
        (, address payable ventureAddr) = _createVentureWithPause(alice, 60 days);
        assertTrue(VentureToken(Venture(payable(ventureAddr)).token()).paused());

        vm.warp(block.timestamp + 1);
        // Buying venture as ERC6909 claims needs no venture ERC20 transfer, so only the hook can stop it.
        vm.expectRevert();
        this.externalBuy(ventureAddr, 1_000_000e18);

        // The pool price cannot move until trading starts.
        (uint160 sqrtBefore,,,) = stateView.getSlot0(_key(ventureAddr).toId());
        vm.warp(block.timestamp + 40 days);
        (uint160 sqrtAfter,,,) = stateView.getSlot0(_key(ventureAddr).toId());
        assertEq(sqrtAfter, sqrtBefore);
    }

    function test_pausedPool_swapsResumeAfterTradingStarts() public {
        (, address payable ventureAddr) = _createVentureWithPause(alice, 60 days);
        vm.prank(alice);
        Venture(payable(ventureAddr)).startTrading();

        vm.warp(block.timestamp + 1);
        (uint160 sqrtBefore,,,) = stateView.getSlot0(_key(ventureAddr).toId());
        _buyVentureAsClaims(ventureAddr, 1_000e18);
        (uint160 sqrtAfter,,,) = stateView.getSlot0(_key(ventureAddr).toId());
        assertTrue(sqrtAfter != sqrtBefore, "swap after unpause must move the price");
    }

    function test_unpausedVenture_swapsUnaffected() public {
        (, address payable ventureAddr) = _createVentureWithLBP(hub, alice);
        assertFalse(VentureToken(Venture(payable(ventureAddr)).token()).paused());
        vm.warp(block.timestamp + 1);
        _buyVentureAsClaims(ventureAddr, 1_000e18);
    }

    function externalBuy(address ventureAddr, uint256 moneyIn) external {
        _buyVentureAsClaims(ventureAddr, moneyIn);
    }
}
