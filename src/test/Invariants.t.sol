// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

/// @notice Invariants for the symmetric A/B/E tranche model.
///   Defaults:
///     A target 4.25 %/yr, A excess 0
///     B target 4.25 %/yr, B excess 4000  (40 %)
///     E target 0,         E excess 6000  (60 %)
///   Loss waterfall: reserve → E → B → A
///   Profit path:    A target → B target → E target → split excess by shares
contract InvariantsTest is Setup {
    uint256 internal constant YEAR = 31_556_952;

    event TrancheFrozenSet(address indexed tranche, bool frozen);
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
        assertTrue(controller.isFrozen(address(bTranche)));
        assertTrue(controller.isFrozen(address(aTranche)));
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
        assertTrue(controller.isFrozen(address(bTranche)));
        assertGt(controller.liveAssets(address(aTranche)), 70e18, "A unaffected");
        assertFalse(controller.isFrozen(address(aTranche)));
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

    /// @dev Excess recorded at settle stays pending — out of live NAV —
    ///      until the tranche realizes it during report().
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

    /// @dev The reserve absorbs loss before any tranche's pending excess. A
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
        assertFalse(controller.isFrozen(address(bTranche)), "B not frozen");
        assertApproxEqAbs(
            controller.pendingExcess(address(bTranche)) + controller.pendingExcess(address(eTranche)),
            1_575_000_000_000_000_000,
            1e15,
            "pending untouched"
        );
    }

    /// @dev Once the reserve is exhausted, loss spills into tranches in reverse
    ///      priority, eating each tranche's pending excess before its baseline
    ///      (and without freezing while only pending is lost).
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
        // Baselines are untouched, but losing pending excess still freezes a
        // tranche (loss is loss, regardless of which part of the claim it hit).
        assertApproxEqAbs(controller.liveAssets(address(bTranche)), 20_850_000_000_000_000_000, 1e15, "B base whole");
        assertApproxEqAbs(controller.liveAssets(address(aTranche)), 72_975_000_000_000_000_000, 1e15, "A base whole");
        assertTrue(controller.isFrozen(address(eTranche)), "E frozen on pending loss");
        assertTrue(controller.isFrozen(address(bTranche)), "B frozen on pending loss");
        assertFalse(controller.isFrozen(address(aTranche)), "A untouched, not frozen");
    }

    /// @dev A tranche taking a loss freezes and emits a single combined
    ///      TrancheLoss (here B's baseline absorbs the whole 10).
    function test_inv_trancheLoss_eventEmitted() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        // No reserve, no time skip → claims == deposits, loss hits B's baseline.
        _simulateRiskyPnL(-int256(10e18));

        vm.expectEmit(true, false, false, true, address(controller));
        emit TrancheFrozenSet(address(bTranche), true);
        vm.expectEmit(true, false, false, true, address(controller));
        emit TrancheLoss(address(bTranche), 10e18);
        _settle();
    }

    /// @dev A tranche frozen by a loss resumes accrual automatically on
    ///      the next strictly profitable settle.
    function test_inv_autoUnfreeze_onProfitableSettle() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        skip(YEAR);
        _simulateRiskyPnL(-int256(10e18)); // no reserve — B takes the hit
        _settle();
        assertTrue(controller.isFrozen(address(bTranche)), "B frozen on loss");

        // A merely break-even settle must NOT unfreeze.
        _settle();
        assertTrue(controller.isFrozen(address(bTranche)), "break-even keeps freeze");

        // Vault earns again — freeze lifts and accrual resumes.
        _simulateRiskyPnL(int256(5e18));
        _settle();
        assertFalse(controller.isFrozen(address(bTranche)), "B unfrozen on profit");
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
