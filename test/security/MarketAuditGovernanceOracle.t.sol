// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {Venture} from "../../src/core/Venture.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";

/// @notice End-to-end conditional-oracle test: a short buy/sell round
///         trip followed by a quiet interval must not let an admitted allowance change beat the no-op.
contract MarketAuditGovernanceOracleTest is DecisionMarketBase {
    uint256 internal constant NEW_ALLOWANCE = 50_000e6;

    function test_Audit_RoundTripCannotExecuteLosingAllowanceProposal() public {
        // Default 2% threshold; one-hour market so the quiet interval dominates the window.
        assertEq(hub.winningMarketThresholdBps(), 200);

        uint256 _marketId = _createAllowanceMarket();
        Market memory market = _marketById(_marketId);
        uint256 noOpId = market.proposalIds[0];
        uint256 candidateId = market.proposalIds[1];
        assertTrue(_proposalById(noOpId).isNoOp);
        Proposal memory candidate = _proposalById(candidateId);
        (uint256 allowanceBefore,,) = Venture(venture).monthlyAllowance(address(usdc));

        vm.warp(market.tradingStart);
        vm.startPrank(bob);
        usdc.approve(address(mm), type(uint256).max);
        mm.split(_marketId, 0, 50_000e6);

        // Pump the candidate's price several-fold.
        (uint256 r0, uint256 r1) = mm.cpmmStates(candidateId);
        uint256 spot0 = r1 * 1e18 / r0;
        uint256 boughtVenture = mm.swapExactIn(candidateId, r1 * 3, 0, 10_000, false, block.timestamp);
        (r0, r1) = mm.cpmmStates(candidateId);
        assertGt(r1 * 1e18 / r0, spot0 * 3, "pump should move spot several-fold");

        // Extra checkpoint while the pump is held, then reverse the trade.
        vm.warp(block.timestamp + 2);
        mm.swapExactIn(candidateId, 1, 0, 10_000, false, block.timestamp);
        vm.warp(block.timestamp + 2);
        mm.swapExactIn(candidateId, boughtVenture, 0, 10_000, true, block.timestamp);
        vm.stopPrank();

        (r0, r1) = mm.cpmmStates(candidateId);
        uint256 restored = r1 * 1e18 / r0;
        assertLt(restored, spot0 * 102 / 100, "round trip restores spot within the threshold");
        assertGt(mm.balanceOf(bob, candidate.virtualMoneyId), 0);

        // Quiet interval to the end of the window, then settle.
        vm.warp(market.tradingEnd + 1);
        uint256 candidateTwap = mm.getProposalTWAP(candidateId);
        uint256 noOpTwap = mm.getProposalTWAP(noOpId);
        assertLt(candidateTwap, noOpTwap * 10_200 / 10_000, "oracle must not credit the stale pump");

        mm.settleMarket(_marketId);
        assertEq(mm.winningProposalByMarketId(_marketId).proposalId, noOpId, "no-op must win");

        mm.executeWinningProposal(_marketId);
        (uint256 allowanceAfter,,) = Venture(venture).monthlyAllowance(address(usdc));
        assertEq(allowanceAfter, allowanceBefore, "allowance must remain unchanged");
        assertTrue(allowanceAfter != NEW_ALLOWANCE);
    }

    function _createAllowanceMarket() internal returns (uint256 _marketId) {
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        ventureToken = Venture(payable(venture)).token();

        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(ventureId, MIN_MARKET_STAKE);
        _mintVenture(hub, venture, alice, MIN_MARKET_STAKE);
        _warmSpotOracle(venture);

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.UpdateMonthlyAllowance({token: address(usdc), amount: NEW_ALLOWANCE}))
        });
        bytes memory payload = abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));

        vm.startPrank(alice);
        IERC20(ventureToken).approve(address(marketStake), type(uint256).max);
        marketStake.depositMarketStake(ventureId);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](1);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "raise allowance", executionPayload: payload});
        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: ventureId,
            title: "allowance change",
            startTimestamp: block.timestamp + 1 days,
            duration: 1 hours,
            proposals: proposals
        });
        uint256 nonce = mm.marketCreationNonces(alice);
        _marketId = mm.createMarket(params, alice, nonce, _signMarketCreation(alice, params, nonce));
        marketId = _marketId;
        vm.stopPrank();
    }
}
