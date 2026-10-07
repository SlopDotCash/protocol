// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";
import {Reclaim} from "../../src/reclaim/Reclaim.sol";
import {Claims} from "../../src/reclaim/Claims.sol";
import {SSTORE2} from "@solady/utils/SSTORE2.sol";
import {AuctionStep} from "@continuous-clearing-auction/libraries/StepLib.sol";

contract LaunchAuditValidationCCA {
    address public pointer = SSTORE2.write(abi.encodePacked(uint24(100_000), uint40(100)));
    uint64 public constant startBlock = 100;

    function step() external pure returns (AuctionStep memory) {
        return AuctionStep({mps: 100_000, startBlock: 100, endBlock: 200});
    }
}

contract LaunchAuditValidationReplayTest is Test {
    uint256 constant WITNESS_KEY = 123456;
    bytes32 constant PROVIDER = keccak256("audit-provider");
    address constant USER = address(0xBEEF);
    Reclaim verifier;
    UmiaValidationHook hook;
    LaunchAuditValidationCCA cca;

    function setUp() public {
        verifier = new Reclaim();
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](1);
        witnesses[0] = Reclaim.Witness(vm.addr(WITNESS_KEY), "wss://audit.example");
        verifier.addNewEpoch(witnesses, 1);
        hook = new UmiaValidationHook(address(this), address(verifier), address(0));
        cca = new LaunchAuditValidationCCA();
        hook.setCCA(address(cca));
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = PROVIDER;
        string[] memory ids = new string[](1);
        ids[0] = "audit-provider";
        hook.enableStep(0, hashes, ids);
    }

    function _proof() internal view returns (Reclaim.Proof memory proof) {
        proof.claimInfo = Claims.ClaimInfo(
            "http",
            "params",
            string.concat('{"contextAddress":"', vm.toString(USER), '","providerHash":"', vm.toString(PROVIDER), '"}')
        );
        proof.signedClaim.claim = Claims.CompleteClaimData({
            identifier: Claims.hashClaimInfo(proof.claimInfo),
            owner: USER,
            timestampS: uint32(block.timestamp),
            epoch: 2
        });
        bytes memory message = Claims.serialise(proof.signedClaim.claim);
        bytes32 digest =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", vm.toString(message.length), message));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WITNESS_KEY, digest);
        proof.signedClaim.signatures = new bytes[](1);
        proof.signedClaim.signatures[0] = abi.encodePacked(r, s, v);
    }

    function test_publicVerificationDoesNotConsumeApplicationProof() public {
        Reclaim.Proof memory proof = _proof();
        vm.prank(address(0xBAD));
        verifier.verifyProof(proof);
        hook.submitProof(USER, 0, abi.encode(proof));
        assertTrue(hook.isVerified(0, USER));
    }

    function test_unregisterCannotBeUndoneByPreviouslyUsedProof() public {
        Reclaim.Proof memory proof = _proof();
        hook.submitProof(USER, 0, abi.encode(proof));
        hook.unregister(USER);
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ProofAlreadyUsed.selector, proof.signedClaim.claim.identifier)
        );
        hook.submitProof(USER, 0, abi.encode(proof));
        assertFalse(hook.isVerified(0, USER));
    }

    function test_permissionlessPreRegistrationDoesNotBreakVictimInlineBid() public {
        bytes memory encoded = abi.encode(_proof());
        vm.prank(address(0xBAD));
        hook.submitProof(USER, 0, encoded);
        vm.roll(100);
        vm.prank(address(cca));
        hook.validate(0, 1, USER, USER, abi.encodePacked(uint256(0), encoded));
        assertTrue(hook.isVerified(0, USER));
    }
}
