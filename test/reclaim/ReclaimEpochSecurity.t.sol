// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Reclaim} from "../../src/reclaim/Reclaim.sol";
import {Claims} from "../../src/reclaim/Claims.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract ReclaimEpochSecurityTest is Test {
    Reclaim verifier;
    uint256 constant OLD_KEY = 0xABCD;
    uint256 constant NEW_KEY = 0xDCBA;

    function setUp() public {
        vm.warp(1000);
        verifier = new Reclaim();
        _rotate(OLD_KEY);
    }

    function _rotate(uint256 key) internal {
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](1);
        witnesses[0] = Reclaim.Witness(vm.addr(key), "wss://test");
        verifier.addNewEpoch(witnesses, 1);
    }

    function _proof(uint32 epoch, uint32 timestamp, uint256 key) internal returns (Reclaim.Proof memory proof) {
        proof.claimInfo = Claims.ClaimInfo("http", "{}", "{}");
        proof.signedClaim.claim =
            Claims.CompleteClaimData(Claims.hashClaimInfo(proof.claimInfo), address(this), timestamp, epoch);
        bytes memory content = Claims.serialise(proof.signedClaim.claim);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(content));
        proof.signedClaim.signatures = new bytes[](1);
        proof.signedClaim.signatures[0] = abi.encodePacked(r, s, v);
    }

    function test_rotationPreservesGenuineHistoricalProof() public {
        vm.warp(1100);
        _rotate(NEW_KEY);
        verifier.verifyProof(_proof(2, 1050, OLD_KEY));
    }

    function test_retiredWitnessCannotSignNewProof() public {
        vm.warp(1100);
        _rotate(NEW_KEY);
        vm.warp(1200);
        Reclaim.Proof memory proof = _proof(2, 1101, OLD_KEY);
        vm.expectRevert("Proof after epoch ended");
        verifier.verifyProof(proof);
    }

    function test_revocationRejectsBackdatedCompromisedWitnessProof() public {
        vm.warp(1100);
        _rotate(NEW_KEY);
        Reclaim.Proof memory proof = _proof(2, 1050, OLD_KEY);
        verifier.verifyProof(proof);
        verifier.revokeEpoch(2);
        vm.expectRevert("Epoch revoked");
        verifier.verifyProof(proof);
        verifier.verifyProof(_proof(3, 1100, NEW_KEY));
    }

    function test_onlyOwnerMayRevokeEpoch() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("Only Owner");
        verifier.revokeEpoch(2);
        assertFalse(verifier.revokedEpochs(2));
    }

    function test_rejectsProofBeforeEpochStarted() public {
        Reclaim.Proof memory proof = _proof(2, 999, OLD_KEY);
        vm.expectRevert("Invalid proof timestamp");
        verifier.verifyProof(proof);
    }

    function test_rejectsProofFromFuture() public {
        Reclaim.Proof memory proof = _proof(2, 1001, OLD_KEY);
        vm.expectRevert("Invalid proof timestamp");
        verifier.verifyProof(proof);
    }

    function test_epochZeroCannotAliasCurrentEpoch() public {
        Reclaim.Proof memory proof = _proof(0, 1000, OLD_KEY);
        vm.expectRevert("Invalid proof epoch");
        verifier.verifyProof(proof);
    }

    function test_currentEpochRemainsUsablePastAdvisoryCacheExpiry() public {
        vm.warp(1000 + 2 days);
        verifier.verifyProof(_proof(2, uint32(block.timestamp), OLD_KEY));
    }
}
