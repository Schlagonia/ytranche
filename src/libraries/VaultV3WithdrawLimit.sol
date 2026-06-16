// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

/**
 * @title VaultV3WithdrawLimit
 * @notice Mirrors the queue path of Yearn VaultV3's internal
 *         `_max_withdraw` logic.
 * @dev The vault resolves the withdrawal queue before calling the hook.
 *      Direct hook calls may still pass an empty queue, so those fall back
 *      to the vault's default queue.
 */
library VaultV3WithdrawLimit {
    uint256 internal constant MAX_BPS = 10_000;

    function maxWithdraw(IVault _vault, address _owner, uint256 _maxLoss, address[] memory _strategies)
        internal
        view
        returns (uint256)
    {
        uint256 maxAssets = _vault.convertToAssets(_vault.balanceOf(_owner));
        uint256 currentIdle = _vault.totalIdle();

        if (maxAssets <= currentIdle) return maxAssets;

        uint256 have = currentIdle;
        uint256 loss = 0;

        address[] memory queue = _strategies.length == 0 ? _vault.get_default_queue() : _strategies;
        return _maxWithdrawFromQueue(_vault, queue, maxAssets, have, loss, _maxLoss);
    }

    function _maxWithdrawFromQueue(
        IVault _vault,
        address[] memory _queue,
        uint256 _maxAssets,
        uint256 _have,
        uint256 _loss,
        uint256 _maxLoss
    ) private view returns (uint256) {
        for (uint256 i; i < _queue.length; ++i) {
            address strategy = _queue[i];
            IVault.StrategyParams memory params = _vault.strategies(strategy);
            require(params.activation != 0, "inactive strategy");

            uint256 currentDebt = params.current_debt;
            uint256 toWithdraw = _min(_maxAssets - _have, currentDebt);
            uint256 unrealisedLoss = _assessShareOfUnrealisedLosses(_vault, strategy, currentDebt, toWithdraw);
            (toWithdraw, unrealisedLoss) = _applyStrategyLimit(_vault, strategy, toWithdraw, unrealisedLoss);

            if (toWithdraw == 0) continue;

            if (unrealisedLoss > 0 && _maxLoss < MAX_BPS) {
                if (_loss + unrealisedLoss > ((_have + toWithdraw) * _maxLoss) / MAX_BPS) {
                    break;
                }
            }

            _have += toWithdraw;
            if (_have >= _maxAssets) break;

            _loss += unrealisedLoss;
        }

        return _have;
    }

    function _applyStrategyLimit(IVault _vault, address _strategy, uint256 _toWithdraw, uint256 _unrealisedLoss)
        private
        view
        returns (uint256, uint256)
    {
        uint256 realizableWithdraw = _toWithdraw - _unrealisedLoss;
        uint256 strategyLimit = IStrategy(_strategy).convertToAssets(IStrategy(_strategy).maxRedeem(address(_vault)));

        if (strategyLimit >= realizableWithdraw) {
            return (_toWithdraw, _unrealisedLoss);
        }

        if (_unrealisedLoss != 0) {
            _unrealisedLoss = (_unrealisedLoss * strategyLimit) / realizableWithdraw;
        }

        return (strategyLimit + _unrealisedLoss, _unrealisedLoss);
    }

    function _assessShareOfUnrealisedLosses(
        IVault _vault,
        address _strategy,
        uint256 _strategyCurrentDebt,
        uint256 _assetsNeeded
    ) private view returns (uint256) {
        uint256 vaultShares = IStrategy(_strategy).balanceOf(address(_vault));
        uint256 strategyAssets = IStrategy(_strategy).convertToAssets(vaultShares);

        if (strategyAssets >= _strategyCurrentDebt || _strategyCurrentDebt == 0) return 0;

        uint256 numerator = _assetsNeeded * strategyAssets;
        uint256 usersShareOfLoss = _assetsNeeded - (numerator / _strategyCurrentDebt);
        // Mirror VaultV3: only round up when there is a remainder AND the share
        // is still below assetsNeeded, otherwise the loss could exceed the amount
        // requested and underflow `_applyStrategyLimit`'s realizableWithdraw.
        if (numerator % _strategyCurrentDebt != 0 && usersShareOfLoss < _assetsNeeded) {
            usersShareOfLoss += 1;
        }

        return usersShareOfLoss;
    }

    function _min(uint256 _a, uint256 _b) private pure returns (uint256) {
        return _a < _b ? _a : _b;
    }
}
