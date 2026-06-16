// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title IHook
 * @notice Central security/policy contract used by the tranches and wired
 *         directly as the Yearn V3 main-vault `deposit_hook` /
 *         `withdraw_hook`. Per-tranche state is keyed by the
 *         tranche's address — there is no A/B/E specialised surface.
 *         Returns *actual* asset caps through `depositCap` / `withdrawCap`
 *         so the strategies can `min` them with their own constraints.
 */
interface IHook {
    /*//////////////////////////////////////////////////////////////
                      CAPS FOR TRANCHE STRATEGIES
    //////////////////////////////////////////////////////////////*/

    function depositCap(address tranche) external view returns (uint256);
    function withdrawCap(address tranche) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                    SHARED DEPOSIT / WITHDRAW HOOK SURFACE
    //////////////////////////////////////////////////////////////*/

    function available_deposit_limit(address receiver) external view returns (uint256);
    function available_withdraw_limit(address owner, uint256 maxLoss, address[] calldata strategies)
        external
        view
        returns (uint256);
    function post_deposit(address sender, address receiver, uint256 assets, uint256 shares) external;
    function post_withdraw(address sender, address receiver, address owner, uint256 assets, uint256 shares) external;
}
