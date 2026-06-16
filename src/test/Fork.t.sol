// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

/// @notice Targeted tests for the upstream constant accrual TokenizedStrategy branch:
///   1. views project pending fee shares so `convertTo*` prices mid-period flows
///      after the fee that accrual will mint.
///   2. live strategy NAV growth syncs through `Accrued` before reports or user
///      flows, instead of being swallowed by a live `_totalAssets()` callback.
contract ForkPatchTest is Setup {
    uint256 internal constant YEAR = 31_556_952;

    event Accrued(uint256 profit, uint256 loss, uint256 protocolFees, uint256 performanceFees);

    /*//////////////////////////////////////////////////////////////
      Constant accrual syncs live NAV before report accounting.
    //////////////////////////////////////////////////////////////*/

    function test_fork_report_accruesLiveNav_zeroFee() public {
        _depositA(alice, 70e18);
        // baseline stored is 70; no time elapsed yet.
        assertEq(ITrancheStrategy(address(aTranche)).totalAssets(), 70e18);

        // Let a full year of A accrual pass. The controller's live NAV grows,
        // but the tranche's stored baseline has not synced yet.
        skip(YEAR);

        uint256 storedBefore = ITrancheStrategy(address(aTranche)).lastTotalAssets();
        uint256 liveNav = controller.liveAssets(address(aTranche));
        uint256 expectedProfit = liveNav - storedBefore;
        assertEq(storedBefore, 70e18, "stored baseline");
        assertGt(expectedProfit, 0, "live NAV accrued");

        // Upstream constant accrual recognizes this in Accrued. The following
        // report then has no remaining delta to return as Reported profit.
        vm.expectEmit(false, false, false, true, address(aTranche));
        emit Accrued(expectedProfit, 0, 0, 0);
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = ITrancheStrategy(address(aTranche)).report();
        assertEq(profit, 0, "reported profit already accrued");
        assertEq(loss, 0, "reported loss");
        assertEq(ITrancheStrategy(address(aTranche)).lastTotalAssets(), liveNav, "baseline synced");
    }

    function test_fork_report_chargesFeeOnLiveAccrualSync() public {
        // 10% performance fee — fees go to `performanceFeeRecipient` set at deploy.
        address feeRecipient = ITrancheStrategy(address(aTranche)).performanceFeeRecipient();
        ITrancheStrategy(address(aTranche)).setPerformanceFee(1000); // 10%

        _depositA(alice, 70e18);
        skip(YEAR);

        uint256 storedBefore = ITrancheStrategy(address(aTranche)).lastTotalAssets();
        uint256 liveNav = controller.liveAssets(address(aTranche));
        uint256 expectedProfit = liveNav - storedBefore;
        uint256 expectedFees = (expectedProfit * 1000) / MAX_BPS;
        uint256 supplyBefore = ITrancheStrategy(address(aTranche)).totalSupply();
        uint256 feeRecipBalBefore = ITrancheStrategy(address(aTranche)).balanceOf(feeRecipient);
        uint256 expectedFeeShares = (expectedFees * supplyBefore) / (liveNav - expectedFees);

        vm.expectEmit(false, false, false, true, address(aTranche));
        emit Accrued(expectedProfit, 0, 0, expectedFees);
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = ITrancheStrategy(address(aTranche)).report();

        // Fee shares mint during accrual at the diluted PPS.
        uint256 supplyAfter = ITrancheStrategy(address(aTranche)).totalSupply();
        uint256 feeRecipBalAfter = ITrancheStrategy(address(aTranche)).balanceOf(feeRecipient);
        assertEq(profit, 0, "reported profit already accrued");
        assertEq(loss, 0, "reported loss");
        assertEq(feeRecipBalAfter - feeRecipBalBefore, expectedFeeShares, "fee shares minted");
        assertEq(supplyAfter - supplyBefore, expectedFeeShares, "supply grew by fee shares");
    }

    /*//////////////////////////////////////////////////////////////
      Issue #1 — views must project pending fee shares so the PPS a new
      depositor sees is the post-fee PPS. A mid-period depositor must
      not receive an implicit discount on yield that the next report
      will charge a fee on.
    //////////////////////////////////////////////////////////////*/

    function test_fork_previewDeposit_projectsPendingFees() public {
        ITrancheStrategy(address(aTranche)).setPerformanceFee(1000); // 10%

        _depositA(alice, 70e18);
        assertEq(ITrancheStrategy(address(aTranche)).balanceOf(alice), 70e18);

        skip(YEAR);

        uint256 live = controller.liveAssets(address(aTranche)); // 72.975e18

        // `totalSupply()` stays canonical — the raw S.totalSupply minus
        // unlocked shares, unchanged by the fork. No projection here.
        assertEq(ITrancheStrategy(address(aTranche)).totalSupply(), 70e18, "totalSupply stays raw");

        // `previewDeposit` uses projected fee shares under the hood. Upstream
        // mints those fee shares at the diluted PPS: feeAssets * supply /
        // (live - feeAssets).
        uint256 preview = ITrancheStrategy(address(aTranche)).previewDeposit(1e18);
        uint256 stored = ITrancheStrategy(address(aTranche)).lastTotalAssets();
        uint256 feeAssets = ((live - stored) * 1000) / MAX_BPS;
        uint256 feeShares = (feeAssets * 70e18) / (live - feeAssets);
        uint256 expectedShares = (1e18 * (70e18 + feeShares)) / live;
        assertApproxEqAbs(preview, expectedShares, 1e10, "previewDeposit projects fee");

        // A deposit *without* the projection would give `1e18 * 70 / live`
        // — strictly fewer shares than the fork now returns.
        uint256 unadjusted = (1e18 * 70e18) / live;
        assertGt(preview, unadjusted, "projection gives more shares than raw PPS would");
    }

    /// @dev Without the view-side pending-fee projection, a mid-period redeemer
    ///      would capture the full pre-fee accrued yield and sidestep the
    ///      performance fee that the next `report()` is going to charge. The
    ///      projection pulls the view PPS down by the pending fee share, so
    ///      the redeemer ends up paying their proportional fee at exit.
    function test_fork_midPeriodRedeemer_paysFeeOnAccruedYield() public {
        ITrancheStrategy(address(aTranche)).setPerformanceFee(1000); // 10%

        _depositA(alice, 70e18);
        skip(YEAR);

        // Put the accrued yield into the main vault so the controller can
        // actually deliver it on redemption.
        _simulateRiskyPnL(int256(3e18));

        uint256 aliceShares = ITrancheStrategy(address(aTranche)).balanceOf(alice);
        vm.prank(alice);
        ITrancheStrategy(address(aTranche)).redeem(aliceShares, alice, alice);

        uint256 received = asset.balanceOf(alice);

        // Pre-fee capture would be ~72.975e18 (70 * aIndex). With the pending
        // fee projected into the view supply, Alice's redemption is priced
        // strictly below that: she's paying her share of the fee on exit.
        assertLt(received, 72_975_000_000_000_000_000, "fee applied mid-period");
        assertGt(received, 72_000_000_000_000_000_000, "still receives accrued yield");
    }
}
