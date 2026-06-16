// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

/// @notice Central {EmergencyAdmin} — halts the main vault and strategies through
///   the Yearn V3 primitives. Gated by EMERGENCY_ROLE (governance is superuser).
contract EmergencyAdminTest is Setup {
    /// @dev Grant EMERGENCY_ROLE to `_who` (cache the role id before the prank so
    ///      the view call doesn't consume it).
    function _grantEmergency(address _who) internal {
        bytes32 role = emergencyAdmin.EMERGENCY_ROLE();
        vm.prank(management);
        authorizer.grantRole(role, _who);
    }

    function _depositReverts(address _tranche, address _user, uint256 _amt) internal {
        _airdrop(_user, _amt);
        vm.startPrank(_user);
        asset.approve(_tranche, _amt);
        vm.expectRevert();
        ITrancheStrategy(_tranche).deposit(_amt, _user);
        vm.stopPrank();
    }

    function test_pauseVault_blocksDepositsAndWithdrawals() public {
        uint256 shares = _depositA(alice, 50e18);

        _grantEmergency(carol);
        vm.prank(carol);
        emergencyAdmin.pauseVault(address(mainVault));

        // Tranche deposit routes into the paused vault and reverts.
        _depositReverts(address(aTranche), bob, 10e18);

        // Direct main-vault deposit reverts too.
        _airdrop(eve, 10e18);
        vm.startPrank(eve);
        asset.approve(address(mainVault), 10e18);
        vm.expectRevert();
        mainVault.deposit(10e18, eve);
        vm.stopPrank();

        // Withdrawals are blocked while paused.
        vm.prank(alice);
        vm.expectRevert();
        ITrancheStrategy(address(aTranche)).redeem(shares, alice, alice);
    }

    function test_shutdownVault_blocksDepositsAllowsWithdrawals() public {
        uint256 shares = _depositA(alice, 50e18);

        _grantEmergency(carol);
        vm.prank(carol);
        emergencyAdmin.shutdownVault(address(mainVault));

        // Deposits blocked once shut down.
        _depositReverts(address(aTranche), bob, 10e18);

        // But holders can still exit.
        vm.prank(alice);
        ITrancheStrategy(address(aTranche)).redeem(shares, alice, alice);
        assertApproxEqAbs(asset.balanceOf(alice), 50e18, 1e15, "alice exited after shutdown");
    }

    function test_pauseStrategy_isScoped() public {
        _grantEmergency(carol);
        vm.prank(carol);
        emergencyAdmin.pauseVault(address(bTranche));

        assertTrue(ITrancheStrategy(address(bTranche)).isPaused(), "B paused");

        // B is blocked, A is unaffected.
        _depositReverts(address(bTranche), bob, 10e18);
        _depositA(alice, 10e18);
    }

    function test_shutdownStrategy() public {
        _grantEmergency(carol);
        vm.prank(carol);
        emergencyAdmin.shutdownStrategy(address(aTranche));

        assertTrue(ITrancheStrategy(address(aTranche)).isShutdown(), "A shut down");
        _depositReverts(address(aTranche), bob, 10e18);
    }

    function test_emergencyWithdraw_requiresPausedOrShutdown() public {
        _depositA(alice, 50e18);
        _grantEmergency(carol);

        // Before a halt, emergencyWithdraw reverts.
        vm.prank(carol);
        vm.expectRevert(bytes("not paused or shutdown"));
        emergencyAdmin.emergencyWithdraw(address(aTranche), 1e18);

        // After pausing the strategy it succeeds (a no-op for Tranches today).
        vm.startPrank(carol);
        emergencyAdmin.pauseVault(address(aTranche));
        emergencyAdmin.emergencyWithdraw(address(aTranche), 1e18);
        vm.stopPrank();
    }

    function test_zeroMaxDebtForStrategy() public {
        assertEq(mainVault.strategies(address(riskyStrategy)).max_debt, type(uint256).max, "pre max debt");

        _grantEmergency(carol);
        vm.prank(carol);
        emergencyAdmin.zeroMaxDebtForStrategy(address(mainVault), address(riskyStrategy));

        assertEq(mainVault.strategies(address(riskyStrategy)).max_debt, 0, "max debt zeroed");
    }

    function test_onlyEmergencyOrGovernance() public {
        // Unprivileged caller is rejected on every entry point.
        vm.startPrank(bob);
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.pauseVault(address(mainVault));
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.shutdownVault(address(mainVault));
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.shutdownStrategy(address(aTranche));
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.emergencyWithdraw(address(aTranche), 1e18);
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.zeroMaxDebtForStrategy(address(mainVault), address(riskyStrategy));
        vm.stopPrank();

        // Governance (the Authorizer superuser) can act without holding the role.
        vm.prank(governance);
        emergencyAdmin.pauseVault(address(aTranche));
        assertTrue(ITrancheStrategy(address(aTranche)).isPaused());
    }
}
