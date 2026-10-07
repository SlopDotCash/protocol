// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VentureVestingAuthority} from "../../src/periphery/VentureVestingAuthority.sol";
import {IVentureVestingAuthority} from "../../src/interfaces/IVentureVestingAuthority.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {metavestController} from "@metavest/MetaVesTController.sol";
import {BaseAllocation} from "@metavest/BaseAllocation.sol";
import {VestingAllocationFactory} from "@metavest/VestingAllocationFactory.sol";
import {TokenOptionFactory} from "@metavest/TokenOptionFactory.sol";
import {RestrictedTokenFactory} from "@metavest/RestrictedTokenFactory.sol";
import {TokenOptionAllocation} from "@metavest/TokenOptionAllocation.sol";
import {RestrictedTokenAward} from "@metavest/RestrictedTokenAllocation.sol";

contract VentureVestingRecoverySecurityTest is Test {
    address constant TREASURY = address(0x1000);
    address constant HUB = address(0x2000);
    address constant GRANTEE = address(0x3000);
    VentureVestingAuthority adapter;
    metavestController controller;
    MockERC20 token;
    MockERC20 payment;
    address option;
    address restricted;

    function setUp() public {
        vm.warp(1_000_000);
        token = new MockERC20("Venture", "V", 18);
        payment = new MockERC20("Payment", "P", 18);
        controller = new metavestController(
            address(this),
            address(this),
            address(new VestingAllocationFactory()),
            address(new TokenOptionFactory()),
            address(new RestrictedTokenFactory())
        );
        adapter = new VentureVestingAuthority(HUB, address(controller));
        controller.initiateAuthorityUpdate(address(adapter));
        adapter.claim();
        token.mint(address(this), 2_000 ether);
        token.approve(address(adapter), type(uint256).max);
        option = _create(metavestController.metavestType.TokenOption);
        restricted = _create(metavestController.metavestType.RestrictedTokenAward);
        IUmiaHub.VentureInfo memory info = IUmiaHub.VentureInfo(1, TREASURY, "venture", 0);
        vm.mockCall(HUB, abi.encodeWithSelector(IUmiaHub.ventureById.selector, 1), abi.encode(info));
        vm.mockCall(TREASURY, abi.encodeWithSelector(IVenture.token.selector), abi.encode(address(token)));
        vm.mockCall(TREASURY, abi.encodeWithSelector(IVenture.liquidationActive.selector), abi.encode(false));
        adapter.bind(1);
        vm.warp(block.timestamp + 100);
        vm.startPrank(TREASURY);
        adapter.terminateGrant(option);
        adapter.terminateGrant(restricted);
        vm.stopPrank();
    }

    function _create(metavestController.metavestType kind) internal returns (address) {
        BaseAllocation.Allocation memory allocation = BaseAllocation.Allocation({
            tokenStreamTotal: 1_000 ether,
            vestingCliffCredit: 0,
            unlockingCliffCredit: 0,
            vestingRate: 1 ether,
            vestingStartTime: uint48(block.timestamp),
            unlockRate: 1 ether,
            unlockStartTime: uint48(block.timestamp),
            tokenContract: address(token)
        });
        bytes memory data = abi.encodeCall(
            controller.createMetavest,
            (kind, GRANTEE, allocation, new BaseAllocation.Milestone[](0), 1 ether, address(payment), 1 days, 0)
        );
        IVentureVestingAuthority.PriceProgramInput memory program;
        return adapter.fundGenesisGrant(address(token), 1_000 ether, data, program);
    }

    function test_expiredOptionCollateralReturnsToTreasury() public {
        assertEq(token.balanceOf(option), 100 ether);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(TREASURY);
        adapter.recoverForfeitedOptions(option);
        assertEq(token.balanceOf(option), 0);
        assertEq(token.balanceOf(TREASURY), 1_000 ether);
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    function test_repurchasePaysGranteeAndReturnsCollateralWithoutResidualApproval() public {
        vm.warp(block.timestamp + 1 days + 1);
        payment.mint(address(adapter), 950 ether);
        vm.prank(TREASURY);
        adapter.repurchaseRestrictedTokens(restricted, 900 ether);
        assertEq(token.balanceOf(TREASURY), 1_800 ether);
        assertEq(token.balanceOf(restricted), 100 ether);
        assertEq(payment.balanceOf(restricted), 900 ether);
        assertEq(payment.balanceOf(TREASURY), 50 ether);
        assertEq(payment.allowance(address(adapter), restricted), 0);
        vm.prank(GRANTEE);
        RestrictedTokenAward(restricted).claimRepurchasedTokens();
        assertEq(payment.balanceOf(GRANTEE), 900 ether);
    }

    function test_recoveryRespectsOriginalExerciseWindow() public {
        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.RecoveryWindowOpen.selector);
        adapter.recoverForfeitedOptions(option);
    }

    function test_optionRecoveryCannotRaceExerciseAtExactDeadline() public {
        vm.warp(TokenOptionAllocation(option).shortStopTime());
        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.RecoveryWindowOpen.selector);
        adapter.recoverForfeitedOptions(option);
        payment.mint(GRANTEE, 100 ether);
        vm.startPrank(GRANTEE);
        payment.approve(option, 100 ether);
        TokenOptionAllocation(option).exerciseTokenOption(100 ether);
        TokenOptionAllocation(option).withdraw(100 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(GRANTEE), 100 ether);
    }

    function test_optionRecoveryPreservesExercisedButUnwithdrawnTokens() public {
        payment.mint(GRANTEE, 50 ether);
        vm.startPrank(GRANTEE);
        payment.approve(option, 50 ether);
        TokenOptionAllocation(option).exerciseTokenOption(50 ether);
        vm.stopPrank();
        vm.warp(TokenOptionAllocation(option).shortStopTime() + 1);
        vm.prank(TREASURY);
        adapter.recoverForfeitedOptions(option);
        assertEq(token.balanceOf(TREASURY), 950 ether);
        assertEq(token.balanceOf(option), 50 ether);
        vm.prank(GRANTEE);
        TokenOptionAllocation(option).withdraw(50 ether);
        assertEq(token.balanceOf(GRANTEE), 50 ether);
    }

    function test_onlyTreasuryMayRecoverOrSpend() public {
        vm.expectRevert(IVentureVestingAuthority.NotTreasury.selector);
        adapter.recoverForfeitedOptions(option);
        vm.expectRevert(IVentureVestingAuthority.NotTreasury.selector);
        adapter.repurchaseRestrictedTokens(restricted, 1);
    }

    function test_unknownAllocationCannotReceiveAllowance() public {
        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.InvalidRecoveryAllocation.selector);
        adapter.repurchaseRestrictedTokens(address(0xBAD), 1);
    }

    function test_recoveryRejectsWrongAllocationType() public {
        vm.startPrank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.InvalidRecoveryAllocation.selector);
        adapter.recoverForfeitedOptions(restricted);
        vm.expectRevert(IVentureVestingAuthority.InvalidRecoveryAllocation.selector);
        adapter.repurchaseRestrictedTokens(option, 1);
        vm.stopPrank();
    }

    function test_recoveryDisabledDuringLiquidation() public {
        vm.mockCall(TREASURY, abi.encodeWithSelector(IVenture.liquidationActive.selector), abi.encode(true));
        vm.startPrank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.LiquidationActive.selector);
        adapter.recoverForfeitedOptions(option);
        vm.expectRevert(IVentureVestingAuthority.LiquidationActive.selector);
        adapter.repurchaseRestrictedTokens(restricted, 1);
        vm.stopPrank();
    }
}
