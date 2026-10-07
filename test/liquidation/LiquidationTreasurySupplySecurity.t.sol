// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "../mocks/MockERC20.sol";
import {GovernanceActions} from "../../src/libraries/GovernanceActions.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {LiquidationAccountingFixTest} from "./LiquidationAccountingFix.t.sol";

contract LiquidationTransferFeeToken is MockERC20 {
    constructor() MockERC20("Fee", "FEE", 18) {}

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = amount / 10;
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}

contract LiquidationTreasurySupplySecurityTest is LiquidationAccountingFixTest {
    function test_standingApprovalCannotRecirculateExcludedClaimTokens() public {
        address spender = makeAddr("standing-spender");
        _mint(alice, 100e18);
        _mint(address(venture), 100e18);
        assetToken.mint(address(venture), 1000e18);
        vm.prank(address(executor));
        venture.setAllowance(address(qToken), spender, type(uint256).max);

        _startLiquidation(_erc20Asset(address(assetToken)));
        assertEq(qToken.balanceOf(address(venture)), 0);
        assertEq(qToken.totalSupply(), liquidator.totalSupplySnapshot());
        vm.prank(spender);
        vm.expectRevert();
        qToken.transferFrom(address(venture), spender, 100e18);

        vm.prank(alice);
        liquidator.claim();
        assertEq(assetToken.balanceOf(alice), 1000e18);
        assertEq(qToken.totalSupply(), 0);
    }

    function test_standingAssetApprovalCannotDrainClaimBacking() public {
        address spender = makeAddr("asset-spender");
        _mint(alice, 100e18);
        assetToken.mint(address(venture), 1000e18);
        vm.prank(address(executor));
        venture.setAllowance(address(assetToken), spender, type(uint256).max);

        _startLiquidation(_erc20Asset(address(assetToken)));
        assertEq(assetToken.balanceOf(address(venture)), 0);
        assertEq(assetToken.balanceOf(address(liquidator)), 1000e18);
        vm.prank(spender);
        vm.expectRevert();
        assetToken.transferFrom(address(venture), spender, 1000e18);

        vm.prank(alice);
        liquidator.claim();
        assertEq(assetToken.balanceOf(alice), 1000e18);
        assertEq(assetToken.balanceOf(address(liquidator)), 0);
    }

    function testFuzz_claimBackingConserved(uint96 aliceUnits, uint96 bobUnits, uint96 treasuryUnits) public {
        uint256 a = bound(uint256(aliceUnits), 1, 1e24);
        uint256 b = bound(uint256(bobUnits), 1, 1e24);
        uint256 t = bound(uint256(treasuryUnits), 0, 1e24);
        _mint(alice, a);
        _mint(bob, b);
        if (t != 0) _mint(address(venture), t);
        assetToken.mint(address(venture), 1e27);

        _startLiquidation(_erc20Asset(address(assetToken)));
        assertEq(liquidator.totalSupplySnapshot(), a + b);
        assertEq(qToken.totalSupply(), a + b);
        vm.prank(alice);
        liquidator.claim();
        vm.prank(bob);
        liquidator.claim();
        assertEq(qToken.totalSupply(), 0);
        assertEq(assetToken.balanceOf(alice), 1e27 * a / (a + b));
        assertEq(assetToken.balanceOf(bob), 1e27 * b / (a + b));
        assertLe(assetToken.balanceOf(address(liquidator)), 1);
    }

    function test_zeroCirculatingSupplyRollsBackTreasuryBurn() public {
        _mint(address(venture), 100e18);
        assetToken.mint(address(venture), 1000e18);
        GovernanceTypes.LiquidationAsset[] memory assets = _erc20Asset(address(assetToken));
        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _startLiquidation(assets);
        assertEq(qToken.balanceOf(address(venture)), 100e18);
        assertEq(qToken.totalSupply(), 100e18);
        assertEq(assetToken.balanceOf(address(venture)), 1000e18);
        assertFalse(venture.liquidationActive());
        assertFalse(liquidator.initialized());
    }

    function test_nativeBackingEscrowedAndFullyPaid() public {
        _mint(alice, 100e18);
        vm.deal(address(venture), 10 ether);
        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset(GovernanceTypes.AssetType.NATIVE, address(0), 0);
        _startLiquidation(assets);
        assertEq(address(venture).balance, 0);
        assertEq(address(liquidator).balance, 10 ether);
        uint256 beforeBalance = alice.balance;
        vm.prank(alice);
        liquidator.claim();
        assertEq(alice.balance - beforeBalance, 10 ether);
        assertEq(address(liquidator).balance, 0);
    }

    function test_transferFeeSnapshotUsesReceivedBacking() public {
        LiquidationTransferFeeToken feeToken = new LiquidationTransferFeeToken();
        _mint(alice, 100e18);
        feeToken.mint(address(venture), 1000e18);
        _startLiquidation(_erc20Asset(address(feeToken)));
        (,,, uint256 snapshot) = liquidator.liquidationAssets(0);
        assertEq(snapshot, 900e18);
        vm.prank(alice);
        liquidator.claim();
        assertEq(feeToken.balanceOf(alice), 810e18);
        assertEq(feeToken.balanceOf(address(liquidator)), 0);
    }

    function test_treasuryClaimTokensRetiredWhileTransfersPaused() public {
        _mint(alice, 100e18);
        _mint(address(venture), 100e18);
        assetToken.mint(address(venture), 1000e18);
        vm.prank(address(venture));
        qToken.pause();

        _startLiquidation(_erc20Asset(address(assetToken)));
        assertTrue(qToken.paused());
        assertEq(qToken.balanceOf(address(venture)), 0);
        assertEq(liquidator.totalSupplySnapshot(), 100e18);
        vm.prank(alice);
        liquidator.claim();
        assertEq(assetToken.balanceOf(alice), 1000e18);
    }
}
