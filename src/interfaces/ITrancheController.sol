// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title ITrancheController
 * @notice Controller surface used by the Tranche strategies. Tranches are
 *         keyed by address — the controller resolves which Tranche by
 *         looking `msg.sender` up in the per-Tranche mapping. There is no
 *         A/B/E specialised surface.
 */
interface ITrancheController {
    // Asset routing called from the Tranches' BaseStrategy hooks.
    function depositFromTranche(uint256 amount) external;
    function withdrawFromTranche(uint256 amount) external;

    // Settlement.
    function settle() external;

    // Called by a Tranche during `report()` to move its pending excess
    // into the baseline so the profit can be locked.
    function realizeExcess() external returns (uint256);

    // Views.
    function VAULT() external view returns (address);
    function reserveAssets() external view returns (uint256);
    function reserveDepositInProgress() external view returns (bool);
    function vaultAssets() external view returns (uint256);
    function vaultMaxWithdraw() external view returns (uint256);
    function backingAssets() external view returns (uint256);
    function trancheCoverage(address tranche) external view returns (uint256 claim, uint256 covered);
    function liveAssets(address tranche) external view returns (uint256);
    function pendingExcess(address tranche) external view returns (uint256);
    function isAccrualPaused(address tranche) external view returns (bool);
    function isTranche(address tranche) external view returns (bool);
    function getTranchesByPriority() external view returns (address[] memory);
}
