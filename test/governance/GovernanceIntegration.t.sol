// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {Venture} from "../../src/core/Venture.sol";
import {GovernanceExecutor} from "../../src/core/GovernanceExecutor.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";

contract GovernanceIntegrationTest is DecisionMarketBase {
    function setUp() public override {
        super.setUp();

        // Lowest threshold the Hub allows (floor is MIN_WINNING_THRESHOLD_BPS); keeps test
        // markets resolving on a small margin without disabling the threshold entirely.
        vm.prank(umiaAdmin);
        hub.setWinningMarketThresholdBps(100);
    }

    function test_executeWinningProposal_mintsTokens() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 100e18}))
        });

        bytes memory payload = abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));

        uint256 _marketId = _createMarketWithPayload(payload);

        vm.startPrank(bob);
        usdc.approve(address(mm), type(uint256).max);

        vm.warp(block.timestamp + 1 days + 1);
        mm.split(_marketId, 0, 5_000e6);

        Market memory market = _marketById(_marketId);
        uint256 proposalId = market.proposalIds[1];
        Proposal memory proposal = _proposalById(proposalId);

        uint256 virtualMoneyBalance = mm.balanceOf(bob, proposal.virtualMoneyId);
        uint256 buyAmount = virtualMoneyBalance / 2;

        (uint256 expectedOut, uint256 priceImpact) = mm.quoteSwapExactIn(proposalId, buyAmount, false);
        uint256 maxPriceImpactBps = priceImpact > 1000 ? priceImpact + 100 : 1000;
        uint256 amountOutMin = expectedOut * 99 / 100;

        mm.swapExactIn(proposalId, buyAmount, amountOutMin, maxPriceImpactBps, false, block.timestamp);
        vm.stopPrank();

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(_marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(_marketId);
        assertEq(winning.proposalId, proposalId);

        mm.executeWinningProposal(_marketId);

        address ventureTokenAddr = Venture(venture).token();
        assertEq(IERC20(ventureTokenAddr).balanceOf(bob), 100e18);
    }

    function test_executeWinningProposal_revertsWhenExecutorNotSet() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 1e18}))
        });

        bytes memory payload = abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));

        uint256 _marketId = _createMarketWithPayload(payload);

        vm.startPrank(bob);
        usdc.approve(address(mm), type(uint256).max);
        vm.warp(block.timestamp + 1 days + 1);
        mm.split(_marketId, 0, 5_000e6);

        Market memory market = _marketById(_marketId);
        uint256 proposalId = market.proposalIds[1];
        Proposal memory proposal = _proposalById(proposalId);

        uint256 virtualMoneyBalance = mm.balanceOf(bob, proposal.virtualMoneyId);
        uint256 buyAmount = virtualMoneyBalance / 2;

        (uint256 expectedOut, uint256 priceImpact) = mm.quoteSwapExactIn(proposalId, buyAmount, false);
        uint256 maxPriceImpactBps = priceImpact > 1000 ? priceImpact + 100 : 1000;
        uint256 amountOutMin = expectedOut * 99 / 100;

        mm.swapExactIn(proposalId, buyAmount, amountOutMin, maxPriceImpactBps, false, block.timestamp);
        vm.stopPrank();

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(_marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(_marketId);
        assertEq(winning.proposalId, proposalId, "Non-no-op proposal should win");

        vm.prank(umiaAdmin);
        hub.setDefaultGovernanceExecutor(address(0));

        vm.expectRevert(IUmiaMarketCore.GovernanceExecutorNotSet.selector);
        mm.executeWinningProposal(_marketId);
    }

    function test_executeWinningProposal_revertsWhenExecutorHasNoCode() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 1e18}))
        });

        bytes memory payload = abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));

        uint256 _marketId = _createMarketWithPayload(payload);

        vm.startPrank(bob);
        usdc.approve(address(mm), type(uint256).max);
        vm.warp(block.timestamp + 1 days + 1);
        mm.split(_marketId, 0, 5_000e6);

        Market memory market = _marketById(_marketId);
        uint256 proposalId = market.proposalIds[1];
        Proposal memory proposal = _proposalById(proposalId);

        uint256 virtualMoneyBalance = mm.balanceOf(bob, proposal.virtualMoneyId);
        uint256 buyAmount = virtualMoneyBalance / 2;

        (uint256 expectedOut, uint256 priceImpact) = mm.quoteSwapExactIn(proposalId, buyAmount, false);
        uint256 maxPriceImpactBps = priceImpact > 1000 ? priceImpact + 100 : 1000;
        uint256 amountOutMin = expectedOut * 99 / 100;

        mm.swapExactIn(proposalId, buyAmount, amountOutMin, maxPriceImpactBps, false, block.timestamp);
        vm.stopPrank();

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(_marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(_marketId);
        assertEq(winning.proposalId, proposalId, "Non-no-op proposal should win");

        vm.prank(umiaAdmin);
        hub.setDefaultGovernanceExecutor(makeAddr("executor-eoa"));

        vm.expectRevert(IUmiaMarketCore.GovernanceExecutorNotSet.selector);
        mm.executeWinningProposal(_marketId);

        assertFalse(mm.marketExecuted(_marketId));
    }

    function test_executeWinningProposal_allowsEmptyPayloadWithoutExecutor() public {
        uint256 _marketId = _createMarketWithPayload("");

        vm.startPrank(bob);
        usdc.approve(address(mm), type(uint256).max);
        vm.warp(block.timestamp + 1 days + 1);
        mm.split(_marketId, 0, 5_000e6);

        Market memory market = _marketById(_marketId);
        uint256 proposalId = market.proposalIds[1];
        Proposal memory proposal = _proposalById(proposalId);

        uint256 virtualMoneyBalance = mm.balanceOf(bob, proposal.virtualMoneyId);
        uint256 buyAmount = virtualMoneyBalance / 2;

        (uint256 expectedOut, uint256 priceImpact) = mm.quoteSwapExactIn(proposalId, buyAmount, false);
        uint256 maxPriceImpactBps = priceImpact > 1000 ? priceImpact + 100 : 1000;
        uint256 amountOutMin = expectedOut * 99 / 100;

        mm.swapExactIn(proposalId, buyAmount, amountOutMin, maxPriceImpactBps, false, block.timestamp);
        vm.stopPrank();

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(_marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(_marketId);
        assertEq(winning.proposalId, proposalId, "empty-payload proposal should win");

        vm.prank(umiaAdmin);
        hub.setDefaultGovernanceExecutor(address(0));

        mm.executeWinningProposal(_marketId);

        assertTrue(mm.marketExecuted(_marketId));
    }

    function _createMarketWithPayload(bytes memory payload) internal returns (uint256 _marketId) {
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        ventureToken = Venture(payable(venture)).token();

        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(ventureId, MIN_MARKET_STAKE);

        _mintVenture(hub, venture, alice, MIN_MARKET_STAKE);

        _warmSpotOracle(venture);

        vm.startPrank(alice);
        IERC20(ventureToken).approve(address(marketStake), type(uint256).max);
        marketStake.depositMarketStake(ventureId);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](1);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "mint treasury", executionPayload: payload});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: ventureId,
            title: "governance execution",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        _marketId = mm.createMarket(params, alice, nonce, signature);
        marketId = _marketId;
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    // Execution window: stale winners expire and block nothing forever
    // ─────────────────────────────────────────────────────────

    /// @dev Creates a market whose single proposal carries `payload`, makes it win, and settles.
    function _settleWithWinningPayload(bytes memory payload) internal returns (uint256 _marketId) {
        _marketId = _createMarketWithPayload(payload);

        vm.startPrank(bob);
        usdc.approve(address(mm), type(uint256).max);
        vm.warp(block.timestamp + 1 days + 1);
        mm.split(_marketId, 0, 5_000e6);

        Market memory market = _marketById(_marketId);
        uint256 proposalId = market.proposalIds[1];
        uint256 buyAmount = mm.balanceOf(bob, _proposalById(proposalId).virtualMoneyId) / 2;
        (uint256 expectedOut, uint256 priceImpact) = mm.quoteSwapExactIn(proposalId, buyAmount, false);
        mm.swapExactIn(
            proposalId,
            buyAmount,
            expectedOut * 99 / 100,
            priceImpact > 1000 ? priceImpact + 100 : 1000,
            false,
            block.timestamp
        );
        vm.stopPrank();

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(_marketId);
        assertEq(mm.winningProposalByMarketId(_marketId).proposalId, proposalId, "payload proposal should win");
    }

    function _mintPayload(uint256 amount) internal view returns (bytes memory) {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: bob, amount: amount}))
        });
        return abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));
    }

    /// @dev Opens a follow-up market for the current venture with alice's existing stake.
    function _createFollowUpMarket() internal returns (uint256) {
        _warmSpotOracle(venture);
        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](1);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "follow-up", executionPayload: ""});
        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: ventureId,
            title: "follow-up market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });
        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);
        vm.prank(alice);
        return mm.createMarket(params, alice, nonce, signature);
    }

    /// @dev `_settleWithWinningPayload` settles at `tradingEnd + 1`; the base disables the execution delay.
    function _windowEnd(uint256 _marketId) internal view returns (uint256) {
        return _marketById(_marketId).tradingEnd + 1 + 7 days;
    }

    function test_executeWinningProposal_revertsAfterExecutionWindow() public {
        uint256 _marketId = _settleWithWinningPayload(_mintPayload(100e18));

        vm.warp(_windowEnd(_marketId) + 1);
        vm.expectRevert(IUmiaMarketCore.ExecutionWindowExpired.selector);
        mm.executeWinningProposal(_marketId);
        assertFalse(mm.marketExecuted(_marketId));
    }

    function test_executeWinningProposal_succeedsAtWindowEnd() public {
        uint256 _marketId = _settleWithWinningPayload(_mintPayload(100e18));

        vm.warp(_windowEnd(_marketId));
        mm.executeWinningProposal(_marketId);
        assertEq(IERC20(Venture(venture).token()).balanceOf(bob), 100e18);
    }

    function test_createMarket_blockedWhileWinningPayloadPending() public {
        uint256 _marketId = _settleWithWinningPayload(_mintPayload(100e18));

        vm.expectRevert(IUmiaMarketCore.WinningProposalPendingExecution.selector);
        this.createFollowUpMarketExternal();

        // Executing the winner releases the venture for its next market.
        mm.executeWinningProposal(_marketId);
        _createFollowUpMarket();
    }

    function test_createMarket_allowedOncePendingPayloadExpires() public {
        uint256 _marketId = _settleWithWinningPayload(_mintPayload(100e18));

        vm.warp(_windowEnd(_marketId) + 1);
        _createFollowUpMarket();
    }

    function test_createMarket_pausedPayloadStillBlocksFollowUp() public {
        uint256 _marketId = _settleWithWinningPayload(_mintPayload(100e18));

        vm.prank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(_marketId);
        vm.expectRevert(IUmiaMarketCore.WinningProposalPendingExecution.selector);
        this.createFollowUpMarketExternal();
        // Reversible pause cannot authorize a new market; expiry safely releases it.
        vm.warp(_windowEnd(_marketId) + 1);
        _createFollowUpMarket();
    }

    function test_createMarket_notBlockedByEmptyPayloadWinner() public {
        _settleWithWinningPayload("");
        _createFollowUpMarket();
    }

    function createFollowUpMarketExternal() external returns (uint256) {
        return _createFollowUpMarket();
    }

    // ─────────────────────────────────────────────────────────
    // Token pinning: an upgraded venture cannot redirect shared escrow
    // ─────────────────────────────────────────────────────────

    function test_ventureTokens_pinnedAtCreation() public {
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        address realToken = Venture(payable(venture)).token();

        // A governance upgrade could make the venture report any token. The shared market core and
        // stake escrow resolve tokens through the hub, so they must keep paying the pinned ones.
        vm.mockCall(venture, abi.encodeWithSignature("token()"), abi.encode(address(usdc)));
        vm.mockCall(venture, abi.encodeWithSignature("moneyToken()"), abi.encode(realToken));

        assertEq(hub.ventureTokenById(ventureId), realToken, "venture token pinned");
        assertEq(hub.ventureMoneyTokenById(ventureId), address(usdc), "money token pinned");
    }

    function test_pinVentureTokens_onlyOwner() public {
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        address realToken = Venture(payable(venture)).token();
        uint256[] memory ids = new uint256[](1);
        ids[0] = ventureId;

        vm.prank(alice);
        vm.expectRevert();
        hub.pinVentureTokens(ids);

        // Already pinned at creation: a re-pin is a no-op and cannot overwrite.
        vm.mockCall(venture, abi.encodeWithSignature("token()"), abi.encode(address(usdc)));
        vm.prank(umiaAdmin);
        hub.pinVentureTokens(ids);
        assertEq(hub.ventureTokenById(ventureId), realToken, "re-pin cannot overwrite");
    }

    function test_legacyTokenGettersFailClosedUntilVerifiedMigration() public {
        (uint256 id, address payable v) = _createVentureWithLBP(hub, alice, "Legacy", "LEG", 1_000_000e18);
        address originalToken = Venture(v).token();
        // The two mappings consume slots 19 and 20 of the Hub storage gap.
        vm.store(address(hub), keccak256(abi.encode(id, uint256(19))), bytes32(0));
        vm.store(address(hub), keccak256(abi.encode(id, uint256(20))), bytes32(0));
        vm.mockCall(v, abi.encodeWithSignature("token()"), abi.encode(address(usdc)));
        vm.mockCall(v, abi.encodeWithSignature("moneyToken()"), abi.encode(originalToken));
        vm.expectRevert(IUmiaHub.VentureTokensNotPinned.selector);
        hub.ventureTokenById(id);
        vm.expectRevert(IUmiaHub.VentureTokensNotPinned.selector);
        hub.ventureMoneyTokenById(id);
        uint256[] memory ids = new uint256[](1);
        address[] memory tokens = new address[](1);
        address[] memory moneyTokens = new address[](1);
        ids[0] = id;
        tokens[0] = originalToken;
        moneyTokens[0] = address(usdc);
        vm.prank(umiaAdmin);
        hub.pinVentureTokens(ids, tokens, moneyTokens);
        assertEq(hub.ventureTokenById(id), originalToken);
        assertEq(hub.ventureMoneyTokenById(id), address(usdc));
    }

    function test_legacyMigrationCannotPinZeroAssets() public {
        (uint256 id,) = _createVentureWithLBP(hub, alice, "Legacy", "LEG", 1_000_000e18);
        vm.store(address(hub), keccak256(abi.encode(id, uint256(19))), bytes32(0));
        vm.store(address(hub), keccak256(abi.encode(id, uint256(20))), bytes32(0));
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(umiaAdmin);
        vm.expectRevert(IUmiaHub.InvalidToken.selector);
        hub.pinVentureTokens(ids, new address[](1), new address[](1));
    }

    function test_legacySupersededPayloadCannotRevive() public {
        uint256 id = _settleWithWinningPayload(_mintPayload(100e18));
        // Simulate pre-upgrade state in which a later market overwrote the active pointer.
        vm.store(address(mm), keccak256(abi.encode(ventureId, uint256(12))), bytes32(id + 1));
        vm.expectRevert(IUmiaMarketCore.WinningProposalSuperseded.selector);
        mm.executeWinningProposal(id);
        assertFalse(mm.marketExecuted(id));
    }
}
