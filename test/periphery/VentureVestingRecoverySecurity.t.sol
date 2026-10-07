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
    MockERC20 otherToken;
    address otherOption;
    address otherRestricted;

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
        otherToken = new MockERC20("Other funded grant", "OTHER", 18);
        otherToken.mint(address(this), 2_000 ether);
        otherToken.approve(address(adapter), type(uint256).max);
        otherOption = _createWithToken(metavestController.metavestType.TokenOption, address(otherToken));
        otherRestricted = _createWithToken(metavestController.metavestType.RestrictedTokenAward, address(otherToken));
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
        return _createWithToken(kind, address(token));
    }

    function _createWithToken(metavestController.metavestType kind, address grantToken) internal returns (address) {
        BaseAllocation.Allocation memory allocation = BaseAllocation.Allocation({
            tokenStreamTotal: 1_000 ether,
            vestingCliffCredit: 0,
            unlockingCliffCredit: 0,
            vestingRate: 1 ether,
            vestingStartTime: uint48(block.timestamp),
            unlockRate: 1 ether,
            unlockStartTime: uint48(block.timestamp),
            tokenContract: grantToken
        });
        bytes memory data = abi.encodeCall(
            controller.createMetavest,
            (kind, GRANTEE, allocation, new BaseAllocation.Milestone[](0), 1 ether, address(payment), 1 days, 0)
        );
        IVentureVestingAuthority.PriceProgramInput memory program;
        return adapter.fundGenesisGrant(grantToken, 1_000 ether, data, program);
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

    function test_registeredNonVentureOptionCollateralIsRecoverable() public {
        vm.prank(TREASURY);
        adapter.terminateGrant(otherOption);
        // Non-venture genesis grants are permitted; their collateral must remain recoverable too.
        adapter.sweep(address(otherToken));
        vm.warp(TokenOptionAllocation(otherOption).shortStopTime() + 1);
        vm.prank(TREASURY);
        adapter.recoverForfeitedOptions(otherOption);
        assertEq(otherToken.balanceOf(TREASURY), 1_000 ether);
        assertEq(otherToken.balanceOf(otherOption), 0);
    }

    function test_registeredNonVentureRestrictedCollateralIsRecoverable() public {
        vm.prank(TREASURY);
        adapter.terminateGrant(otherRestricted);
        adapter.sweep(address(otherToken));
        vm.warp(block.timestamp + 1 days + 1);
        payment.mint(address(adapter), 900 ether);
        vm.prank(TREASURY);
        adapter.repurchaseRestrictedTokens(otherRestricted, 900 ether);
        assertEq(otherToken.balanceOf(TREASURY), 900 ether);
        assertEq(payment.allowance(address(adapter), otherRestricted), 0);
        assertEq(otherToken.balanceOf(address(adapter)), 0);
    }

    function _aliasFixture() internal returns (metavestController fresh, VentureVestingAuthority freshAdapter) {
        fresh = new metavestController(
            address(this),
            address(this),
            address(new VestingAllocationFactory()),
            address(new TokenOptionFactory()),
            address(new RestrictedTokenFactory())
        );
        freshAdapter = new VentureVestingAuthority(HUB, address(fresh));
        fresh.initiateAuthorityUpdate(address(freshAdapter));
        freshAdapter.claim();
    }

    function test_restrictedPaymentCannotAliasCollateralAndFundingRollsBack() public {
        (metavestController fresh, VentureVestingAuthority freshAdapter) = _aliasFixture();
        BaseAllocation.Allocation memory allocation = BaseAllocation.Allocation({
            tokenStreamTotal: 1_000 ether,
            vestingCliffCredit: 0,
            unlockingCliffCredit: 0,
            vestingRate: 1 ether,
            vestingStartTime: uint48(block.timestamp + 1 days),
            unlockRate: 1 ether,
            unlockStartTime: uint48(block.timestamp + 1 days),
            tokenContract: address(token)
        });
        bytes memory data = abi.encodeCall(
            fresh.createMetavest,
            (
                metavestController.metavestType.RestrictedTokenAward,
                GRANTEE,
                allocation,
                new BaseAllocation.Milestone[](0),
                1 ether,
                address(token),
                1 days,
                0
            )
        );
        token.mint(address(this), 1_000 ether);
        token.approve(address(freshAdapter), 1_000 ether);
        uint256 beforeBalance = token.balanceOf(address(this));
        IVentureVestingAuthority.PriceProgramInput memory program;
        vm.expectRevert(IVentureVestingAuthority.PaymentTokenMatchesAllocationToken.selector);
        freshAdapter.fundGenesisGrant(address(token), 1_000 ether, data, program);
        assertEq(token.balanceOf(address(this)), beforeBalance);
        assertEq(token.balanceOf(address(freshAdapter)), 0);
        assertEq(token.allowance(address(freshAdapter), address(fresh)), 0);
    }
}
