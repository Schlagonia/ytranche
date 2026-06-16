// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title IAuthorizer
 * @notice Generic access-control surface the {Authorized} base delegates to.
 *         `isAuthorized` answers "does `account` hold `role`, or governance?"
 *         (the superuser bypass); `hasRole` is the strict check with no bypass.
 */
interface IAuthorizer {
    function isAuthorized(bytes32 role, address account) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external;
}
