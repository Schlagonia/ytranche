// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title Roles
 * @author ytranche
 * @notice The system's default role identifiers, declared once and shared by
 *         the {Authorizer} and every {Authorized} contract through inheritance
 *         (so neither side redeclares them). A contract may still add its own
 *         role — global (`keccak256("FOO_ROLE")`) or contract-scoped
 *         (`keccak256(abi.encodePacked(address(this), "FOO_ROLE"))`).
 */
abstract contract Roles {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
}
