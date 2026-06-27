// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";
import {MockReserveVault} from "./mocks/MockReserveVault.sol";

/// @notice Smoke/basic flow tests: A deposit-withdraw, B deposit-cooldown-redeem,
///         reserve funding, and main-vault routing through the controller.
contract TrancheBasicTest is Setup {
    function test_A_depositAndRedeem_noPnL() public {
        uint256 amt = 70e18;
        _depositA(alice, amt);
        assertEq(ITrancheStrategy(address(aTranche)).balanceOf(alice), amt, "A shares 1:1 at WAD start");
        assertEq(ITrancheStrategy(address(aTranche)).totalAssets(), amt, "A NAV");
        // redeem right back
        vm.prank(alice);
        ITrancheStrategy(address(aTranche)).redeem(amt, alice, alice);
        assertEq(asset.balanceOf(alice), amt, "A user got funds back");
    }

    /// @dev During an unrealised vault loss a user can still exit (loss-taking
    ///      cap), redeeming the realisable amount and bearing the loss itself;
    ///      the reserve and other Tranches are untouched.
    function test_withdraw_passesRedeemLossToUser() public {
        _depositA(alice, 100e18);
        _fundReserve(10e18);

        // Mark the strategy down 20% at the strategy level only (no
        // process_report) — the vault now carries an unrealised loss.
        asset.burn(address(riskyStrategy), 20e18);
        vm.prank(keeper);
        IStrategy(address(riskyStrategy)).report();

        uint256 maxShares = ITrancheStrategy(address(aTranche)).maxRedeem(alice);
        assertGt(maxShares, 0, "can still exit during the deficit");
        uint256 nominal = ITrancheStrategy(address(aTranche)).convertToAssets(maxShares);

        vm.prank(alice);
        uint256 got = ITrancheStrategy(address(aTranche)).redeem(maxShares, alice, alice);

        assertEq(asset.balanceOf(alice), got, "received the returned assets");
        assertLt(got, nominal, "user bore the redeem loss");
        assertGt(got, 0, "but still received funds");
        assertApproxEqAbs(controller.reserveAssets(), 10e18, 1e15, "reserve untouched by redemption loss");
    }

    /// @dev A donation (stray idle) on the Tranche strategy must not cause the
    ///      controller to under-deliver a withdrawal — `_amount` already arrives
    ///      net of idle, so the controller must not subtract it again.
    function test_donationToTranche_doesNotUnderfundWithdrawal() public {
        uint256 amt = 70e18;
        _depositA(alice, amt);

        // Donate stray idle to the Tranche strategy. Not counted in NAV
        // (totalAssets is baseline-driven), so it doesn't change PPS.
        _airdrop(address(aTranche), 1e18);

        vm.prank(alice);
        ITrancheStrategy(address(aTranche)).redeem(amt, alice, alice);

        // Alice gets her full principal — no phantom loss from double-subtraction.
        assertEq(asset.balanceOf(alice), amt, "alice received full principal");
    }

    function test_B_deposit_and_cooldownRedeem() public {
        uint256 amt = 20e18;
        // Fund the reserve so the system stays solvent while B accrues target
        // interest (solvency counts reserve + vault vs. live liabilities). The
        // reserve is NOT a redemption source — withdrawals are capped at the
        // main vault's deliverable — but its presence keeps withdrawal caps open.
        _fundReserve(1e18);

        uint256 shares = _depositB(alice, amt);
        assertEq(ITrancheStrategy(address(bTranche)).balanceOf(alice), shares, "B shares");

        // Cannot redeem before cooldown
        vm.prank(alice);
        vm.expectRevert();
        ITrancheStrategy(address(bTranche)).redeem(shares, alice, alice);

        // Start cooldown, then fast-forward 14d, then redeem.
        vm.prank(alice);
        bTranche.startCooldown(shares);

        // Midway: still blocked.
        skip(13 days);
        vm.prank(alice);
        vm.expectRevert();
        ITrancheStrategy(address(bTranche)).redeem(shares, alice, alice);

        skip(2 days);

        // Withdrawals are capped by the main vault's loss-free deliverable. The
        // vault holds only principal (no realised yield), so B can redeem up to
        // ~principal now; accrued target interest beyond that is realised at
        // settlement, NOT paid from the reserve on redemption.
        uint256 maxAssets = ITrancheStrategy(address(bTranche)).maxWithdraw(alice);
        assertApproxEqAbs(maxAssets, amt, 1e15, "withdraw capped at vault deliverable (~principal)");

        uint256 maxShares = ITrancheStrategy(address(bTranche)).maxRedeem(alice);
        vm.prank(alice);
        ITrancheStrategy(address(bTranche)).redeem(maxShares, alice, alice);

        // User received ~principal; the small accrued remainder stays in the Tranche.
        uint256 received = asset.balanceOf(alice);
        assertApproxEqAbs(received, amt, 1e15, "received ~ principal (vault deliverable)");
    }

    function test_mainVault_directDepositAllowed() public {
        // The main vault is opened in Setup, so anyone may deposit directly
        // (identity is not checked once open). A self-receiver deposit does not
        // touch controller/Tranche accounting.
        _airdrop(alice, 10e18);
        vm.startPrank(alice);
        asset.approve(address(mainVault), 10e18);
        uint256 shares = mainVault.deposit(10e18, alice);
        vm.stopPrank();
        assertGt(shares, 0, "direct deposit now allowed");
        assertEq(mainVault.balanceOf(alice), shares, "depositor holds the shares");
        assertEq(controller.vaultAssets(), 0, "controller NAV untouched by self-receiver deposit");
    }

    function test_reserve_funding_and_accounting() public {
        _fundReserve(10e18);
        assertEq(controller.reserveAssets(), 10e18, "reserve idle");
        // A and B NAV unaffected.
        assertEq(controller.vaultAssets(), 0);
        assertEq(controller.liveAssets(address(aTranche)), 0);
        assertEq(controller.liveAssets(address(bTranche)), 0);
    }

    /// @dev Migrating the reserve vault requires the old one be swept first;
    ///      `withdrawReserve` moves the 4626 shares themselves to the receiver.
    function test_reserveVault_migration() public {
        _fundReserve(10e18);
        assertGt(reserveVault.balanceOf(address(controller)), 0, "reserve funded");

        MockReserveVault newReserve = new MockReserveVault(address(asset));

        // Can't switch while the old vault still holds shares.
        vm.prank(governance);
        vm.expectRevert(bytes("reserve not empty"));
        controller.setReserveVault(address(newReserve));

        // Sweep the old vault's shares out — they go to the receiver as-is.
        uint256 shares = reserveVault.balanceOf(address(controller));
        vm.prank(governance);
        controller.withdrawReserve(shares, treasury);
        assertEq(reserveVault.balanceOf(address(controller)), 0, "old vault emptied");
        assertEq(reserveVault.balanceOf(treasury), shares, "shares swept to receiver");

        // Now the migration is allowed.
        vm.prank(governance);
        controller.setReserveVault(address(newReserve));
        assertEq(address(controller.reserveVault()), address(newReserve), "migrated");
        assertEq(controller.reserveAssets(), 0, "new reserve starts empty");
    }

    function test_sweep_governanceCanRecoverStrayToken() public {
        _airdrop(address(controller), 5e18);

        vm.prank(governance);
        controller.sweep(address(asset), 3e18, treasury);

        assertEq(asset.balanceOf(treasury), 3e18, "treasury received stray token");
        assertEq(asset.balanceOf(address(controller)), 2e18, "remainder stayed");
    }

    function test_sweep_rejectsNonGovernance() public {
        _airdrop(address(controller), 1e18);

        vm.prank(management);
        vm.expectRevert(bytes("!authorized"));
        controller.sweep(address(asset), 1e18, treasury);
    }

    function test_sweep_protectsMainVaultToken() public {
        _airdrop(alice, 1e18);
        vm.startPrank(alice);
        asset.approve(address(mainVault), 1e18);
        mainVault.deposit(1e18, address(controller));
        vm.stopPrank();

        uint256 shares = mainVault.balanceOf(address(controller));

        vm.prank(governance);
        vm.expectRevert(bytes("protected token"));
        controller.sweep(address(mainVault), shares, treasury);

        assertEq(mainVault.balanceOf(address(controller)), shares, "vault shares stayed protected");
    }

    /// @dev The reserve vault can be cleared to address(0); reserve then
    ///      contributes 0 and flows still work.
    function test_reserveVault_clearToZero() public {
        // Reserve is unfunded at setup, so the old-empty guard passes.
        vm.prank(governance);
        controller.setReserveVault(address(0));
        assertEq(address(controller.reserveVault()), address(0), "cleared");
        assertEq(controller.reserveAssets(), 0, "no reserve contributes 0");

        // System still functions without a reserve vault.
        _depositA(alice, 10e18);
        assertEq(controller.vaultAssets(), 10e18);
    }

    function test_A_deposit_flowsThroughMainVault() public {
        _depositA(alice, 70e18);
        assertEq(controller.vaultAssets(), 70e18, "funds arrived at main vault");
        // liquid parking holds the underlying
        assertEq(asset.balanceOf(address(riskyStrategy)), 70e18);
    }

    function test_B_deposit_flowsThroughMainVault() public {
        _depositB(alice, 20e18);
        assertEq(controller.vaultAssets(), 20e18);
        assertEq(asset.balanceOf(address(riskyStrategy)), 20e18);
    }
}
