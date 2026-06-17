// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

import {IAuthorizer} from "./interfaces/IAuthorizer.sol";
import {Roles} from "./Roles.sol";

/**
 * @title Authorizer
 * @author ytranche
 * @notice Single, generic source of access control for the Tranche system.
 *
 *  `GOVERNANCE_ROLE` is the superuser: by default it satisfies anything checked
 *  through {isAuthorized}. To require a role strictly (no governance bypass),
 *  use {hasRole} with the role id instead.
 *
 *  A few standard roles are declared below. Any contract may declare its own
 *  role — global (`keccak256("FOO_ROLE")`) or contract-scoped
 *  (`keccak256(abi.encodePacked(address(this), "FOO_ROLE"))`) — grant it through
 *  the default admin, and gate on it by inheriting {Authorized}. Governance and
 *  default admin start as the same address, then can diverge.
 *
 *  Role-admin chain: MANAGEMENT_ROLE administers KEEPER_ROLE and EMERGENCY_ROLE
 *  (keeper / emergency membership can be delegated to a manager). Governance
 *  does not hold MANAGEMENT_ROLE by default; it only satisfies management-gated
 *  runtime checks through {isAuthorized}.
 *
 *  ex:
 *      contract MyContract is Authorized {
 *          bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
 *          bytes32 public constant THIS_MANAGER_ROLE =
 *              keccak256(abi.encodePacked(address(this), "MANAGER_ROLE"));
 *
 *          function a() external isAuthorized(MANAGER_ROLE) {}      // role or governance
 *          function b() external hasRole(THIS_MANAGER_ROLE) {}      // role strictly
 *      }
 *
 *  Governance and default admin are each single-holder and move via separate
 *  two-step handoffs expressed with the native role-admin chain. The {grantRole}
 *  override finalizes each swap by clearing the matching pending role and
 *  revoking the prior holder. Role renouncing is disabled.
 */
contract Authorizer is Roles, IAuthorizer, AccessControlEnumerable {
    bytes32 public constant PENDING_GOVERNANCE_ROLE = keccak256("PENDING_GOVERNANCE_ROLE");
    bytes32 public constant PENDING_DEFAULT_ADMIN_ROLE = keccak256("PENDING_DEFAULT_ADMIN_ROLE");

    constructor(address _governance, address _management) {
        require(_governance != address(0), "ZERO governance");
        require(_management != address(0), "ZERO management");

        // Governance is the runtime superuser. The default admin controls role
        // membership / role-admin plumbing. They begin equal, then may diverge.
        _grantRole(DEFAULT_ADMIN_ROLE, _governance);
        _grantRole(GOVERNANCE_ROLE, _governance);
        _grantRole(MANAGEMENT_ROLE, _management);

        // Two-step handoffs: current holder proposes a pending holder, who then
        // claims the live role (finalized in the {grantRole} override).
        _setRoleAdmin(PENDING_GOVERNANCE_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(GOVERNANCE_ROLE, PENDING_GOVERNANCE_ROLE);
        _setRoleAdmin(PENDING_DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(DEFAULT_ADMIN_ROLE, PENDING_DEFAULT_ADMIN_ROLE);

        // Management administers keeper / emergency, so their membership can be
        // delegated to managers without bothering governance.
        _setRoleAdmin(KEEPER_ROLE, MANAGEMENT_ROLE);
        _setRoleAdmin(EMERGENCY_ROLE, MANAGEMENT_ROLE);
    }

    /// @notice True if `account` holds `role`, or is governance (the superuser).
    function isAuthorized(bytes32 role, address account) public view returns (bool) {
        return hasRole(role, account) || hasRole(GOVERNANCE_ROLE, account);
    }

    /// @dev Resolve the `hasRole` declared by both {AccessControl} and the
    ///      {IAuthorizer} surface to a single implementation.
    function hasRole(bytes32 role, address account)
        public
        view
        override(AccessControl, IAccessControl, IAuthorizer)
        returns (bool)
    {
        return super.hasRole(role, account);
    }

    /// @dev Finalize the two-step governance / default-admin handoffs. Only the
    ///      pending holder can claim the live role; doing so clears the pending
    ///      role and revokes the prior live holder.
    function grantRole(bytes32 role, address account) public override(AccessControl, IAccessControl) {
        super.grantRole(role, account);
        if (role == GOVERNANCE_ROLE) {
            address previous = getRoleMember(GOVERNANCE_ROLE, 0);
            _revokeRole(PENDING_GOVERNANCE_ROLE, account);
            _revokeRole(GOVERNANCE_ROLE, previous);
        } else if (role == DEFAULT_ADMIN_ROLE) {
            address previous = getRoleMember(DEFAULT_ADMIN_ROLE, 0);
            _revokeRole(PENDING_DEFAULT_ADMIN_ROLE, account);
            _revokeRole(DEFAULT_ADMIN_ROLE, previous);
        }
    }

    /// @notice Update the admin role for a non-core role.
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "!default admin");
        require(
            role != DEFAULT_ADMIN_ROLE && role != PENDING_DEFAULT_ADMIN_ROLE && role != GOVERNANCE_ROLE
                && role != PENDING_GOVERNANCE_ROLE,
            "locked admin role"
        );
        _setRoleAdmin(role, adminRole);
    }

    /// @dev Role renouncing is disabled. Role removal must go through the
    ///      relevant role admin via {revokeRole}.
    function renounceRole(bytes32, address) public pure override(AccessControl, IAccessControl) {
        revert("renounce disabled");
    }

    /// @notice Current governance holder (the single GOVERNANCE_ROLE member).
    function governance() external view returns (address) {
        return getRoleMember(GOVERNANCE_ROLE, 0);
    }

    /// @notice Current default admin holder (the single DEFAULT_ADMIN_ROLE member).
    function defaultAdmin() external view returns (address) {
        return getRoleMember(DEFAULT_ADMIN_ROLE, 0);
    }

    /// @notice Address proposed to take over governance (PENDING_GOVERNANCE_ROLE).
    function pendingGovernance() external view returns (address) {
        return getRoleMemberCount(PENDING_GOVERNANCE_ROLE) == 0 ? address(0) : getRoleMember(PENDING_GOVERNANCE_ROLE, 0);
    }

    /// @notice Address proposed to take over default admin (PENDING_DEFAULT_ADMIN_ROLE).
    function pendingDefaultAdmin() external view returns (address) {
        return
            getRoleMemberCount(PENDING_DEFAULT_ADMIN_ROLE) == 0
                ? address(0)
                : getRoleMember(PENDING_DEFAULT_ADMIN_ROLE, 0);
    }
}
