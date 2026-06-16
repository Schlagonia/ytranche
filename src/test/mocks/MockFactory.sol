// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/// @notice Minimal stand-in for the Yearn `IFactory` the TokenizedStrategy
///         singleton calls into when a non-zero performance fee is charged.
///         Tests that enable the fee use this so protocol_fee_config() resolves.
contract MockFactory {
    uint16 public protocolFeeBps;
    address public protocolFeeRecipient;

    function setProtocolFee(uint16 bps, address recipient) external {
        protocolFeeBps = bps;
        protocolFeeRecipient = recipient;
    }

    function protocol_fee_config() external view returns (uint16, address) {
        return (protocolFeeBps, protocolFeeRecipient);
    }
}
