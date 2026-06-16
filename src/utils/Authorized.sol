// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IAuthorizer} from "../interfaces/IAuthorizer.sol";
import {Roles} from "./Roles.sol";

/**
 * @title Authorized
 * @author ytranche
 * @notice Base contract that delegates access control to a shared {Authorizer}.
 *         Inherits {Roles} so the default role ids are available to gate on.
 *         A function declares the `bytes32` role it requires:
 *           - `isAuthorized(role)` passes for the role holder OR governance.
 *           - `hasRole(role)`     passes only for the strict role holder.
 *         A contract may also declare and gate on its own role id (global or
 *         contract-scoped) beyond the inherited defaults.
 */
abstract contract Authorized is Roles {
    /// @notice Immutable access-control authority.
    IAuthorizer public immutable AUTHORIZER;

    constructor(address _authorizer) {
        require(_authorizer != address(0), "ZERO authorizer");
        AUTHORIZER = IAuthorizer(_authorizer);
    }

    /// @notice Restrict to holders of `role` (governance satisfies any role).
    modifier isAuthorized(bytes32 role) {
        require(AUTHORIZER.isAuthorized(role, msg.sender), "!authorized");
        _;
    }

    /// @notice Restrict to strict holders of `role` (no governance bypass).
    modifier hasRole(bytes32 role) {
        require(AUTHORIZER.hasRole(role, msg.sender), "!authorized");
        _;
    }
}
