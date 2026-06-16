// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {IAuthorizer} from "../interfaces/utils/IAuthorizer.sol";
import {Roles} from "./Roles.sol";

/**
 * @title Authorized
 * @notice Base contract that delegates role checks to a shared Authorizer.
 */
abstract contract Authorized is Roles {
    IAuthorizer public immutable AUTHORIZER;

    constructor(address _authorizer) {
        require(_authorizer != address(0), "ZERO authorizer");
        AUTHORIZER = IAuthorizer(_authorizer);
    }

    modifier isAuthorized(bytes32 role) {
        require(AUTHORIZER.isAuthorized(role, msg.sender), "!authorized");
        _;
    }

    modifier hasRole(bytes32 role) {
        require(AUTHORIZER.hasRole(role, msg.sender), "!authorized");
        _;
    }
}
