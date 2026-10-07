// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {IUmiaLBP} from "../../src/interfaces/IUmiaLBP.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ContinuousClearingAuctionFactory} from "@continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {ContinuousClearingAuction} from "@continuous-clearing-auction/ContinuousClearingAuction.sol";
import {AuctionParameters} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract LaunchAuditRecoveryTest is Test {
    function test_failedAuctionRecoveryReturnsReserveAndUnsoldSupply() public {
        _checkRecovery(1);
    }

    function test_zeroMinimumZeroBidAuctionCanRecover() public {
        _checkRecovery(0);
    }

    function _checkRecovery(uint128 minimumRaise) internal {
        MockERC20 token = new MockERC20("venture", "V", 18);
        MockERC20 money = new MockERC20("money", "M", 18);
        ContinuousClearingAuctionFactory factory = new ContinuousClearingAuctionFactory(address(0));
        address venture = address(0x1234);
        vm.mockCall(venture, abi.encodeWithSignature("HUB()"), abi.encode(address(this)));
        vm.mockCall(address(this), abi.encodeWithSignature("ccaFactory()"), abi.encode(address(factory)));
        vm.mockCall(address(this), abi.encodeWithSignature("migrationDelayBlocks()"), abi.encode(uint64(0)));
        vm.mockCall(address(this), abi.encodeWithSignature("sweepDelayBlocks()"), abi.encode(uint64(0)));
        uint64 start = uint64(block.number + 1);
        uint64 end = start + 100;
        AuctionParameters memory p = AuctionParameters({
            currency: address(money),
            tokensRecipient: address(1),
            fundsRecipient: address(1),
            startBlock: start,
            endBlock: end,
            claimBlock: end,
            tickSpacing: 1 << 96,
            validationHook: address(0),
            floorPrice: 1 << 96,
            requiredCurrencyRaised: minimumRaise,
            auctionStepsData: abi.encodePacked(uint24(100_000), uint40(100))
        });
        UmiaLBP lbp = new UmiaLBP(
            address(token),
            1_000 ether,
            5_000_000,
            address(money),
            abi.encode(p),
            IPoolManager(address(0x2345)),
            IUmiaHook(address(0x3456)),
            venture,
            2000,
            address(0)
        );
        token.mint(address(lbp), 1_000 ether);
        lbp.onTokensReceived();
        ContinuousClearingAuction cca = ContinuousClearingAuction(address(lbp.initializer()));
        vm.roll(end + 1000);
        cca.checkpoint();
        assertEq(cca.isGraduated(), minimumRaise == 0);
        vm.expectRevert(minimumRaise == 0 ? IUmiaLBP.NoCurrencyRaised.selector : bytes4(keccak256("NotGraduated()")));
        lbp.migrate();
        vm.expectRevert(IUmiaLBP.SweepNotAllowed.selector);
        lbp.sweepToken();
        vm.expectRevert();
        cca.sweepUnsoldTokens();
        assertEq(token.balanceOf(address(lbp)), 500 ether);
        assertEq(token.balanceOf(address(cca)), 500 ether);
        assertFalse(lbp.migrated());

        lbp.recoverFailedAuction();
        assertEq(token.balanceOf(venture), 1_000 ether);
        assertEq(token.balanceOf(address(lbp)), 0);
        assertEq(token.balanceOf(address(cca)), 0);
        assertFalse(lbp.migrated());
        // Anyone may repeat the fixed-recipient sweep, but cannot duplicate the recovery.
        lbp.recoverFailedAuction();
        assertEq(token.balanceOf(venture), 1_000 ether);
    }
}
