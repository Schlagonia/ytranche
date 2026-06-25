// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";

/// @notice Golden illustration tests for the symmetric A/B/E model.
///   Default config:
///     A target = 4.25 %/yr, A excess = 0      (senior)
///     B target = 4.25 %/yr, B excess = 4000   (junior, 40 %)
///     E target = 0,         E excess = 6000   (equity, 60 %)
///   Stack used here: A = 70, B = 20, reserve = 10, risky deposit = 90.
///   E starts at 0 — its baseline accumulates the equity promote even
///   without depositors (would be claimable if E shares existed).
///   After one year: A.base = 72.975, B.base = 20.85, E.base = 0,
///   totalClaim = 93.825.
contract IllustrationTest is Setup {
    uint256 internal constant A_AMT = 70e18;
    uint256 internal constant B_AMT = 20e18;
    uint256 internal constant R_AMT = 10e18;
    uint256 internal constant YEAR = 31_556_952;

    function _stackAndYear(int256 pnl) internal {
        _depositA(alice, A_AMT);
        _depositB(bob, B_AMT);
        _fundReserve(R_AMT);
        skip(YEAR);
        _simulateRiskyPnL(pnl);
        _settle();
        // Excess is pending after settle — realized at each Tranche's report.
        _reportTranches();
    }

    function _approx(uint256 got, uint256 want, uint256 tol, string memory lbl) internal pure {
        uint256 diff = got > want ? got - want : want - got;
        require(diff <= tol, string(abi.encodePacked("approx: ", lbl)));
    }

    /// @dev 5 % risky year (4.50 profit). Surplus = 0.675.
    ///        toA = 0, toB = 0.270, toE = 0.405.
    function test_illustration_5pct() public {
        _stackAndYear(int256(45e17));
        _approx(controller.liveAssets(address(aTranche)), 72_975_000_000_000_000_000, 1e15, "A NAV");
        _approx(controller.liveAssets(address(bTranche)), 21_120_000_000_000_000_000, 1e15, "B NAV");
        _approx(controller.liveAssets(address(eTranche)), 405_000_000_000_000_000, 1e15, "E NAV");
        // Reserve is unchanged — equity flows to E now, not reserve.
        _approx(controller.reserveAssets(), 10_000_000_000_000_000_000, 1e15, "reserve");
    }

    /// @dev 6 % risky year (5.40 profit). Surplus = 1.575.
    ///        toB = 0.630, toE = 0.945.
    function test_illustration_6pct() public {
        _stackAndYear(int256(54e17));
        _approx(controller.liveAssets(address(aTranche)), 72_975_000_000_000_000_000, 1e15, "A NAV");
        _approx(controller.liveAssets(address(bTranche)), 21_480_000_000_000_000_000, 1e15, "B NAV");
        _approx(controller.liveAssets(address(eTranche)), 945_000_000_000_000_000, 1e15, "E NAV");
        _approx(controller.reserveAssets(), 10_000_000_000_000_000_000, 1e15, "reserve");
    }

    /// @dev 7 % risky year (6.30 profit). Surplus = 2.475.
    ///        toB = 0.990, toE = 1.485.
    function test_illustration_7pct() public {
        _stackAndYear(int256(63e17));
        _approx(controller.liveAssets(address(aTranche)), 72_975_000_000_000_000_000, 1e15, "A NAV");
        _approx(controller.liveAssets(address(bTranche)), 21_840_000_000_000_000_000, 1e15, "B NAV");
        _approx(controller.liveAssets(address(eTranche)), 1_485_000_000_000_000_000, 1e15, "E NAV");
        _approx(controller.reserveAssets(), 10_000_000_000_000_000_000, 1e15, "reserve");
    }

    /// @dev 4 % risky year (3.60 profit). Shortfall = 0.225 → reserve.
    function test_illustration_weakYear_4pct() public {
        _stackAndYear(int256(36e17));
        _approx(controller.liveAssets(address(aTranche)), 72_975_000_000_000_000_000, 1e15, "A NAV whole");
        _approx(controller.liveAssets(address(bTranche)), 20_850_000_000_000_000_000, 1e15, "B NAV whole");
        _approx(controller.liveAssets(address(eTranche)), 0, 1e15, "E flat");
        _approx(controller.reserveAssets(), 9_775_000_000_000_000_000, 1e15, "reserve drained");
        assertFalse(controller.isAccrualPaused(address(aTranche)));
        assertFalse(controller.isAccrualPaused(address(bTranche)));
        assertFalse(controller.isAccrualPaused(address(eTranche)));
    }

    /// @dev 2 % risky year (1.80 profit). Shortfall = 2.025 → reserve.
    function test_illustration_stressed_2pct() public {
        _stackAndYear(int256(18e17));
        _approx(controller.liveAssets(address(aTranche)), 72_975_000_000_000_000_000, 1e15, "A NAV whole");
        _approx(controller.liveAssets(address(bTranche)), 20_850_000_000_000_000_000, 1e15, "B NAV whole");
        _approx(controller.reserveAssets(), 7_975_000_000_000_000_000, 1e15, "reserve drained");
    }

    /// @dev Negative year (−20 risky). Total loss vs claim = 23.825.
    ///      Reserve absorbs 10, E absorbs 0, B absorbs 13.825 (accrual paused).
    function test_illustration_negativeYear() public {
        _depositA(alice, A_AMT);
        _depositB(bob, B_AMT);
        _fundReserve(R_AMT);
        skip(YEAR);
        _simulateRiskyPnL(-int256(20e18));
        _settle();
        _approx(controller.liveAssets(address(aTranche)), 72_975_000_000_000_000_000, 1e15, "A whole");
        _approx(controller.liveAssets(address(bTranche)), 7_025_000_000_000_000_000, 1e15, "B haircut");
        _approx(controller.reserveAssets(), 0, 1e15, "reserve wiped");
        assertFalse(controller.isAccrualPaused(address(aTranche)), "A still accruing");
        assertTrue(controller.isAccrualPaused(address(bTranche)), "B accrual paused on haircut");
    }

    /// @dev Alternate split: A=0, B=7000, E=3000 on the 6 % year.
    ///      Surplus = 1.575. toB = 1.1025. toE = 0.4725.
    function test_alternateSplit_70_30() public {
        vm.startPrank(governance);
        // Lower E first to make room for B.
        controller.setTrancheExcessShareBps(address(eTranche), 3000);
        controller.setTrancheExcessShareBps(address(bTranche), 7000);
        vm.stopPrank();
        _stackAndYear(int256(54e17));
        _approx(controller.liveAssets(address(aTranche)), 72_975_000_000_000_000_000, 1e15, "A NAV");
        _approx(controller.liveAssets(address(bTranche)), 21_952_500_000_000_000_000, 1e15, "B NAV 70pct");
        _approx(controller.liveAssets(address(eTranche)), 472_500_000_000_000_000, 1e15, "E NAV 30pct");
    }

    /// @dev A also takes a slice: A=2000, B=4000, E=4000 on 7 % year.
    ///      Surplus = 2.475. toA = 0.495, toB = 0.990, toE = 0.990.
    function test_aAlsoTakesExcess() public {
        vm.startPrank(governance);
        controller.setTrancheExcessShareBps(address(eTranche), 4000);
        controller.setTrancheExcessShareBps(address(aTranche), 2000);
        controller.setTrancheExcessShareBps(address(bTranche), 4000);
        vm.stopPrank();
        _stackAndYear(int256(63e17));
        _approx(controller.liveAssets(address(aTranche)), 73_470_000_000_000_000_000, 1e15, "A NAV with excess");
        _approx(controller.liveAssets(address(bTranche)), 21_840_000_000_000_000_000, 1e15, "B NAV");
        _approx(controller.liveAssets(address(eTranche)), 990_000_000_000_000_000, 1e15, "E NAV 40pct");
    }

    /// @dev Different target rates: A=2.00 %, B=8.00 %.
    ///      After 1y: A.base = 71.4; B.base = 21.6. totalClaim = 93.0.
    ///      Risky after 6 % = 95.4. Surplus = 2.40.
    ///      toB = 0.96, toE = 1.44 (default A excess = 0, B excess = 4000, E excess = 6000).
    function test_differentTargetRates() public {
        vm.startPrank(governance);
        controller.setTrancheTargetBps(address(aTranche), 200);
        controller.setTrancheTargetBps(address(bTranche), 800);
        vm.stopPrank();
        _depositA(alice, A_AMT);
        _depositB(bob, B_AMT);
        _fundReserve(R_AMT);
        skip(YEAR);
        _simulateRiskyPnL(int256(54e17));
        _settle();
        _reportTranches();
        _approx(controller.liveAssets(address(aTranche)), 71_400_000_000_000_000_000, 1e15, "A NAV (2%)");
        _approx(controller.liveAssets(address(bTranche)), 22_560_000_000_000_000_000, 1e15, "B NAV (8% + 0.96 excess)");
        _approx(controller.liveAssets(address(eTranche)), 1_440_000_000_000_000_000, 1e15, "E NAV 60%");
    }
}
