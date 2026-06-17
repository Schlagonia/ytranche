// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

/**
 * @title VaultV3WithdrawLimit
 * @notice Mirrors the queue path of Yearn VaultV3's internal
 *         `_max_withdraw` logic.
 * @dev The vault resolves the withdrawal queue before calling the hook, so the
 *      passed `_strategies` array is already the queue VaultV3 will use.
 */
library VaultV3WithdrawLimit {
    uint256 internal constant MAX_BPS = 10_000;

    function maxWithdraw(IVault _vault, address _owner, uint256 _maxLoss, address[] memory _strategies)
        internal
        view
        returns (uint256)
    {
        if (_vault.isPaused()) return 0;

        uint256 maxAssets = _vault.convertToAssets(_vault.balanceOf(_owner));
        uint256 have = _vault.totalIdle();
        if (maxAssets <= have) return maxAssets;

        uint256 loss = 0;

        for (uint256 i; i < _strategies.length; ++i) {
            address strategy = _strategies[i];

            uint256 currentDebt;
            {
                IVault.StrategyParams memory params = _vault.strategies(strategy);
                require(params.activation != 0, "inactive strategy");
                currentDebt = params.current_debt;
            }

            uint256 toWithdraw = _min(maxAssets - have, currentDebt);
            uint256 unrealisedLoss = _assessShareOfUnrealisedLosses(_vault, strategy, currentDebt, toWithdraw);

            {
                uint256 strategyLimit = _strategyWithdrawLimit(_vault, strategy);
                uint256 realizableWithdraw = toWithdraw - unrealisedLoss;

                if (strategyLimit < realizableWithdraw) {
                    if (unrealisedLoss != 0) {
                        unrealisedLoss = (unrealisedLoss * strategyLimit) / realizableWithdraw;
                    }

                    toWithdraw = strategyLimit + unrealisedLoss;
                }
            }

            if (toWithdraw == 0) continue;

            if (unrealisedLoss > 0 && _maxLoss < MAX_BPS) {
                if (loss + unrealisedLoss > ((have + toWithdraw) * _maxLoss) / MAX_BPS) {
                    break;
                }
            }

            have += toWithdraw;
            if (have >= maxAssets) break;

            loss += unrealisedLoss;
        }

        return have;
    }

    function _strategyWithdrawLimit(IVault _vault, address _strategy) private view returns (uint256) {
        return IStrategy(_strategy).convertToAssets(IStrategy(_strategy).maxRedeem(address(_vault)));
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
        // is still below assetsNeeded, otherwise the loss could exceed the
        // requested amount and underflow `toWithdraw - unrealisedLoss`.
        if (numerator % _strategyCurrentDebt != 0 && usersShareOfLoss < _assetsNeeded) {
            usersShareOfLoss += 1;
        }

        return usersShareOfLoss;
    }

    function _min(uint256 _a, uint256 _b) private pure returns (uint256) {
        return _a < _b ? _a : _b;
    }
}
