// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title IAuthorizer
 * @notice Generic access-control surface delegated to by Authorized contracts.
 */
interface IAuthorizer {
    function isAuthorized(bytes32 role, address account) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external;
}
