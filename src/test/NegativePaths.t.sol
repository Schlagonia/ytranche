// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";
import {EmergencyAdmin} from "../periphery/EmergencyAdmin.sol";
import {ILockedTrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

/// @notice §5.3 — revert-path coverage for require-statements that were
///         previously unverified.
contract NegativePathsTest is Setup {
    function test_registerTranche_doubleRegisterReverts() public {
        vm.prank(governance);
        vm.expectRevert(bytes("already registered"));
        controller.registerTranche(address(aTranche), 100, 0);
    }

    function test_registerTranche_zeroAddressReverts() public {
        vm.prank(governance);
        vm.expectRevert(bytes("ZERO tranche"));
        controller.registerTranche(address(0), 100, 0);
    }

    function test_registerTranche_excessOverMaxReverts() public {
        // A/B/E already sum to MAX_BPS, so any nonzero excess on a new tranche fails.
        address fresh = address(0xDEAD);
        vm.prank(governance);
        vm.expectRevert(bytes("excess > MAX_BPS"));
        controller.registerTranche(fresh, 0, 1);
    }

    function test_setRateLimitWindow_zeroReverts() public {
        vm.prank(management);
        vm.expectRevert(bytes("zero window"));
        hook.setRateLimitWindow(0);
    }

    function test_setCooldownDuration_tooLongReverts() public {
        // This test contract is the locked tranche's strategy-management.
        vm.expectRevert(bytes("cooldown too long"));
        ILockedTrancheStrategy(address(bTranche)).setCooldownDuration(31 days);
    }

    function test_setWithdrawalWindow_tooShortReverts() public {
        vm.expectRevert(bytes("window too short"));
        ILockedTrancheStrategy(address(bTranche)).setWithdrawalWindow(1 days - 1);
    }

    /// The sole governance holder cannot be revoked by an arbitrary caller (the
    /// role admin is PENDING_GOVERNANCE_ROLE, which nobody holds by default), so
    /// governance cannot be trivially bricked via revoke.
    function test_revokeSoleGovernance_revertsForNonAdmin() public {
        bytes32 govRole = authorizer.GOVERNANCE_ROLE();
        vm.prank(alice);
        vm.expectRevert();
        authorizer.revokeRole(govRole, governance);
        assertEq(authorizer.getRoleMemberCount(govRole), 1, "governance still single");
    }

    /// An EmergencyAdmin that was never granted the vault's EMERGENCY_MANAGER role
    /// cannot pause it, even when the caller holds EMERGENCY_ROLE.
    function test_emergencyAdmin_withoutVaultRoleReverts() public {
        EmergencyAdmin rogue = new EmergencyAdmin(address(authorizer));
        bytes32 emRole = authorizer.EMERGENCY_ROLE();
        vm.prank(management);
        authorizer.grantRole(emRole, alice);

        vm.prank(alice);
        vm.expectRevert();
        rogue.pauseVault(address(mainVault));
    }
}
