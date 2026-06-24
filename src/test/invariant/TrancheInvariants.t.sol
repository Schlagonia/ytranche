// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {console2} from "forge-std/console2.sol";
import {Setup} from "../utils/Setup.sol";
import {TrancheHandler} from "./handlers/TrancheHandler.sol";
import {MockMainVault} from "../mocks/MockMainVault.sol";
import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {ILockedTrancheStrategy} from "../../interfaces/ITrancheStrategy.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";

/// @notice Stateful invariant suite. Drives the protocol through long randomized
///         action sequences via {TrancheHandler} and asserts the core accounting
///         and economic invariants hold (or are reconciled) at every step.
contract TrancheInvariants is Setup {
    TrancheHandler public handler;

    // Absolute wei tolerance for rounding across the vault + per-tranche accrual.
    uint256 internal constant TOL = 1e12;
    // Looser tolerance for the exact two-sided conservation check, which accumulates
    // the vyper vault's per-operation share rounding over a full action sequence.
    uint256 internal constant CONS_TOL = 1e13;

    // NOTE: plan invariant #1 (strategy totalAssets() == controller.liveAssets()) is
    // intentionally NOT a stateful invariant: TokenizedStrategy.totalAssets() is the
    // STORED value refreshed on report/deposit/withdraw, while liveAssets() accrues
    // continuously, so they legitimately diverge between checkpoints (and after a
    // loss, before the next report). The relationship is validated indirectly by #3
    // and by the report-based scenario tests in Scenarios.t.sol.

    function setUp() public override {
        super.setUp();

        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = eve;

        handler = new TrancheHandler(
            TrancheHandler.Refs({
                controller: controller,
                hook: hook,
                asset: asset,
                riskyStrategy: IStrategy(address(riskyStrategy)),
                mainVault: mainVault,
                keeper: keeper,
                management: management,
                aTranche: address(aTranche),
                bTranche: address(bTranche),
                eTranche: address(eTranche)
            }),
            actors
        );

        // Hand each tranche's strategy-management to the handler so it can toggle
        // the health check around settlement reports (this contract is the current
        // strategy-management from the Setup deploy).
        _giveManagement(address(aTranche));
        _giveManagement(address(bTranche));
        _giveManagement(address(eTranche));

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _selectors()}));
    }

    function _selectFork() internal override {
        if (TOKENIZED_STRATEGY_ADDRESS.code.length == 0) {
            TokenizedStrategy tokenizedStrategy = new TokenizedStrategy(address(0));
            vm.etch(TOKENIZED_STRATEGY_ADDRESS, address(tokenizedStrategy).code);
        }

        require(
            keccak256(bytes(IStrategy(TOKENIZED_STRATEGY_ADDRESS).apiVersion())) == keccak256(bytes("3.1.0")),
            "BAD_TOKENIZED_VERSION"
        );
    }

    function _deployMainVault() internal override returns (IVault) {
        return IVault(address(new MockMainVault(address(asset))));
    }

    function _giveManagement(address tranche) internal {
        IStrategy(tranche).setPendingManagement(address(handler));
        vm.prank(address(handler));
        IStrategy(tranche).acceptManagement();
    }

    function _selectors() internal pure returns (bytes4[] memory sel) {
        sel = new bytes4[](20);
        sel[0] = TrancheHandler.depositA.selector;
        sel[1] = TrancheHandler.depositB.selector;
        sel[2] = TrancheHandler.depositE.selector;
        sel[3] = TrancheHandler.withdrawA.selector;
        sel[4] = TrancheHandler.redeemIfMatureB.selector;
        sel[5] = TrancheHandler.redeemIfMatureE.selector;
        sel[6] = TrancheHandler.startCooldownB.selector;
        sel[7] = TrancheHandler.startCooldownE.selector;
        sel[8] = TrancheHandler.cancelCooldownB.selector;
        sel[9] = TrancheHandler.cancelCooldownE.selector;
        sel[10] = TrancheHandler.transferAttemptB.selector;
        sel[11] = TrancheHandler.transferAttemptE.selector;
        sel[12] = TrancheHandler.warp.selector;
        sel[13] = TrancheHandler.injectProfit.selector;
        sel[14] = TrancheHandler.injectLoss.selector;
        sel[15] = TrancheHandler.injectUnsettledLoss.selector;
        sel[16] = TrancheHandler.processVaultReport.selector;
        sel[17] = TrancheHandler.fundReserve.selector;
        sel[18] = TrancheHandler.settle.selector;
        sel[19] = TrancheHandler.reportTranches.selector;
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// #4 — `backingAssets()` is exactly its definition (smoke check on the getter).
    function invariant_backingAccountingConsistent() public view {
        assertApproxEqAbs(
            controller.backingAssets(),
            controller.vaultAssets() + controller.reserveAssets(),
            TOL,
            "backing != vault + reserve"
        );
    }

    /// #6a — no value creation: everything backing the system plus everything paid
    /// out can never exceed everything put in plus all profit. Losses only reduce,
    /// so this one-sided bound is robust to processed/unprocessed PnL timing and to
    /// loss crystallized at redemption. Always on.
    function invariant_noValueCreation() public view {
        uint256 lhs = controller.backingAssets() + handler.ghost_principalOut();
        uint256 rhs = handler.ghost_principalIn() + handler.ghost_reserveFunded() + handler.ghost_processedProfit()
            + handler.ghost_unprocessedProfit();
        assertLe(lhs, rhs + TOL, "value created from nothing");
    }

    /// #6b — exact two-sided conservation: backing + paid-out + realized-loss equals
    /// deposited + reserve-funded + realized-profit. Asserted only in CLEAN states —
    /// no markdown mid-flight (unprocessed PnL == 0) and no illiquid loss ever
    /// crystallized at redemption (redemptionLoss == 0) — so the processed-loss ghost
    /// is the complete loss term and there is no double-count.
    function invariant_valueConservationExact() public view {
        if (handler.ghost_unprocessedLoss() != 0 || handler.ghost_unprocessedProfit() != 0) return;
        if (handler.ghost_redemptionLoss() != 0) return;
        uint256 credits = handler.ghost_principalIn() + handler.ghost_reserveFunded() + handler.ghost_processedProfit();
        uint256 debits = handler.ghost_principalOut() + handler.ghost_processedLoss();
        assertApproxEqAbs(controller.backingAssets() + debits, credits, CONS_TOL, "exact conservation");
    }

    /// #3 — totalClaims() equals the sum of each tranche's live value plus pending
    /// excess (validates the getter walks every registered tranche).
    function invariant_claimsAccountingConsistent() public view {
        address[] memory t = controller.getTranchesByPriority();
        uint256 sum;
        for (uint256 i; i < t.length; ++i) {
            sum += controller.liveAssets(t[i]) + controller.pendingExcess(t[i]);
        }
        assertApproxEqAbs(controller.totalClaims(), sum, TOL, "totalClaims != sum(live + pending)");
    }

    /// #7 — the reserve is never a yield source: its assets never exceed what was
    /// funded into it (it only ever sits flat or is drawn down at a loss settle).
    function invariant_reserveNeverExceedsFunded() public view {
        assertLe(controller.reserveAssets(), handler.ghost_reserveFunded() + TOL, "reserve exceeds funded");
    }

    // NOTE: plan invariant #9 (junior-first loss ordering) is intentionally NOT a
    // stateful invariant. "Frozen tranches form a junior suffix" is only true at the
    // moment loss is applied: a junior tranche that was empty during a loss does not
    // freeze, and a deposit into it afterward leaves a frozen senior above an
    // unfrozen junior-with-baseline — a legitimate state, not a bug (the fuzzer found
    // exactly this). Junior-first ordering is verified at the application moment by
    // testFuzz_lossAbsorptionJuniorFirst and the loss-ordering scenario tests.

    /// #10 — a frozen tranche does not accrue: its live value equals its baseline.
    function invariant_frozenTrancheDoesNotAccrue() public view {
        address[] memory t = controller.getTranchesByPriority();
        for (uint256 i; i < t.length; ++i) {
            if (!controller.isFrozen(t[i])) continue;
            (,,,, uint256 baseline,,) = controller.tranches(t[i]);
            assertEq(controller.liveAssets(t[i]), baseline, "frozen tranche accrued");
        }
    }

    /// #15 — cooled shares never exceed a locked tranche's total supply.
    function invariant_cooledSharesNeverExceedSupply() public view {
        _assertCooledWithinSupply(address(bTranche));
        _assertCooledWithinSupply(address(eTranche));
    }

    function _assertCooledWithinSupply(address tranche) internal view {
        uint256 n = handler.actorCount();
        uint256 cooled;
        for (uint256 i; i < n; ++i) {
            (,, uint256 s) = ILockedTrancheStrategy(tranche).getCooldownStatus(handler.actors(i));
            cooled += s;
        }
        assertLe(cooled, IStrategy(tranche).totalSupply(), "cooled shares exceed supply");
    }

    /// #11 (weak form) — accrual is never negative: each tranche's live value is at
    /// least its stored baseline.
    function invariant_liveAssetsGteBaseline() public view {
        address[] memory tranches = controller.getTranchesByPriority();
        for (uint256 i; i < tranches.length; ++i) {
            (,,,, uint256 baseline,,) = controller.tranches(tranches[i]);
            assertGe(controller.liveAssets(tranches[i]), baseline, "liveAssets < baseline");
        }
    }

    /// #12 — excess shares never exceed MAX_BPS.
    function invariant_excessShareBpsBounded() public view {
        address[] memory tranches = controller.getTranchesByPriority();
        uint256 sum;
        for (uint256 i; i < tranches.length; ++i) {
            (,, uint16 ex,,,,) = controller.tranches(tranches[i]);
            sum += ex;
        }
        assertLe(sum, MAX_BPS, "sum excessShareBps > MAX_BPS");
    }

    /// #13 — the two-step core roles are always single-holder (never bricked/doubled).
    function invariant_coreRolesSingleHolder() public view {
        assertEq(authorizer.getRoleMemberCount(authorizer.GOVERNANCE_ROLE()), 1, "governance not single");
        assertEq(authorizer.getRoleMemberCount(authorizer.DEFAULT_ADMIN_ROLE()), 1, "default admin not single");
    }

    /// #8 — immediately after a settle with no outstanding unsettled markdown, total
    /// claims are reconciled to within backing (the waterfall is solvent post-settle).
    function invariant_postSettleSolvency() public view {
        if (!handler.lastCallWasSettle()) return;
        if (handler.ghost_unprocessedLoss() != 0) return;
        assertLe(controller.totalClaims(), controller.backingAssets() + TOL, "claims > backing after settle");
    }

    function invariant_callSummary() public view {
        // Surfaced with `forge test -vv` to confirm the fuzzer reached interesting states.
        console2.log("deposits A/B/E", handler.calls("depositA"), handler.calls("depositB"), handler.calls("depositE"));
        console2.log("settle", handler.calls("settle"));
        console2.log("injectLoss", handler.calls("injectLoss"));
        console2.log("injectUnsettledLoss", handler.calls("injectUnsettledLoss"));
        console2.log("processVaultReport", handler.calls("processVaultReport"));
        console2.log("redeemIfMatureB", handler.calls("redeemIfMatureB"));
        console2.log("reportTranches", handler.calls("reportTranches"));
    }
}
