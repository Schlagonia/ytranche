// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC4626Mock} from "@openzeppelin/contracts/mocks/ERC4626Mock.sol";

/// @notice Adversarial reserve vault whose `previewWithdraw` rounds shares UP so
///         aggressively that `previewWithdraw(maxWithdraw)` exceeds the holder's
///         share balance. Used to prove the controller's full-reserve drain clamps
///         to `maxRedeem` and does not revert (the M-3 scenario).
contract MockRoundUpReserveVault is ERC4626Mock {
    constructor(address asset_) ERC4626Mock(asset_) {}

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return super.previewWithdraw(assets) + 1;
    }
}
