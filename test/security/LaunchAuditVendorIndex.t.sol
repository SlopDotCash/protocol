// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {BaseAllocation} from "@metavest/BaseAllocation.sol";
import {VestingAllocation} from "@metavest/VestingAllocation.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Mirrors the production condition's immutable index lookup; price is fixed at 2.
contract LaunchAuditIndexedCondition {
    function checkCondition(address, bytes4, bytes calldata data) external pure returns (bool) {
        return abi.decode(data, (uint256)) == 0;
    }
}

contract LaunchAuditVendorIndexTest is Test {
    function authority() external view returns (address) {
        return address(this);
    }

    function test_vendorRemovalReindexesHighMilestoneOntoLowerThreshold() public {
        MockERC20 token = new MockERC20("V", "V", 18);
        LaunchAuditIndexedCondition condition = new LaunchAuditIndexedCondition();
        BaseAllocation.Allocation memory a =
            BaseAllocation.Allocation(1 ether, 1 ether, 1 ether, 0, 0, 0, 0, address(token));
        BaseAllocation.Milestone[] memory milestones = new BaseAllocation.Milestone[](2);
        address[] memory conditions = new address[](1);
        conditions[0] = address(condition);
        milestones[0] = BaseAllocation.Milestone(10 ether, true, false, conditions);
        milestones[1] = BaseAllocation.Milestone(1000 ether, true, false, conditions);
        VestingAllocation allocation = new VestingAllocation(address(this), address(this), a, milestones);
        token.mint(address(allocation), 1011 ether);
        vm.expectRevert(BaseAllocation.MetaVesT_ConditionNotSatisfied.selector);
        allocation.confirmMilestone(1);
        allocation.removeMilestone(0); // legitimate controller-authorized amendment
        allocation.confirmMilestone(0); // moved award now passes the unchanged lower threshold
        allocation.withdraw(1001 ether);
        assertEq(token.balanceOf(address(this)), 1011 ether); // 10 clawback + 1001 withdrawn
    }
}
