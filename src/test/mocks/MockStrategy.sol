// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {TokenizedStrategyLib as TokenizedStrategy} from "@tokenized-strategy/libraries/TokenizedStrategyLib.sol";

/// @notice Trivial test-only Yearn strategy that just holds idle behind the
///         real Vyper Yearn V3 test vault. It receives simulated PnL airdrops
///         in tests. Production deployments use real strategies.
contract MockStrategy is BaseStrategy {
    uint256 public withdrawLimit = type(uint256).max;

    constructor(address _asset) BaseStrategy(_asset, "MockStrategy") {
        TokenizedStrategy.strategyStorage().performanceFee = 0;
    }

    function _deployFunds(uint256) internal override {}
    function _freeFunds(uint256) internal override {}

    function _strategyTotalAssets() internal view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function _harvestAndReport() internal view override returns (uint256) {
        return _strategyTotalAssets();
    }

    function availableWithdrawLimit(address) public view override returns (uint256) {
        return withdrawLimit;
    }

    function setWithdrawLimit(uint256 _withdrawLimit) external {
        withdrawLimit = _withdrawLimit;
    }
}
