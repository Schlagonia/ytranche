// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

contract HookTest is Setup {
    function test_insolvency_allowsDepositsAndWithdrawals() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _fundReserve(10e18);
        _simulateRiskyPnL(-int256(15e18));

        (uint256 bClaim, uint256 bCovered) = controller.trancheCoverage(address(bTranche));
        assertLt(bCovered, bClaim, "B under-covered");
        assertGt(bClaim - bCovered, 0, "B shortfall");

        // New capital can still enter while a junior Tranche is under-covered.
        _airdrop(carol, 1e18);
        vm.startPrank(carol);
        asset.approve(address(aTranche), 1e18);
        ITrancheStrategy(address(aTranche)).deposit(1e18, carol);
        vm.stopPrank();

        // Exits are still allowed while under-covered, bounded by vault
        // liquidity and rate limits. The reserve is not touched by redemptions.
        assertGt(ITrancheStrategy(address(aTranche)).maxWithdraw(alice), 0);
        uint256 reserveBefore = controller.reserveAssets();
        vm.prank(alice);
        uint256 received = ITrancheStrategy(address(aTranche)).redeem(1, alice, alice);
        assertGt(received, 0, "redeem delivered assets");
        assertEq(controller.reserveAssets(), reserveBefore, "reserve untouched");
    }

    function test_exactlyCoveredSystem_isNotAutoPaused() public {
        _depositA(alice, 70e18);

        (uint256 aClaim, uint256 aCovered) = controller.trancheCoverage(address(aTranche));
        assertEq(aCovered, aClaim, "A covered");
        // Covered system: a Tranche deposit is not auto-blocked.
        assertGt(ITrancheStrategy(address(aTranche)).maxDeposit(bob), 0);
    }

    function test_rateLimit_rollsOverAfterWindow() public {
        vm.startPrank(management);
        hook.setRateLimitWindow(1 hours);
        hook.setDepositRateLimit(address(aTranche), uint128(10e18));
        vm.stopPrank();

        _fundReserve(1e18);
        _depositA(alice, 10e18); // fills the bucket

        // Next deposit should fail.
        _airdrop(alice, 1e18);
        vm.startPrank(alice);
        asset.approve(address(aTranche), 1e18);
        vm.expectRevert();
        ITrancheStrategy(address(aTranche)).deposit(1e18, alice);
        vm.stopPrank();

        // After the window rolls, it should open again.
        skip(61 minutes);
        _depositA(alice, 5e18);
    }

    function test_trancheDepositLimit_capsAggregateDeposits() public {
        vm.prank(management);
        hook.setDepositLimit(address(aTranche), 10e18);

        _depositA(alice, 7e18);

        _airdrop(bob, 4e18);
        vm.startPrank(bob);
        asset.approve(address(aTranche), 4e18);
        vm.expectRevert();
        ITrancheStrategy(address(aTranche)).deposit(4e18, bob);
        vm.stopPrank();
    }

    function test_trancheDepositLimit_usesTrancheTotalAssets() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        skip(SECONDS_PER_YEAR);
        _simulateRiskyPnL(int256(54e17));
        _settle();

        assertApproxEqAbs(controller.liveAssets(address(bTranche)), 20_850_000_000_000_000_000, 1e15, "B live");
        assertApproxEqAbs(controller.pendingExcess(address(bTranche)), 630_000_000_000_000_000, 1e15, "B pending");

        vm.prank(management);
        hook.setDepositLimit(address(bTranche), 21_500_000_000_000_000_000);

        assertApproxEqAbs(ITrancheStrategy(address(bTranche)).totalAssets(), 20_850_000_000_000_000_000, 1e15);
        assertApproxEqAbs(ITrancheStrategy(address(bTranche)).maxDeposit(carol), 650_000_000_000_000_000, 1e15);

        _reportTranches();

        assertApproxEqAbs(ITrancheStrategy(address(bTranche)).totalAssets(), 21_480_000_000_000_000_000, 1e15);
        assertApproxEqAbs(ITrancheStrategy(address(bTranche)).maxDeposit(carol), 20_000_000_000_000_000, 1e15);
    }

    function test_mainVaultDepositLimit_capsAggregateExposure() public {
        vm.prank(management);
        hook.setDepositLimit(address(mainVault), 10e18);

        _depositA(alice, 7e18);

        _airdrop(bob, 4e18);
        vm.startPrank(bob);
        asset.approve(address(aTranche), 4e18);
        vm.expectRevert();
        ITrancheStrategy(address(aTranche)).deposit(4e18, bob);
        vm.stopPrank();
    }

    /// @dev A Tranche's own maxDeposit reflects the shared main-vault ingress
    ///      limit (deposits route straight into the main vault), and the limit
    ///      is shared across Tranches.
    function test_trancheMaxDeposit_respectsMainVaultLimit() public {
        vm.prank(management);
        hook.setDepositLimit(address(mainVault), 10e18);

        _depositA(alice, 7e18);

        // 3e18 of main-vault headroom remains — both Tranches see it.
        assertEq(ITrancheStrategy(address(aTranche)).maxDeposit(bob), 3e18, "A maxDeposit capped by main vault");
        assertEq(ITrancheStrategy(address(bTranche)).maxDeposit(bob), 3e18, "B shares the same main-vault headroom");

        // A deposit within the headroom works; beyond it the cap holds.
        _depositB(bob, 3e18);
        assertEq(ITrancheStrategy(address(aTranche)).maxDeposit(carol), 0, "main-vault limit now exhausted");
    }

    function test_mainVaultRateCap_capsIngressPerWindow() public {
        vm.startPrank(management);
        hook.setRateLimitWindow(1 hours);
        hook.setDepositRateLimit(address(mainVault), uint128(10e18));
        vm.stopPrank();

        _depositA(alice, 7e18);

        _airdrop(bob, 4e18);
        vm.startPrank(bob);
        asset.approve(address(aTranche), 4e18);
        vm.expectRevert();
        ITrancheStrategy(address(aTranche)).deposit(4e18, bob);
        vm.stopPrank();
    }

    function test_gatedVault_onlyAllowedCanDeposit() public {
        // Per-Tranche gating lives on the Tranche (this contract is management).
        ITrancheStrategy(address(aTranche)).setOpen(false); // re-gate A
        ITrancheStrategy(address(aTranche)).setAllowed(alice, true);

        _depositA(alice, 5e18); // allowed

        _airdrop(bob, 5e18);
        vm.startPrank(bob);
        asset.approve(address(aTranche), 5e18);
        vm.expectRevert();
        ITrancheStrategy(address(aTranche)).deposit(5e18, bob); // not allowed
        vm.stopPrank();
    }

    /// @dev The main-vault gate (keyed by the vault) blocks direct deposits by
    ///      receiver, while the controller's own Tranche-routed deposits remain
    ///      permitted regardless.
    function test_mainVault_gateBlocksDirectDeposit() public {
        vm.prank(management);
        hook.setOpen(false); // re-gate the main vault

        // Tranche flows still work — the controller is always permitted.
        _depositA(alice, 5e18);

        // A non-allowed receiver cannot deposit directly into the main vault.
        _airdrop(bob, 10e18);
        vm.startPrank(bob);
        asset.approve(address(mainVault), 10e18);
        vm.expectRevert();
        mainVault.deposit(10e18, bob);

        // Once allowed, the direct deposit succeeds.
        vm.stopPrank();
        vm.prank(management);
        hook.setAllowed(bob, true);
        vm.prank(bob);
        uint256 shares = mainVault.deposit(10e18, bob);
        assertGt(shares, 0, "allowed receiver can deposit directly");
    }

    /// @dev The gate is per-vault: re-gating A must not affect B.
    function test_gate_isPerVault() public {
        ITrancheStrategy(address(aTranche)).setOpen(false);
        ITrancheStrategy(address(aTranche)).setAllowed(alice, true);

        // bob is not on A's list -> A deposit blocked.
        _airdrop(bob, 5e18);
        vm.startPrank(bob);
        asset.approve(address(aTranche), 5e18);
        vm.expectRevert();
        ITrancheStrategy(address(aTranche)).deposit(5e18, bob);
        vm.stopPrank();

        // B is still open -> bob deposits into B fine.
        _depositB(bob, 5e18);
    }

    /// @dev Withdrawals are never gated — a holder can still exit a vault that
    ///      has been re-gated for deposits.
    function test_withdraw_notGated() public {
        _depositA(alice, 50e18);

        ITrancheStrategy(address(aTranche)).setOpen(false); // gate deposits; alice not allowed
        // alice is NOT on the allow-list.

        assertGt(ITrancheStrategy(address(aTranche)).maxWithdraw(alice), 0, "withdraw allowed despite gate");
        vm.prank(alice);
        ITrancheStrategy(address(aTranche)).redeem(50e18, alice, alice);
        assertEq(asset.balanceOf(alice), 50e18, "gated-deposit vault still lets holders exit");
    }

    function test_mainVaultWithdrawLimit_matchesYearnStrategyLimitMath() public {
        _depositA(alice, 100e18);
        riskyStrategy.setWithdrawLimit(80e18);

        address[] memory queue = mainVault.get_default_queue();

        assertEq(hook.available_withdraw_limit(address(controller), 0, queue), 80e18);
        assertEq(hook.available_withdraw_limit(address(controller), 10_000, queue), 80e18);
        assertEq(mainVault.maxWithdraw(address(controller)), 80e18);
        assertEq(mainVault.maxWithdraw(address(controller), 10_000), 80e18);
        assertEq(mainVault.maxRedeem(address(controller)), 80e18);
    }

    function test_mainVaultWithdrawLimit_usesResolvedQueueOnly() public {
        _depositA(alice, 100e18);
        riskyStrategy.setWithdrawLimit(80e18);

        address[] memory empty;
        assertEq(mainVault.totalIdle(), 0, "idle");
        assertEq(hook.available_withdraw_limit(address(controller), 10_000, empty), 0, "empty queue only sees idle");

        address[] memory queue = mainVault.get_default_queue();
        assertEq(
            hook.available_withdraw_limit(address(controller), 10_000, queue),
            mainVault.maxWithdraw(address(controller), 10_000),
            "resolved queue mirrors vault"
        );
    }

    function test_mainVaultWithdrawLimit_zeroWhenPaused() public {
        _depositA(alice, 100e18);

        mainVault.setPaused(true);

        address[] memory queue = mainVault.get_default_queue();
        assertEq(hook.available_withdraw_limit(address(controller), 10_000, queue), 0, "paused hook limit");
        assertEq(mainVault.maxWithdraw(address(controller), 10_000), 0, "paused vault limit");
    }

    /// @dev Under an *unrealised* strategy loss (realised at the strategy level
    ///      but not yet processed into the vault), the Hook's mirrored
    ///      available_withdraw_limit must equal the vault's own maxWithdraw and
    ///      must not revert (the round-up guard prevents an underflow).
    function test_mainVaultWithdrawLimit_matchesVault_underUnrealisedLoss() public {
        _depositA(alice, 100e18);

        // Mark the strategy down 10% and realise it at the strategy level only.
        asset.burn(address(riskyStrategy), 10e18);
        vm.prank(keeper);
        IStrategy(address(riskyStrategy)).report();
        // NOTE: deliberately NOT calling mainVault.process_report — the vault
        // still books 100e18 debt while the strategy is worth 90e18.

        address[] memory queue = mainVault.get_default_queue();

        assertEq(
            hook.available_withdraw_limit(address(controller), 10_000, queue),
            mainVault.maxWithdraw(address(controller), 10_000),
            "mirror == vault (lenient loss)"
        );
        assertEq(
            hook.available_withdraw_limit(address(controller), 0, queue),
            mainVault.maxWithdraw(address(controller), 0),
            "mirror == vault (no loss tolerated)"
        );
    }

    /// @dev When the main vault can only deliver part of the position, the
    ///      Tranche's maxWithdraw is capped to that deliverable and a larger
    ///      redemption reverts rather than raiding the reserve.
    function test_trancheWithdraw_cappedByVaultLiquidity() public {
        _depositA(alice, 100e18);
        // Keep the system solvent while we throttle liquidity.
        _fundReserve(5e18);

        // Throttle the vault's deliverable to 40e18.
        riskyStrategy.setWithdrawLimit(40e18);

        assertEq(controller.vaultMaxWithdraw(), 40e18, "controller deliverable throttled");
        assertEq(ITrancheStrategy(address(aTranche)).maxWithdraw(alice), 40e18, "Tranche maxWithdraw capped");

        // Redeeming the whole position exceeds the cap -> revert.
        vm.prank(alice);
        vm.expectRevert();
        ITrancheStrategy(address(aTranche)).redeem(100e18, alice, alice);

        // Redeeming up to the cap succeeds and never touches the reserve.
        uint256 reserveBefore = controller.reserveAssets();
        uint256 maxShares = ITrancheStrategy(address(aTranche)).maxRedeem(alice);
        vm.prank(alice);
        ITrancheStrategy(address(aTranche)).redeem(maxShares, alice, alice);

        assertApproxEqAbs(asset.balanceOf(alice), 40e18, 1e12, "received the capped amount");
        assertEq(controller.reserveAssets(), reserveBefore, "reserve untouched by redemption");
    }
}
