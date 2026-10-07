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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RecoveryTestPermit2 {
    function transferFrom(address from, address to, uint160 amount, address token) external {
        IERC20(token).transferFrom(from, to, amount);
    }
}

contract UmiaLBPFailedAuctionSecurityTest is Test {
    address constant VENTURE = address(0x1234);
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    MockERC20 token;
    MockERC20 money;
    UmiaLBP lbp;
    ContinuousClearingAuction cca;
    uint64 start;
    uint64 end;

    function _launch(uint128 target) internal {
        token = new MockERC20("venture", "V", 18);
        money = new MockERC20("money", "M", 18);
        ContinuousClearingAuctionFactory factory = new ContinuousClearingAuctionFactory(address(0));
        vm.mockCall(VENTURE, abi.encodeWithSignature("HUB()"), abi.encode(address(this)));
        vm.mockCall(address(this), abi.encodeWithSignature("ccaFactory()"), abi.encode(address(factory)));
        vm.mockCall(address(this), abi.encodeWithSignature("migrationDelayBlocks()"), abi.encode(uint64(5)));
        start = uint64(block.number + 1);
        end = start + 100;
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
            requiredCurrencyRaised: target,
            auctionStepsData: abi.encodePacked(uint24(100_000), uint40(100))
        });
        lbp = new UmiaLBP(
            address(token),
            1_000 ether,
            5_000_000,
            address(money),
            abi.encode(p),
            IPoolManager(address(0x2345)),
            IUmiaHook(address(0x3456)),
            VENTURE,
            2000,
            address(0)
        );
        token.mint(address(lbp), 1_000 ether);
        lbp.onTokensReceived();
        cca = ContinuousClearingAuction(address(lbp.initializer()));
    }

    function _bid() internal returns (uint256 bidId) {
        vm.etch(PERMIT2, address(new RecoveryTestPermit2()).code);
        money.mint(address(this), 100 ether);
        money.approve(PERMIT2, type(uint256).max);
        vm.roll(start);
        return cca.submitBid(2 << 96, 100 ether, address(this), "");
    }

    function test_recoverUncheckpointedFailedAuctionReturnsAllSupply() public {
        _launch(1);
        vm.roll(end + 5);
        vm.prank(address(0xBAD));
        lbp.recoverFailedAuction();
        assertEq(token.balanceOf(VENTURE), 1_000 ether);
        assertEq(token.balanceOf(address(lbp)), 0);
        assertEq(token.balanceOf(address(cca)), 0);
        assertFalse(lbp.migrated());
        lbp.recoverFailedAuction();
        assertEq(token.balanceOf(VENTURE), 1_000 ether);
    }

    function test_recoveryPreservesFullBidRefunds() public {
        _launch(1_000 ether);
        uint256 bidId = _bid();
        vm.roll(end + 5);
        lbp.recoverFailedAuction();
        assertEq(money.balanceOf(address(cca)), 100 ether);
        cca.exitBid(bidId);
        assertEq(money.balanceOf(address(this)), 100 ether);
        assertEq(token.balanceOf(VENTURE), 1_000 ether);
    }

    function test_recoveryRejectsSuccessfulAuctionAfterCheckpoint() public {
        _launch(1);
        _bid();
        vm.roll(end + 5);
        vm.expectRevert(IUmiaLBP.SweepNotAllowed.selector);
        lbp.recoverFailedAuction();
        assertEq(token.balanceOf(address(lbp)), 500 ether);
        assertEq(token.balanceOf(address(cca)), 500 ether);
    }

    function test_recoveryCannotRunBeforeDelay() public {
        _launch(1);
        vm.roll(end + 4);
        vm.expectRevert(IUmiaLBP.SweepNotAllowed.selector);
        lbp.recoverFailedAuction();
        assertEq(token.balanceOf(address(lbp)), 500 ether);
    }
}
