// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable test token. Defaults to 18 decimals; `setDecimals` lets a
///         test stand it up at e.g. 6 decimals (call before any mint / before it
///         is wired into a vault, since the vault reads decimals at init).
contract MockERC20 is ERC20 {
    uint8 private _customDecimals = 18;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    function setDecimals(uint8 decimals_) external {
        _customDecimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
