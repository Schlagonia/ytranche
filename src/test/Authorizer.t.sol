// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";

/// @notice Access-control matrix + two-step governance handoff on the generic
///   Authorizer that the Hook and Controller delegate to. The model is flat:
///   `isAuthorized(role, account)` is true only when the account holds `role`
///   directly OR holds GOVERNANCE_ROLE (the runtime superuser). Default admin
///   manages membership / role-admin plumbing. Roles do not imply one another —
///   management does NOT satisfy emergency/keeper.
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

        // Governance moved. Default admin did not. Separate keys, separate doors.
        assertEq(authorizer.defaultAdmin(), governance, "default admin stayed put");
        assertFalse(authorizer.hasRole(authorizer.MANAGEMENT_ROLE(), carol), "new governance is not management");

        // The new governor is still a runtime superuser, but cannot manage roles
        // unless it also holds DEFAULT_ADMIN_ROLE.
        bytes32 mgmtRole = authorizer.MANAGEMENT_ROLE();
        bytes32 keeperRole = authorizer.KEEPER_ROLE();
        vm.prank(carol);
        vm.expectRevert();
        authorizer.grantRole(mgmtRole, eve);

        // Default admin can grant a specific manager, who then administers
        // operational roles.
        vm.prank(governance);
        authorizer.grantRole(mgmtRole, eve);
        vm.prank(eve);
        authorizer.grantRole(keeperRole, bob);
        assertTrue(authorizer.hasRole(keeperRole, bob));
    }

    function test_twoStepDefaultAdminTransfer() public {
        bytes32 defaultAdminRole = authorizer.DEFAULT_ADMIN_ROLE();
        bytes32 pendingRole = authorizer.PENDING_DEFAULT_ADMIN_ROLE();
        bytes32 mgmtRole = authorizer.MANAGEMENT_ROLE();

        assertEq(authorizer.governance(), governance, "governance starts equal");
        assertEq(authorizer.defaultAdmin(), governance, "default admin starts equal");

        vm.prank(governance);
        authorizer.grantRole(pendingRole, carol);
        assertEq(authorizer.defaultAdmin(), governance, "old default admin still in control");
        assertEq(authorizer.pendingDefaultAdmin(), carol, "pending admin set");

        vm.prank(bob);
        vm.expectRevert();
        authorizer.grantRole(defaultAdminRole, bob);

        vm.prank(carol);
        authorizer.grantRole(defaultAdminRole, carol);
        assertEq(authorizer.defaultAdmin(), carol, "default admin transferred");
        assertEq(authorizer.pendingDefaultAdmin(), address(0), "pending admin cleared");
        assertEq(authorizer.governance(), governance, "governance did not move");

        vm.prank(governance);
        vm.expectRevert();
        authorizer.grantRole(mgmtRole, eve);

        vm.prank(carol);
        authorizer.grantRole(mgmtRole, eve);
        assertTrue(authorizer.hasRole(mgmtRole, eve), "new default admin grants roles");
    }

    function test_governanceCannotBeGrantedDirectlyOrRenounced() public {
        bytes32 govRole = authorizer.GOVERNANCE_ROLE();
        vm.startPrank(governance);
        // GOVERNANCE_ROLE's admin is PENDING_GOVERNANCE_ROLE — even the current
        // governor cannot grant it directly without going through the handoff.
        vm.expectRevert();
        authorizer.grantRole(govRole, carol);
        // Governance cannot renounce (would brick the system).
        vm.expectRevert(bytes("cannot renounce core role"));
        authorizer.renounceRole(govRole, governance);
        vm.stopPrank();
    }

    function test_defaultAdminCannotBeGrantedDirectlyOrRenounced() public {
        bytes32 defaultAdminRole = authorizer.DEFAULT_ADMIN_ROLE();
        vm.startPrank(governance);
        // DEFAULT_ADMIN_ROLE's admin is PENDING_DEFAULT_ADMIN_ROLE, so even the
        // current default admin must use the handoff.
        vm.expectRevert();
        authorizer.grantRole(defaultAdminRole, carol);
        vm.expectRevert(bytes("cannot renounce core role"));
        authorizer.renounceRole(defaultAdminRole, governance);
        vm.stopPrank();
    }

    function test_setRoleAdminIsDefaultAdminOnly() public {
        bytes32 defaultAdminRole = authorizer.DEFAULT_ADMIN_ROLE();
        bytes32 pendingAdminRole = authorizer.PENDING_DEFAULT_ADMIN_ROLE();
        bytes32 managementRole = authorizer.MANAGEMENT_ROLE();
        bytes32 customRole = keccak256("CUSTOM_ROLE");

        vm.prank(governance);
        authorizer.grantRole(pendingAdminRole, carol);
        vm.prank(carol);
        authorizer.grantRole(defaultAdminRole, carol);

        vm.prank(governance);
        vm.expectRevert(bytes("!default admin"));
        authorizer.setRoleAdmin(customRole, managementRole);

        vm.prank(carol);
        authorizer.setRoleAdmin(customRole, managementRole);
        assertEq(authorizer.getRoleAdmin(customRole), managementRole);

        vm.prank(carol);
        authorizer.grantRole(managementRole, eve);
        vm.prank(eve);
        authorizer.grantRole(customRole, bob);
        assertTrue(authorizer.hasRole(customRole, bob), "custom admin updated");
    }

    function test_setRoleAdminDoesNotRewriteCoreHandoffs() public {
        bytes32 defaultAdminRole = authorizer.DEFAULT_ADMIN_ROLE();
        bytes32 pendingDefaultAdminRole = authorizer.PENDING_DEFAULT_ADMIN_ROLE();
        bytes32 governanceRole = authorizer.GOVERNANCE_ROLE();
        bytes32 pendingGovernanceRole = authorizer.PENDING_GOVERNANCE_ROLE();

        vm.startPrank(governance);
        vm.expectRevert(bytes("locked admin role"));
        authorizer.setRoleAdmin(governanceRole, defaultAdminRole);
        vm.expectRevert(bytes("locked admin role"));
        authorizer.setRoleAdmin(pendingGovernanceRole, defaultAdminRole);
        vm.expectRevert(bytes("locked admin role"));
        authorizer.setRoleAdmin(defaultAdminRole, governanceRole);
        vm.expectRevert(bytes("locked admin role"));
        authorizer.setRoleAdmin(pendingDefaultAdminRole, governanceRole);
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
        // A role the Authorizer never declared is administered by default admin
        // and checks like any other — proving the generic surface.
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
