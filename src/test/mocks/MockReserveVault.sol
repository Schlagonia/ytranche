// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC4626Mock} from "@openzeppelin/contracts/mocks/ERC4626Mock.sol";

/// @notice Standard ERC4626 test reserve vault. NAV grows when tests mint
///         underlying directly to the vault.
contract MockReserveVault is ERC4626Mock {
    bool public revertWithdraw;

    constructor(address asset_) ERC4626Mock(asset_) {}

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        require(!revertWithdraw, "withdraw disabled");
        return super.withdraw(assets, receiver, owner);
    }

    function setRevertWithdraw(bool _revertWithdraw) external {
        revertWithdraw = _revertWithdraw;
    }

    /// @notice Simulate reserve yield in tests by minting `amount` underlying into this vault.
    function accrue(uint256) external pure {}
}
