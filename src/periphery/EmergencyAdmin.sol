// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

import {Authorized} from "./Authorized.sol";

/**
 * @title EmergencyAdmin
 * @author ytranche
 * @notice Single, central entry point for every emergency halt in the Tranche
 *         system. A caller with the relevant role names the target to halt —
 *         the contract holds no addresses of its own, it just drives the underlying Yearn V3
 *         primitives:
 *           - {pauseVault}        — `setPaused(true)` on a vault OR a strategy
 *           - {shutdownVault}     — `shutdown_vault()` on the main vault
 *           - {shutdownStrategy}  — `shutdownStrategy()` on a strategy
 *           - {emergencyWithdraw} — `emergencyWithdraw()` on a strategy
 *           - {zeroMaxDebtForStrategy} — sets a vault strategy's max debt to 0
 *
 *  For these to land, this contract must hold the vault's `EMERGENCY_MANAGER`
 *  and `MAX_DEBT_MANAGER` roles and be set as each strategy's `emergencyAdmin`
 *  (`setEmergencyAdmin`).
 *
 *  Halt-only by design: there is no unpause here. A vault pause is reversible by
 *  an `EMERGENCY_MANAGER` holder; a strategy pause only by its own management.
 */
contract EmergencyAdmin is Authorized {
    constructor(address _authorizer) Authorized(_authorizer) {}

    /// @notice Pause a target — blocks its flows. Works for both the main vault
    ///         and any strategy (both expose `setPaused(bool)`). Reversible by
    ///         the target's own pause authority.
    function pauseVault(address _target) external isAuthorized(EMERGENCY_ROLE) {
        IVault(_target).setPaused(true);
    }

    /// @notice Shut the main vault down — blocks deposits, leaves withdrawals
    ///         open. Irreversible.
    function shutdownVault(address _vault) external isAuthorized(MANAGEMENT_ROLE) {
        IVault(_vault).shutdown_vault();
    }

    /// @notice Shut a strategy down — blocks deposits. Irreversible.
    function shutdownStrategy(address _strategy) external isAuthorized(MANAGEMENT_ROLE) {
        IStrategy(_strategy).shutdownStrategy();
    }

    /// @notice Pull funds out of a strategy's yield source into its idle balance.
    ///         Requires the strategy to be paused or shut down first.
    function emergencyWithdraw(address _strategy, uint256 _amount) external isAuthorized(EMERGENCY_ROLE) {
        IStrategy(_strategy).emergencyWithdraw(_amount);
    }

    /// @notice Set a vault strategy's max debt to zero.
    ///         Requires this contract to hold the vault's MAX_DEBT_MANAGER role.
    function zeroMaxDebtForStrategy(address _vault, address _strategy) external isAuthorized(EMERGENCY_ROLE) {
        IVault(_vault).update_max_debt_for_strategy(_strategy, 0);
    }
}
