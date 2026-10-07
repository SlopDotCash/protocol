// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Reclaim} from "../../src/reclaim/Reclaim.sol";
import {Claims} from "../../src/reclaim/Claims.sol";
import {StringUtils} from "../../src/reclaim/StringUtils.sol";
import {SimpleLiquidatorTest} from "../liquidation/SimpleLiquidator.t.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";

contract GovernanceAuditReclaim is Test {
    Reclaim internal verifier;
    uint256 internal constant OLD_KEY = 123456;

    function setUp() public {
        vm.warp(1_800_000_000);
        verifier = new Reclaim();
        _rotate(OLD_KEY);
    }

    function _rotate(uint256 key) internal {
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](1);
        witnesses[0] = Reclaim.Witness(vm.addr(key), "wss://audit.example");
        verifier.addNewEpoch(witnesses, 1);
    }

    function _proof() internal returns (Reclaim.Proof memory proof) {
        proof.claimInfo = Claims.ClaimInfo("http", "params", "victim-specific-context");
        proof.signedClaim.claim = Claims.CompleteClaimData({
            identifier: Claims.hashClaimInfo(proof.claimInfo),
            owner: address(0xA11CE),
            timestampS: uint32(block.timestamp),
            epoch: 2
        });
        bytes memory message = Claims.serialise(proof.signedClaim.claim);
        bytes32 digest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n", StringUtils.uint2str(message.length), message)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OLD_KEY, digest);
        proof.signedClaim.signatures = new bytes[](1);
        proof.signedClaim.signatures[0] = abi.encodePacked(r, s, v);
    }

    function test_Audit_UnrelatedCallerCannotConsumeVictimProof() public {
        Reclaim.Proof memory proof = _proof();
        vm.prank(address(0xBAD));
        verifier.verifyProof(proof);
        assertTrue(verifier.usedProofs(proof.signedClaim.claim.identifier));
        vm.prank(proof.signedClaim.claim.owner);
        verifier.verifyProof(proof);
    }

    function test_Audit_RetiredWitnessCannotSignFreshClaims() public {
        vm.warp(block.timestamp + 1 days);
        _rotate(987654);
        uint256 oldEpochEnd = verifier.fetchEpoch(2).timestampEnd;
        vm.warp(block.timestamp + 30 days);
        Reclaim.Proof memory proof = _proof();
        assertGt(proof.signedClaim.claim.timestampS, oldEpochEnd);
        assertEq(verifier.currentEpoch(), 3);
        vm.expectRevert("Proof after epoch ended");
        verifier.verifyProof(proof);
        assertFalse(verifier.usedProofs(proof.signedClaim.claim.identifier));
    }

    function test_Audit_RevokedWitnessCannotBackdateClaims() public {
        Reclaim.Proof memory proof = _proof();
        _rotate(987654);
        verifier.revokeEpoch(2);
        vm.expectRevert("Epoch revoked");
        verifier.verifyProof(proof);
    }

    function test_Audit_CurrentEpochAdvisoryEndDoesNotExpireWitness() public {
        vm.warp(block.timestamp + 30 days);
        verifier.verifyProof(_proof());
    }

    function test_Audit_OnlyOwnerCanRevokeWitness() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("Only Owner");
        verifier.revokeEpoch(2);
    }
}

contract GovernanceAuditLiquidation is SimpleLiquidatorTest {
    function test_Audit_ExcludedTreasuryTokensCannotOverclaimThroughStandingApproval() public {
        address spender = makeAddr("previously-approved-spender");
        vm.startPrank(address(executor));
        venture.mint(alice, 100e18);
        venture.mint(address(venture), 100e18);
        venture.setAllowance(address(qToken), spender, 100e18);
        vm.stopPrank();
        assetToken.mint(address(venture), 1000e18);
        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset(GovernanceTypes.AssetType.ERC20, address(assetToken), 0);
        _startLiquidation(assets); // fixture adds 1 token held by team1
        assertEq(liquidator.totalSupplySnapshot(), 101e18);
        assertEq(qToken.balanceOf(address(venture)), 0);
        assertEq(qToken.totalSupply(), 101e18);
        vm.prank(spender);
        vm.expectRevert();
        qToken.transferFrom(address(venture), spender, 100e18);
        assertEq(assetToken.balanceOf(spender), 0);
        vm.prank(alice);
        liquidator.claim();
        assertEq(assetToken.balanceOf(alice), uint256(1000e18) * 100 / 101);
        assertEq(qToken.balanceOf(alice), 0);
    }
}
