// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Venture} from "../../src/core/Venture.sol";

import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";

contract MarketDomainForkSecurityTest is DecisionMarketBase {
    function test_PermitsRejectPreviousChainAndAcceptCurrentChain() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        vm.warp(vm.getBlockTimestamp() + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        Market memory market = _marketById(marketId);
        uint256 proposalId = market.proposalIds[1];

        uint256 bobPrivateKey = 0xB0B;
        address bobAddr = vm.addr(bobPrivateKey);

        uint256 virtualMoneyId = mm.getVirtualMoneyId(proposalId);

        vm.prank(bob);
        mm.transfer(bobAddr, virtualMoneyId, 500e6);

        uint256 amountIn = 100e6;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        uint256 nonce = mm.swapNonces(bobAddr);

        IUmiaMarketCore.SwapExactInPermit memory permit = IUmiaMarketCore.SwapExactInPermit({
            proposalId: proposalId,
            amountIn: amountIn,
            amountOutMin: 0,
            maxPriceImpactBps: 5000,
            zeroForOne: false,
            nonce: nonce,
            deadline: deadline
        });

        bytes32 structHash = keccak256(
            abi.encode(
                mm.SWAP_EXACT_IN_PERMIT_TYPEHASH(),
                permit.proposalId,
                permit.amountIn,
                permit.amountOutMin,
                permit.maxPriceImpactBps,
                permit.zeroForOne,
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = mm.balanceOf(bobAddr, mm.getVirtualVentureId(proposalId));

        bytes32 previousDomain = mm.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        vm.expectRevert(IUmiaMarketCore.InvalidSignature.selector);
        vm.prank(charlie);
        mm.swapExactInWithPermit(permit, bobAddr, signature);
        assertEq(mm.swapNonces(bobAddr), nonce, "rejected replay cannot consume nonce");
        assertTrue(mm.DOMAIN_SEPARATOR() != previousDomain, "domain must follow current chain");
        digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(bobPrivateKey, digest);
        signature = abi.encodePacked(r, s, v);

        vm.prank(charlie);
        uint256 amountOut = mm.swapExactInWithPermit(permit, bobAddr, signature);

        assertGt(amountOut, 0, "Should receive output tokens");
        assertEq(
            mm.balanceOf(bobAddr, mm.getVirtualVentureId(proposalId)),
            balanceBefore + amountOut,
            "Bob should receive output tokens"
        );
        assertEq(mm.swapNonces(bobAddr), nonce + 1, "Nonce should increment");
    }

    function test_ExactOutPermitsFollowCurrentChain() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);
        uint256 proposalId = _marketById(marketId).proposalIds[1];
        uint256 key = 0xB0B;
        address signer = vm.addr(key);
        uint256 moneyId = mm.getVirtualMoneyId(proposalId);
        vm.prank(bob);
        mm.transfer(signer, moneyId, 500e6);
        IUmiaMarketCore.SwapExactOutPermit memory permit = IUmiaMarketCore.SwapExactOutPermit({
            proposalId: proposalId,
            amountOut: 10e6,
            amountInMax: 500e6,
            maxPriceImpactBps: 10_000,
            zeroForOne: false,
            nonce: 0,
            deadline: vm.getBlockTimestamp() + 1 hours
        });
        bytes32 structHash = keccak256(
            abi.encode(
                mm.SWAP_EXACT_OUT_PERMIT_TYPEHASH(),
                permit.proposalId,
                permit.amountOut,
                permit.amountInMax,
                permit.maxPriceImpactBps,
                permit.zeroForOne,
                permit.nonce,
                permit.deadline
            )
        );
        bytes memory signature = _signDomain(key, structHash);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(IUmiaMarketCore.InvalidSignature.selector);
        mm.swapExactOutWithPermit(permit, signer, signature);
        assertEq(mm.swapNonces(signer), 0);
        signature = _signDomain(key, structHash);
        assertGt(mm.swapExactOutWithPermit(permit, signer, signature), 0);
        assertEq(mm.balanceOf(signer, mm.getVirtualVentureId(proposalId)), permit.amountOut);
        assertEq(mm.swapNonces(signer), 1);
    }

    function test_MarketCreationApprovalFollowsCurrentChain() public {
        (ventureId, venture) = _createVentureWithLBP(hub, alice);
        ventureToken = Venture(payable(venture)).token();
        _warmSpotOracle(venture);
        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(ventureId, MIN_MARKET_STAKE);
        _mintVenture(hub, venture, alice, MIN_MARKET_STAKE);
        vm.startPrank(alice);
        IERC20(ventureToken).approve(address(marketStake), MIN_MARKET_STAKE);
        marketStake.depositMarketStake(ventureId);
        vm.stopPrank();
        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "A", executionPayload: ""});
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "B", executionPayload: ""});
        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: ventureId,
            title: "Fork domain",
            startTimestamp: vm.getBlockTimestamp() + 1 days,
            duration: 0,
            proposals: proposals
        });
        bytes memory signature = _signMarketCreation(alice, params, 0);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(IUmiaMarketCore.InvalidSignature.selector);
        vm.prank(alice);
        mm.createMarket(params, alice, 0, signature);
        assertEq(mm.marketCreationNonces(alice), 0);
        signature = _signMarketCreation(alice, params, 0);
        vm.prank(alice);
        assertGt(mm.createMarket(params, alice, 0, signature), 0);
        assertEq(mm.marketCreationNonces(alice), 1);
    }

    function _signDomain(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
