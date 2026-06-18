// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Authorized} from "./Authorized.sol";
import {ITrancheController} from "../interfaces/ITrancheController.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

/// @notice Batch keeper helper for settlement plus per-Tranche reports.
contract Keeper is Authorized {
    event SettledAndReported(address indexed caller, uint256 trancheCount);

    ITrancheController public immutable CONTROLLER;

    constructor(address _authorizer, address _controller) Authorized(_authorizer) {
        require(_controller != address(0), "ZERO controller");
        CONTROLLER = ITrancheController(_controller);
    }

    function settleAndReport() external isAuthorized(KEEPER_ROLE) {
        CONTROLLER.settle();

        address[] memory tranches = CONTROLLER.getTranchesByPriority();
        uint256 trancheCount = tranches.length;
        for (uint256 i = 0; i < trancheCount; ++i) {
            ITrancheStrategy(tranches[i]).report();
        }

        emit SettledAndReported(msg.sender, trancheCount);
    }
}
