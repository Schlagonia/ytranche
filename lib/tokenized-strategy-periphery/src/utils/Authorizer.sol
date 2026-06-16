// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

import {IAuthorizer} from "../interfaces/utils/IAuthorizer.sol";
import {Roles} from "./Roles.sol";

/**
 * @title Authorizer
 * @notice Shared AccessControl authority with governance as superuser.
 */
contract Authorizer is Roles, IAuthorizer, AccessControlEnumerable {
    bytes32 public constant PENDING_GOVERNANCE_ROLE = keccak256("PENDING_GOVERNANCE_ROLE");
    bytes32 public constant PENDING_DEFAULT_ADMIN_ROLE = keccak256("PENDING_DEFAULT_ADMIN_ROLE");

    constructor(address _governance, address _management) {
        require(_governance != address(0), "ZERO governance");
        require(_management != address(0), "ZERO management");

        _grantRole(DEFAULT_ADMIN_ROLE, _governance);
        _grantRole(GOVERNANCE_ROLE, _governance);
        _grantRole(MANAGEMENT_ROLE, _management);

        _setRoleAdmin(PENDING_GOVERNANCE_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(GOVERNANCE_ROLE, PENDING_GOVERNANCE_ROLE);
        _setRoleAdmin(PENDING_DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(DEFAULT_ADMIN_ROLE, PENDING_DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(KEEPER_ROLE, MANAGEMENT_ROLE);
        _setRoleAdmin(EMERGENCY_ROLE, MANAGEMENT_ROLE);
    }

    function isAuthorized(bytes32 role, address account) public view returns (bool) {
        return hasRole(role, account) || hasRole(GOVERNANCE_ROLE, account);
    }

    function hasRole(bytes32 role, address account)
        public
        view
        override(AccessControl, IAccessControl, IAuthorizer)
        returns (bool)
    {
        return super.hasRole(role, account);
    }

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

    function setRoleAdmin(bytes32 role, bytes32 adminRole) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "!default admin");
        require(
            role != DEFAULT_ADMIN_ROLE && role != PENDING_DEFAULT_ADMIN_ROLE && role != GOVERNANCE_ROLE
                && role != PENDING_GOVERNANCE_ROLE,
            "locked admin role"
        );
        _setRoleAdmin(role, adminRole);
    }

    function renounceRole(bytes32 role, address account) public override(AccessControl, IAccessControl) {
        require(role != GOVERNANCE_ROLE && role != DEFAULT_ADMIN_ROLE, "cannot renounce core role");
        super.renounceRole(role, account);
    }

    function governance() external view returns (address) {
        return getRoleMember(GOVERNANCE_ROLE, 0);
    }

    function defaultAdmin() external view returns (address) {
        return getRoleMember(DEFAULT_ADMIN_ROLE, 0);
    }

    function pendingGovernance() external view returns (address) {
        return getRoleMemberCount(PENDING_GOVERNANCE_ROLE) == 0 ? address(0) : getRoleMember(PENDING_GOVERNANCE_ROLE, 0);
    }

    function pendingDefaultAdmin() external view returns (address) {
        return getRoleMemberCount(PENDING_DEFAULT_ADMIN_ROLE) == 0
            ? address(0)
            : getRoleMember(PENDING_DEFAULT_ADMIN_ROLE, 0);
    }
}
