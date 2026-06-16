// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

import {IAuthorizer} from "./interfaces/IAuthorizer.sol";
import {Roles} from "./utils/Roles.sol";

/**
 * @title Authorizer
 * @author ytranche
 * @notice Single, generic source of access control for the tranche system.
 *
 *  `GOVERNANCE_ROLE` is the superuser: by default it satisfies anything checked
 *  through {isAuthorized}. To require a role strictly (no governance bypass),
 *  use {hasRole} with the role id instead.
 *
 *  A few standard roles are declared below. Any contract may declare its own
 *  role — global (`keccak256("FOO_ROLE")`) or contract-scoped
 *  (`keccak256(abi.encodePacked(address(this), "FOO_ROLE"))`) — grant it through
 *  governance, and gate on it by inheriting {Authorized}. Governance is the
 *  default admin of every role (standard or custom), so no edit here is needed.
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
 *  Governance is single-holder and moves via a two-step handoff expressed with
 *  the native role-admin chain: the current governor grants
 *  `PENDING_GOVERNANCE_ROLE` to the proposed holder, who then grants themselves
 *  `GOVERNANCE_ROLE` (its admin is the pending role). The {grantRole} override
 *  finalizes the swap — clearing the pending role and moving GOVERNANCE_ROLE +
 *  the default admin off the prior governor.
 */
contract Authorizer is Roles, IAuthorizer, AccessControlEnumerable {
    bytes32 public constant PENDING_GOVERNANCE_ROLE = keccak256("PENDING_GOVERNANCE_ROLE");

    constructor(address _governance, address _management) {
        require(_governance != address(0), "ZERO governance");
        require(_management != address(0), "ZERO management");

        // Governance is the superuser and the default admin of every role a
        // downstream contract invents. Management is separate and administers
        // the management-scoped operational roles below.
        _grantRole(DEFAULT_ADMIN_ROLE, _governance);
        _grantRole(GOVERNANCE_ROLE, _governance);
        _grantRole(MANAGEMENT_ROLE, _management);

        // Two-step handoff: governance proposes a pending holder, who then
        // claims GOVERNANCE_ROLE (finalized in the {grantRole} override).
        _setRoleAdmin(PENDING_GOVERNANCE_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(GOVERNANCE_ROLE, PENDING_GOVERNANCE_ROLE);

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

    /// @dev Finalize the two-step governance handoff. Only the pending holder
    ///      can grant GOVERNANCE_ROLE (PENDING_GOVERNANCE_ROLE admins it); doing
    ///      so clears the pending role and moves GOVERNANCE_ROLE + the default
    ///      admin off the prior governor, keeping a single governor.
    function grantRole(bytes32 role, address account) public override(AccessControl, IAccessControl) {
        super.grantRole(role, account);
        if (role == GOVERNANCE_ROLE) {
            address previous = getRoleMember(GOVERNANCE_ROLE, 0);
            _revokeRole(PENDING_GOVERNANCE_ROLE, account);
            _revokeRole(GOVERNANCE_ROLE, previous);
            _grantRole(DEFAULT_ADMIN_ROLE, account);
            _revokeRole(DEFAULT_ADMIN_ROLE, previous);
        }
    }

    /// @dev Governance / default admin cannot be renounced — they only move via
    ///      the two-step handoff, so the system can never be left ungoverned.
    function renounceRole(bytes32 role, address account) public override(AccessControl, IAccessControl) {
        require(role != GOVERNANCE_ROLE && role != DEFAULT_ADMIN_ROLE, "cannot renounce governance");
        super.renounceRole(role, account);
    }

    /// @notice Current governance holder (the single GOVERNANCE_ROLE member).
    function governance() external view returns (address) {
        return getRoleMember(GOVERNANCE_ROLE, 0);
    }

    /// @notice Address proposed to take over governance (PENDING_GOVERNANCE_ROLE).
    function pendingGovernance() external view returns (address) {
        return getRoleMemberCount(PENDING_GOVERNANCE_ROLE) == 0 ? address(0) : getRoleMember(PENDING_GOVERNANCE_ROLE, 0);
    }
}
