// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LaunchAuditValidationReplayTest} from "./LaunchAuditValidationReplay.t.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";

contract LaunchAuditPermitAuthorizationTest is LaunchAuditValidationReplayTest {
    uint256 constant PERMIT_KEY = 789012;
    bytes32 constant NONCE = keccak256("independent-permit");

    function setUp() public override {
        super.setUp();
        hook.setSigner(vm.addr(PERMIT_KEY));
        hook.enableStepPermit(0);
        hook.setStepMaxBidAmount(0, 1);
        hook.setZkGlobalMaxBidAmount(1);
        vm.roll(100);
    }

    function _permit(uint256 chainId, uint256 deadline, uint256 key) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(hook.DOMAIN_TYPEHASH(), keccak256("UmiaValidationHook"), keccak256("1"), chainId, address(hook))
        );
        bytes32 structure =
            keccak256(abi.encode(hook.SERVER_PERMIT_TYPEHASH(), USER, uint256(0), NONCE, deadline, uint128(10)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structure)));
        return abi.encodePacked(bytes1(0x01), abi.encode(uint256(0), NONCE, deadline, abi.encodePacked(r, s, v)));
    }

    function _registerAsStranger() internal {
        bytes memory proof = abi.encode(_proof());
        vm.prank(address(0xBAD));
        hook.submitProof(USER, 0, proof);
    }

    function test_preRegistrationCannotOverrideExplicitPermitBudget() public {
        bytes memory permit = _permit(block.chainid, block.timestamp + 100, PERMIT_KEY);
        _registerAsStranger();
        vm.prank(address(cca));
        hook.validate(0, 10, USER, USER, permit);
        assertTrue(hook.isPermitNonceUsed(NONCE));
        assertEq(hook.zkBidTotal(USER, 0), 0);
        assertEq(hook.zkGlobalBidTotal(), 0);
    }

    function test_verifiedWalletRejectsMalformedExplicitPermit() public {
        _registerAsStranger();
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        vm.prank(address(cca));
        hook.validate(0, 1, USER, USER, hex"01");
    }

    function test_verifiedWalletRejectsConsumedExplicitPermit() public {
        _registerAsStranger();
        bytes memory permit = _permit(block.chainid, block.timestamp + 100, PERMIT_KEY);
        vm.prank(address(cca));
        hook.validate(0, 10, USER, USER, permit);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.PermitAlreadyUsed.selector, NONCE));
        vm.prank(address(cca));
        hook.validate(0, 10, USER, USER, permit);
    }

    function test_verifiedWalletStillRejectsInvalidExplicitPermit() public {
        _registerAsStranger();
        bytes memory permit = _permit(block.chainid, block.timestamp + 100, PERMIT_KEY + 1);
        vm.expectRevert(UmiaValidationHook.InvalidSignature.selector);
        vm.prank(address(cca));
        hook.validate(0, 10, USER, USER, permit);
        assertFalse(hook.isPermitNonceUsed(NONCE));
    }

    function test_verifiedWalletStillRejectsExpiredExplicitPermit() public {
        _registerAsStranger();
        uint256 deadline = block.timestamp;
        bytes memory permit = _permit(block.chainid, deadline, PERMIT_KEY);
        vm.warp(deadline + 1);
        vm.expectRevert(UmiaValidationHook.ExpiredDeadline.selector);
        vm.prank(address(cca));
        hook.validate(0, 10, USER, USER, permit);
    }

    function test_disabledPermitCannotBypassVerifiedWalletCap() public {
        _registerAsStranger();
        hook.disableStepPermit(0);
        bytes memory permit = _permit(block.chainid, block.timestamp + 100, PERMIT_KEY);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsGlobalCap.selector, USER, 10, 1));
        vm.prank(address(cca));
        hook.validate(0, 10, USER, USER, permit);
        assertFalse(hook.isPermitNonceUsed(NONCE));
    }
}
