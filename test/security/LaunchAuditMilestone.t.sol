// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {VentureVestingAuthorityTest} from "../periphery/VentureVestingAuthority.t.sol";
import {IVentureVestingAuthority} from "../../src/interfaces/IVentureVestingAuthority.sol";

contract LaunchAuditMilestoneTest is VentureVestingAuthorityTest {
    function test_registeredLadderCannotBeReindexedByRemoval() public {
        _fundGenesis(_absoluteProgram(100, 10000));
        _mockBindDeps();
        adapter.bind(VENTURE_ID);
        bytes memory data = abi.encodeWithSignature("removeMetavestMilestone(address,uint256)", ALLOCATION, 0);
        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.PriceProgramMilestoneMutationForbidden.selector);
        adapter.forward(data, _noProgram());
        assertEq(adapter.effectiveThreshold(ALLOCATION, 1), 10000);
    }

    function test_registeredLadderCannotAppendUnregisteredMilestone() public {
        _fundGenesis(_absoluteProgram(100, 10000));
        _mockBindDeps();
        adapter.bind(VENTURE_ID);
        bytes memory data = abi.encodePacked(
            bytes4(keccak256("addMetavestMilestone(address,(uint256,bool,bool,address[]))")), abi.encode(ALLOCATION)
        );
        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.PriceProgramMilestoneMutationForbidden.selector);
        adapter.forward(data, _noProgram());
    }

    function test_nonPriceMilestoneRemovalStillForwards() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);
        bytes memory data = abi.encodeWithSignature("removeMetavestMilestone(address,uint256)", ALLOCATION, 0);
        vm.mockCall(CONTROLLER, data, bytes(""));
        vm.prank(TREASURY);
        adapter.forward(data, _noProgram());
    }
}
