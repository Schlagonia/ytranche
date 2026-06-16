// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/// @notice Same-asset, low-risk, synchronously redeemable 4626-style vault. The protocol
/// reserve may optionally park idle assets here. Async / delayed redemption is not allowed.
interface IReserveVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}
