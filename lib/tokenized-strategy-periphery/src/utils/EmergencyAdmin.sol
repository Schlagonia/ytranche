// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {Authorized} from "./Authorized.sol";

interface IEmergencyPausable {
    function setPaused(bool paused) external;
}

interface IEmergencyVault {
    function shutdown_vault() external;
    function update_max_debt_for_strategy(address strategy, uint256 newMaxDebt) external;
}

interface IEmergencyStrategy {
    function shutdownStrategy() external;
    function emergencyWithdraw(uint256 amount) external;
}

/**
 * @title EmergencyAdmin
 * @notice Central emergency pass-through for Yearn vault and strategy actions.
 */
contract EmergencyAdmin is Authorized {
    constructor(address _authorizer) Authorized(_authorizer) {}

    function pauseVault(address _target) external isAuthorized(EMERGENCY_ROLE) {
        IEmergencyPausable(_target).setPaused(true);
    }

    function shutdownVault(address _vault) external isAuthorized(EMERGENCY_ROLE) {
        IEmergencyVault(_vault).shutdown_vault();
    }

    function shutdownStrategy(address _strategy) external isAuthorized(EMERGENCY_ROLE) {
        IEmergencyStrategy(_strategy).shutdownStrategy();
    }

    function emergencyWithdraw(address _strategy, uint256 _amount) external isAuthorized(EMERGENCY_ROLE) {
        IEmergencyStrategy(_strategy).emergencyWithdraw(_amount);
    }

    function zeroMaxDebtForStrategy(address _vault, address _strategy) external isAuthorized(EMERGENCY_ROLE) {
        IEmergencyVault(_vault).update_max_debt_for_strategy(_strategy, 0);
    }
}
