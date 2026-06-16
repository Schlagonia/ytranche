// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";

/// @notice Access-control matrix + two-step governance handoff on the generic
///   Authorizer that the Hook and Controller delegate to. The model is flat:
///   `isAuthorized(role, account)` is true only when the account holds `role`
///   directly OR holds GOVERNANCE_ROLE (the sole superuser). Roles do not imply
///   one another — management does NOT satisfy emergency/keeper.
contract AuthorizerTest is Setup {
    function test_twoStepGovernanceTransfer() public {
        bytes32 govRole = authorizer.GOVERNANCE_ROLE();
        bytes32 pendingRole = authorizer.PENDING_GOVERNANCE_ROLE();

        // Step 1: current governance proposes a pending holder.
        vm.prank(governance);
        authorizer.grantRole(pendingRole, carol);
        assertEq(authorizer.governance(), governance, "old governance still in control");
        assertEq(authorizer.pendingGovernance(), carol, "pending set");

        // A stray caller cannot claim (GOVERNANCE_ROLE admin is the pending role).
        vm.prank(bob);
        vm.expectRevert();
        authorizer.grantRole(govRole, bob);

        // Step 2: the pending holder claims governance.
        vm.prank(carol);
        authorizer.grantRole(govRole, carol);
        assertEq(authorizer.governance(), carol, "governance transferred");
        assertEq(authorizer.pendingGovernance(), address(0), "pending cleared");
        assertTrue(authorizer.isAuthorized(govRole, carol));
        assertFalse(authorizer.isAuthorized(govRole, governance), "old governance demoted");

        // The new governor inherited default admin, but not management.
        assertFalse(authorizer.hasRole(authorizer.MANAGEMENT_ROLE(), carol), "new governance is not management");

        // Governance can grant a specific manager, who then administers operational roles.
        bytes32 mgmtRole = authorizer.MANAGEMENT_ROLE();
        bytes32 keeperRole = authorizer.KEEPER_ROLE();
        vm.prank(carol);
        authorizer.grantRole(mgmtRole, eve);
        vm.prank(eve);
        authorizer.grantRole(keeperRole, bob);
        assertTrue(authorizer.hasRole(keeperRole, bob));
    }

    function test_governanceCannotBeGrantedDirectlyOrRenounced() public {
        bytes32 govRole = authorizer.GOVERNANCE_ROLE();
        vm.startPrank(governance);
        // GOVERNANCE_ROLE's admin is PENDING_GOVERNANCE_ROLE — even the current
        // governor cannot grant it directly without going through the handoff.
        vm.expectRevert();
        authorizer.grantRole(govRole, carol);
        // Governance cannot renounce (would brick the system).
        vm.expectRevert(bytes("cannot renounce governance"));
        authorizer.renounceRole(govRole, governance);
        vm.stopPrank();
    }

    function test_governanceIsTheOnlySuperuser() public {
        // Governance satisfies every role check without holding them directly.
        assertFalse(authorizer.hasRole(authorizer.MANAGEMENT_ROLE(), governance), "governance is not management");
        assertTrue(authorizer.hasRole(authorizer.MANAGEMENT_ROLE(), management), "specific management set");
        assertTrue(authorizer.isAuthorized(authorizer.MANAGEMENT_ROLE(), governance));
        assertTrue(authorizer.isAuthorized(emergencyAdmin.EMERGENCY_ROLE(), governance));
        assertTrue(authorizer.isAuthorized(authorizer.KEEPER_ROLE(), governance));

        // Governance can call across every scope.
        vm.startPrank(governance);
        hook.setRateLimitWindow(2 hours); // management
        controller.settle(); // keeper
        controller.setTrancheTargetBps(address(aTranche), 500); // governance
        emergencyAdmin.pauseVault(address(mainVault)); // emergency (last — halts the vault)
        vm.stopPrank();
    }

    function test_managementIsScopedAndDoesNotEscalate() public {
        bytes32 role = authorizer.MANAGEMENT_ROLE();
        vm.prank(governance);
        authorizer.grantRole(role, carol);

        vm.startPrank(carol);
        // Management-scoped config works.
        hook.setRateLimitWindow(2 hours);
        // But management no longer implies emergency, keeper, or governance.
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.pauseVault(address(mainVault)); // emergency
        vm.expectRevert(bytes("!authorized"));
        controller.settle(); // keeper
        vm.expectRevert(bytes("!authorized"));
        controller.setTrancheTargetBps(address(aTranche), 500); // governance
        vm.stopPrank();
    }

    function test_emergencyIsScopedToBreakers() public {
        bytes32 role = emergencyAdmin.EMERGENCY_ROLE();
        vm.prank(management);
        authorizer.grantRole(role, bob);

        vm.startPrank(bob);
        emergencyAdmin.pauseVault(address(mainVault)); // ok — emergency can halt the vault
        vm.expectRevert(bytes("!authorized"));
        hook.setRateLimitWindow(2 hours); // but cannot touch management config
        vm.stopPrank();
    }

    function test_keeperIsScopedToSettlement() public {
        bytes32 role = authorizer.KEEPER_ROLE();
        vm.prank(management);
        authorizer.grantRole(role, eve);

        vm.prank(eve);
        controller.settle(); // ok

        vm.prank(eve);
        vm.expectRevert(bytes("!authorized")); // keeper does not imply emergency
        emergencyAdmin.pauseVault(address(mainVault));
    }

    function test_managementAdminsKeeperAndEmergency() public {
        bytes32 mgmt = authorizer.MANAGEMENT_ROLE();
        bytes32 keeperRole = authorizer.KEEPER_ROLE();
        bytes32 emergencyRole = emergencyAdmin.EMERGENCY_ROLE();

        // Governance makes carol a manager.
        vm.prank(governance);
        authorizer.grantRole(mgmt, carol);

        // Manager can now grant/revoke keeper and emergency without governance.
        vm.startPrank(carol);
        authorizer.grantRole(keeperRole, eve);
        authorizer.grantRole(emergencyRole, bob);
        vm.stopPrank();
        assertTrue(authorizer.hasRole(keeperRole, eve), "manager granted keeper");
        assertTrue(authorizer.hasRole(emergencyRole, bob), "manager granted emergency");

        vm.prank(carol);
        authorizer.revokeRole(keeperRole, eve);
        assertFalse(authorizer.hasRole(keeperRole, eve), "manager revoked keeper");

        // A non-manager cannot administer those roles.
        vm.prank(eve);
        vm.expectRevert();
        authorizer.grantRole(keeperRole, eve);
    }

    function test_customRoleWorksWithoutAuthorizerEdit() public {
        // A role the Authorizer never declared is administered by governance and
        // checks like any other — proving the generic surface.
        bytes32 customRole = keccak256("CUSTOM_ROLE");

        assertFalse(authorizer.isAuthorized(customRole, carol));

        vm.prank(governance);
        authorizer.grantRole(customRole, carol);

        assertTrue(authorizer.isAuthorized(customRole, carol), "holder authorized");
        assertTrue(authorizer.isAuthorized(customRole, governance), "governance superuser");
        assertFalse(authorizer.isAuthorized(customRole, bob), "non-holder rejected");
    }

    function test_unprivilegedCallerRejectedEverywhere() public {
        vm.startPrank(bob);
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.pauseVault(address(mainVault));
        vm.expectRevert(bytes("!authorized"));
        hook.setRateLimitWindow(2 hours);
        vm.expectRevert(bytes("!authorized"));
        controller.settle();
        vm.expectRevert(bytes("!authorized"));
        controller.setTrancheTargetBps(address(aTranche), 500);
        vm.stopPrank();
    }
}
