// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";
import {MockRoundUpReserveVault} from "./mocks/MockRoundUpReserveVault.sol";

/// @notice Deterministic, single-scenario tests for the symmetric A/B/E Tranche
///   model. (Renamed from Invariants.t.sol: these are hand-written scenarios; the
///   stateful Foundry invariants live in test/invariant/.)
///   Defaults:
///     A target 4.25 %/yr, A excess 0
///     B target 4.25 %/yr, B excess 4000  (40 %)
///     E target 0,         E excess 6000  (60 %)
///   Loss waterfall: reserve -> E -> B -> A
///   Profit path:    A target -> B target -> E target -> split excess by shares
contract ScenariosTest is Setup {
    uint256 internal constant YEAR = 31_556_952;

    event TrancheAccrualPausedSet(address indexed tranche, bool accrualPaused);
    event TrancheLoss(address indexed tranche, uint256 amount);

    function test_inv_reserveSeparate_fromRisky() public {
        _depositA(alice, 100e18);
        _fundReserve(50e18);
        assertEq(controller.vaultAssets(), 100e18);
        assertEq(controller.reserveAssets(), 50e18);
    }

    function test_inv_excess_zeroWhenJustCoveringTargets() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _fundReserve(10e18);
        skip(YEAR);
        _simulateRiskyPnL(int256(3_825_000_000_000_000_000));
        _settle();
        uint256 res = controller.reserveAssets();
        assertLe(res, 10e18 + 1e15, "no equity flow to reserve");
        assertGe(res, 10e18 - 1e15, "reserve unchanged");
        assertLe(controller.liveAssets(address(eTranche)), 1e15);
    }

    function test_inv_AlossOnly_afterReserveAndB() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _fundReserve(10e18);
        skip(YEAR);
        _simulateRiskyPnL(-int256(35e18));
        _settle();
        assertEq(controller.reserveAssets(), 0, "reserve wiped");
        assertEq(controller.liveAssets(address(bTranche)), 0, "B wiped");
        assertTrue(controller.isAccrualPaused(address(bTranche)));
        assertTrue(controller.isAccrualPaused(address(aTranche)));
        uint256 a = controller.liveAssets(address(aTranche));
        assertGt(a, 64_995_000_000_000_000_000);
        assertLt(a, 65_005_000_000_000_000_000);
    }

    function test_inv_BlossOnly_afterReserveExhausted() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _fundReserve(10e18);
        skip(YEAR);
        _simulateRiskyPnL(-int256(15e18));
        _settle();
        assertEq(controller.reserveAssets(), 0);
        uint256 b = controller.liveAssets(address(bTranche));
        assertGt(b, 12_020_000_000_000_000_000);
        assertLt(b, 12_030_000_000_000_000_000);
        assertTrue(controller.isAccrualPaused(address(bTranche)));
        assertGt(controller.liveAssets(address(aTranche)), 70e18, "A unaffected");
        assertFalse(controller.isAccrualPaused(address(aTranche)));
    }

    function test_inv_fullReserveDrainUsesRedeem() public {
        _depositA(alice, 70e18);
        _fundReserve(10e18);
        reserveVault.setRevertWithdraw(true);

        _simulateRiskyPnL(-int256(10e18));
        _settle();

        assertEq(controller.reserveAssets(), 0, "reserve fully redeemed");
        assertEq(controller.liveAssets(address(aTranche)), 70e18, "A whole");
        assertFalse(controller.isAccrualPaused(address(aTranche)), "A accrual not paused");
    }

    function test_inv_trancheCoverage_isSeniorFirst() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _fundReserve(10e18);
        _simulateRiskyPnL(-int256(35e18));

        assertEq(controller.backingAssets(), 65e18, "backing");

        (uint256 aClaim, uint256 aCovered) = controller.trancheCoverage(address(aTranche));
        assertEq(aClaim, 70e18, "A claim");
        assertEq(aCovered, 65e18, "A covered");

        (uint256 bClaim, uint256 bCovered) = controller.trancheCoverage(address(bTranche));
        assertEq(bClaim, 20e18, "B claim");
        assertEq(bCovered, 0, "B covered");
    }

    function test_inv_cooledShares_remainEconomicallyActive() public {
        _depositB(alice, 20e18);
        uint256 nav0 = controller.liveAssets(address(bTranche));
        vm.prank(alice);
        bTranche.startCooldown(20e18);
        assertEq(controller.liveAssets(address(bTranche)), nav0);
        vm.prank(alice);
        vm.expectRevert(bytes("Cannot transfer shares in cooldown"));
        ITrancheStrategy(address(bTranche)).transfer(bob, 1);
    }

    function test_inv_capitalFlow_notMisclassifiedAsPnL() public {
        _depositA(alice, 50e18);
        _depositB(bob, 30e18);
        _fundReserve(20e18);
        _settle();
        uint256 res0 = controller.reserveAssets();
        uint256 bNav0 = controller.liveAssets(address(bTranche));
        _depositA(carol, 10e18);
        uint256 carolBal = ITrancheStrategy(address(aTranche)).balanceOf(carol);
        vm.prank(carol);
        ITrancheStrategy(address(aTranche)).redeem(carolBal, carol, carol);
        _settle();
        assertEq(controller.reserveAssets(), res0, "no spurious equity flow");
        assertEq(controller.liveAssets(address(bTranche)), bNav0, "no spurious B credit");
    }

    function test_inv_zeroBSupply_settleWorks() public {
        _depositA(alice, 70e18);
        _fundReserve(10e18);
        skip(YEAR);
        _simulateRiskyPnL(int256(5e18));
        _settle();
        assertGt(controller.liveAssets(address(aTranche)), 70e18);
    }

    function test_inv_zeroASupply_settleWorks() public {
        _depositB(bob, 20e18);
        _fundReserve(10e18);
        skip(YEAR);
        _simulateRiskyPnL(int256(3e18));
        _settle();
        assertEq(ITrancheStrategy(address(aTranche)).totalSupply(), 0);
        assertEq(controller.liveAssets(address(aTranche)), 0);
    }

    /// @dev With E excess = 6000 (60 %), an E user gets the equity promote.
    function test_inv_eUserCapturesEquityPromote() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _depositE(eve, 1e18);
        skip(YEAR);
        _simulateRiskyPnL(int256(45e17)); // 4.50
        _settle();
        _reportTranches();
        // E.baseline = principal (1.0) + 60% × 0.675 = 1.405
        uint256 e = controller.liveAssets(address(eTranche));
        assertGt(e, 1_400_000_000_000_000_000);
        assertLt(e, 1_410_000_000_000_000_000);
    }

    /// @dev §5.4 / M-2 — excess assigned to a zero-supply Tranche is stranded as
    ///      pendingExcess and then captured wholesale by the FIRST depositor when
    ///      realized. Documents the windfall behavior.
    function test_scenario_zeroSupplyExcess_inflatesFirstDepositor() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        // E has a 60% excess share but no deposits (zero supply).
        skip(YEAR);
        _simulateRiskyPnL(int256(45e17)); // 4.50 profit
        _settle();

        uint256 ePending = controller.pendingExcess(address(eTranche));
        assertGt(ePending, 0, "excess assigned to empty E");
        assertEq(ITrancheStrategy(address(eTranche)).totalSupply(), 0, "E still empty");

        // First E depositor arrives; report realizes the stranded excess into the
        // baseline, so the lone depositor captures it on top of principal.
        _depositE(eve, 1e18);
        _reportTranches();
        uint256 eShares = ITrancheStrategy(address(eTranche)).balanceOf(eve);
        uint256 eValue = ITrancheStrategy(address(eTranche)).convertToAssets(eShares);
        assertApproxEqAbs(eValue, 1e18 + ePending, 1e15, "first depositor captured stranded excess");
    }

    /// @dev §5.1 / M-3 — full reserve drain in settle() does not revert even when the
    ///      reserve vault rounds withdrawal shares UP past the held balance, because
    ///      the controller clamps the draw to maxRedeem and redeems share-exact.
    function test_scenario_fullReserveDrain_roundUpDoesNotRevert() public {
        MockRoundUpReserveVault ru = new MockRoundUpReserveVault(address(asset));
        vm.prank(governance);
        controller.setReserveVault(address(ru));

        _depositA(alice, 70e18);
        _fundReserve(10e18); // funds the adversarial reserve

        // The reserve's previewWithdraw over-reports shares vs. what is held.
        uint256 held = ru.balanceOf(address(controller));
        assertGt(ru.previewWithdraw(controller.reserveAssets()), held, "round-up exceeds held shares");

        // A loss larger than the full reserve forces settle() to drain all of it.
        skip(YEAR);
        _simulateRiskyPnL(-int256(20e18));
        _settle(); // must NOT revert

        assertApproxEqAbs(controller.reserveAssets(), 0, 1e12, "reserve fully drained");
    }

    /// @dev §5.2 — fuzz the loss waterfall: the senior Tranche is untouched as long
    ///      as the junior buffer (reserve + E + B) can absorb the loss, and only
    ///      absorbs once that buffer is exhausted. No time skip -> no target accrual.
    function testFuzz_lossAbsorptionJuniorFirst(uint256 lossSeed) public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _depositE(eve, 10e18);
        _fundReserve(10e18);

        uint256 loss = bound(lossSeed, 0, 95e18);
        _simulateRiskyPnL(-int256(loss));
        _settle();

        uint256 aLive = controller.liveAssets(address(aTranche));
        uint256 juniorBuffer = 10e18 + 10e18 + 20e18; // reserve + E + B

        if (loss <= juniorBuffer) {
            assertApproxEqAbs(aLive, 70e18, 1e12, "senior untouched while junior buffer remains");
            assertFalse(controller.isAccrualPaused(address(aTranche)), "A accrual not paused");
        } else {
            assertLt(aLive, 70e18, "senior absorbs only after junior buffer exhausted");
        }
    }

    /// @dev §5.2 — fuzz the excess split: it is assigned by excessShareBps, so for
    ///      any profitable settle E (60%) > B (40%) > A (0).
    function testFuzz_excessSplit_byBps(uint256 profitSeed) public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _depositE(eve, 10e18);
        skip(YEAR);
        uint256 profit = bound(profitSeed, 10e18, 1000e18); // exceeds targets -> real excess
        _simulateRiskyPnL(int256(profit));
        _settle();

        assertEq(controller.pendingExcess(address(aTranche)), 0, "A has 0 excess share");
        uint256 b = controller.pendingExcess(address(bTranche));
        uint256 e = controller.pendingExcess(address(eTranche));
        assertGt(b, 0, "B got excess");
        assertGt(e, b, "E (60%) > B (40%)");
    }

    /// @dev §5.2 — fuzz target accrual: it is monotonic in time and bounded above by
    ///      a rate slightly over the 4.25%/yr target (the per-second rate truncates
    ///      down, so realized accrual never exceeds the nominal bound).
    function testFuzz_targetAccrual_monotonicAndBounded(uint256 amtSeed, uint256 timeSeed) public {
        uint256 amt = bound(amtSeed, 1e18, 1_000_000e18);
        _depositA(alice, amt);
        uint256 base = controller.liveAssets(address(aTranche));

        uint256 t = bound(timeSeed, 0, 365 days);
        skip(t);
        uint256 grown = controller.liveAssets(address(aTranche));

        assertGe(grown, base, "accrual monotonic");
        uint256 maxGrowth = base + (base * 500 * t) / (10_000 * YEAR); // 5%/yr ceiling
        assertLe(grown, maxGrowth + 1, "accrual within target bound");
    }

    /// @dev §5.1 — a reserve that has itself lost value (marked down) is still drawn
    ///      correctly at settle, with the residual loss flowing to the senior.
    function test_scenario_reserveLoss_handledAtSettle() public {
        _depositA(alice, 70e18);
        _fundReserve(10e18);

        // Simulate a reserve-vault loss by burning underlying it holds.
        asset.burn(address(reserveVault), 3e18);
        assertApproxEqAbs(controller.reserveAssets(), 7e18, 1, "reserve marked down to 7");

        skip(YEAR);
        _simulateRiskyPnL(-int256(20e18));
        _settle();

        assertApproxEqAbs(controller.reserveAssets(), 0, 1e12, "depleted reserve fully drawn");
        assertTrue(controller.isAccrualPaused(address(aTranche)), "senior absorbs residual loss");
    }

    /// @dev Excess recorded at settle stays pending — out of live NAV —
    ///      until the Tranche realizes it during report().
    function test_inv_excessPending_untilReport() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        skip(YEAR);
        _simulateRiskyPnL(int256(54e17)); // 5.40 → surplus 1.575
        _settle();

        // Settle records pending but does not touch live NAV.
        assertApproxEqAbs(controller.liveAssets(address(bTranche)), 20_850_000_000_000_000_000, 1e15, "B NAV flat");
        assertApproxEqAbs(controller.pendingExcess(address(bTranche)), 630_000_000_000_000_000, 1e15, "B pending");
        assertApproxEqAbs(controller.pendingExcess(address(eTranche)), 945_000_000_000_000_000, 1e15, "E pending");

        // Report realizes pending into the baseline and clears it.
        _reportTranches();
        assertEq(controller.pendingExcess(address(bTranche)), 0, "B pending cleared");
        assertApproxEqAbs(controller.liveAssets(address(bTranche)), 21_480_000_000_000_000_000, 1e15, "B NAV realized");
    }

    /// @dev Settling twice without a report must not re-distribute the
    ///      same surplus.
    function test_inv_doubleSettle_noDoubleCount() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        skip(YEAR);
        _simulateRiskyPnL(int256(54e17));
        _settle();
        uint256 bPending = controller.pendingExcess(address(bTranche));
        uint256 ePending = controller.pendingExcess(address(eTranche));
        _settle();
        assertEq(controller.pendingExcess(address(bTranche)), bPending, "B pending unchanged");
        assertEq(controller.pendingExcess(address(eTranche)), ePending, "E pending unchanged");
    }

    /// @dev The reserve absorbs loss before any Tranche's pending excess. A
    ///      loss smaller than the reserve leaves all pending excess and every
    ///      baseline whole.
    function test_inv_loss_eatsReserveBeforePending() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _fundReserve(10e18);
        skip(YEAR);
        _simulateRiskyPnL(int256(54e17)); // surplus 1.575 → pending
        _settle();
        uint256 totalPending = controller.pendingExcess(address(bTranche)) + controller.pendingExcess(address(eTranche));
        assertApproxEqAbs(totalPending, 1_575_000_000_000_000_000, 1e15, "pending recorded");

        // Lose less than the reserve — reserve absorbs it, pending untouched.
        _simulateRiskyPnL(-int256(1e18));
        _settle();
        assertApproxEqAbs(controller.reserveAssets(), 9e18, 1e15, "reserve absorbed the loss");
        assertApproxEqAbs(controller.liveAssets(address(bTranche)), 20_850_000_000_000_000_000, 1e15, "B base whole");
        assertFalse(controller.isAccrualPaused(address(bTranche)), "B accrual not paused");
        assertApproxEqAbs(
            controller.pendingExcess(address(bTranche)) + controller.pendingExcess(address(eTranche)),
            1_575_000_000_000_000_000,
            1e15,
            "pending untouched"
        );
    }

    /// @dev Once the reserve is exhausted, loss spills into Tranches in reverse
    ///      priority, eating each Tranche's pending excess before its baseline.
    ///      Current accrual pause policy still pauses any Tranche that absorbs loss.
    function test_inv_loss_pendingAbsorbsAtTranchePriority() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _fundReserve(10e18);
        skip(YEAR);
        _simulateRiskyPnL(int256(54e17)); // surplus 1.575 → B pending .63, E pending .945
        _settle();

        // Lose 11 — reserve (10) is exhausted, 1.0 spills into pending junior-first.
        _simulateRiskyPnL(-int256(11e18));
        _settle();

        assertApproxEqAbs(controller.reserveAssets(), 0, 1e15, "reserve exhausted");
        // E (junior) pending wiped first, then B pending nicked by the remainder.
        assertApproxEqAbs(controller.pendingExcess(address(eTranche)), 0, 1e15, "E pending wiped");
        assertApproxEqAbs(
            controller.pendingExcess(address(bTranche)), 575_000_000_000_000_000, 1e15, "B pending nicked"
        );
        // Baselines are untouched, but losing pending excess still pauses accrual for a
        // Tranche (loss is loss, regardless of which part of the claim it hit).
        assertApproxEqAbs(controller.liveAssets(address(bTranche)), 20_850_000_000_000_000_000, 1e15, "B base whole");
        assertApproxEqAbs(controller.liveAssets(address(aTranche)), 72_975_000_000_000_000_000, 1e15, "A base whole");
        assertTrue(controller.isAccrualPaused(address(eTranche)), "E accrual paused on pending loss");
        assertTrue(controller.isAccrualPaused(address(bTranche)), "B accrual paused on pending loss");
        assertFalse(controller.isAccrualPaused(address(aTranche)), "A untouched, accrual not paused");
    }

    /// @dev A Tranche taking a loss pauses accrual and emits a single combined
    ///      TrancheLoss (here B's baseline absorbs the whole 10).
    function test_inv_trancheLoss_eventEmitted() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        // No reserve, no time skip → claims == deposits, loss hits B's baseline.
        _simulateRiskyPnL(-int256(10e18));

        vm.expectEmit(true, false, false, true, address(controller));
        emit TrancheAccrualPausedSet(address(bTranche), true);
        vm.expectEmit(true, false, false, true, address(controller));
        emit TrancheLoss(address(bTranche), 10e18);
        _settle();
    }

    /// @dev A Tranche paused by a loss resumes accrual automatically on
    ///      the next strictly profitable settle.
    function test_inv_autoResumeAccrual_onProfitableSettle() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        skip(YEAR);
        _simulateRiskyPnL(-int256(10e18)); // no reserve — B takes the hit
        _settle();
        assertTrue(controller.isAccrualPaused(address(bTranche)), "B accrual paused on loss");

        // A merely break-even settle must NOT resume accrual.
        _settle();
        assertTrue(controller.isAccrualPaused(address(bTranche)), "break-even keeps accrual paused");

        // Vault earns again — the pause lifts and accrual resumes.
        _simulateRiskyPnL(int256(5e18));
        _settle();
        assertFalse(controller.isAccrualPaused(address(bTranche)), "B accrual resumed on profit");
        uint256 bNav = controller.liveAssets(address(bTranche));
        skip(YEAR);
        assertGt(controller.liveAssets(address(bTranche)), bNav, "B accruing again");
    }

    function test_inv_AandBAccrueSymmetrically() public {
        _depositA(alice, 50e18);
        _depositB(bob, 50e18);
        skip(YEAR);
        assertApproxEqAbs(controller.liveAssets(address(aTranche)), 52_125_000_000_000_000_000, 1e15);
        assertApproxEqAbs(controller.liveAssets(address(bTranche)), 52_125_000_000_000_000_000, 1e15);
    }
}
