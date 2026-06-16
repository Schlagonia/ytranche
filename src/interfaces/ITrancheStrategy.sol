// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";

/// @notice Base tranche strategy interface — used directly for the senior
/// (A) tranche and inherited by `ILockedTrancheStrategy` for B and E.
/// Extends {IBaseHealthCheck} so the per-tranche open / allow-list and the
/// report health-check limits are reachable.
interface ITrancheStrategy is IBaseHealthCheck {
    function hook() external view returns (address);
    function setHook(address) external;
}

/// @notice Cooldown-augmented tranche strategy interface — used for B and E.
interface ILockedTrancheStrategy is ITrancheStrategy {
    function MAX_COOLDOWN_DURATION() external view returns (uint256);
    function MIN_WITHDRAWAL_WINDOW() external view returns (uint256);

    function cooldownDuration() external view returns (uint256);
    function withdrawalWindow() external view returns (uint256);

    function setCooldownDuration(uint256) external;
    function setWithdrawalWindow(uint256) external;

    function startCooldown(uint256 shares) external;
    function cancelCooldown() external;

    function getCooldownStatus(address user)
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares);
}
