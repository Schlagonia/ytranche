// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title ITrancheController
 * @notice Controller surface used by the tranche strategies. Tranches are
 *         keyed by address — the controller resolves which tranche by
 *         looking `msg.sender` up in the per-tranche mapping. There is no
 *         A/B/E specialised surface.
 */
interface ITrancheController {
    // Asset routing called from the tranches' BaseStrategy hooks.
    function depositFromTranche(uint256 amount) external;
    function withdrawFromTranche(uint256 amount) external;

    // Settlement.
    function settle() external;

    // Called by a tranche during `report()` to move its pending excess
    // into the baseline so the profit can be locked.
    function realizeExcess() external returns (uint256);

    // Views.
    function VAULT() external view returns (address);
    function reserveAssets() external view returns (uint256);
    function vaultAssets() external view returns (uint256);
    function vaultMaxWithdraw() external view returns (uint256);
    function liveAssets(address tranche) external view returns (uint256);
    function pendingExcess(address tranche) external view returns (uint256);
    function isFrozen(address tranche) external view returns (bool);
    function isTranche(address tranche) external view returns (bool);
    function isSolvent() external view returns (bool);
}
