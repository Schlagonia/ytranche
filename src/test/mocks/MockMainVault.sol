// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/ERC4626Mock.sol";

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";

/// @notice Fast local stand-in for the Yearn V3 main vault used only by the
///         invariant suite. It reports strategy PnL only when process_report is
///         called, so the handler can model processed vs unsettled strategy NAV.
contract MockMainVault is ERC4626Mock {
    using SafeERC20 for IERC20;

    IERC20 internal immutable UNDERLYING;

    address public role_manager;
    address public deposit_hook;
    address public withdraw_hook;
    bool public auto_allocate;
    uint256 public deposit_limit = type(uint256).max;
    uint256 public minimum_total_idle;
    uint256 public profitMaxUnlockTime;

    mapping(address => uint256) public roles;
    mapping(address => IVault.StrategyParams) public strategies;
    mapping(address => uint256) public reportedAssets;

    address[] internal queue;
    address[] internal strategyList;

    constructor(address asset_) ERC4626Mock(asset_) {
        UNDERLYING = IERC20(asset_);
        role_manager = msg.sender;
    }

    function totalAssets() public view override returns (uint256 assets) {
        assets = UNDERLYING.balanceOf(address(this));
        for (uint256 i; i < strategyList.length; ++i) {
            assets += reportedAssets[strategyList[i]];
        }
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        receiver;
        uint256 assets = totalAssets();
        return assets >= deposit_limit ? 0 : deposit_limit - assets;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        shares = super.deposit(assets, receiver);
        _autoAllocate();
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        require(shares <= maxRedeem(owner), "ERC4626: redeem more than max");
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 nominalAssets = previewRedeem(shares);
        _freeFunds(nominalAssets);
        assets = _min(nominalAssets, UNDERLYING.balanceOf(address(this)));

        _burn(owner, shares);
        UNDERLYING.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        redeem(shares, receiver, owner);
    }

    function set_role(address account, uint256 role) external {
        roles[account] = role;
    }

    function add_strategy(address newStrategy) external {
        _addStrategy(newStrategy, true);
    }

    function add_strategy(address newStrategy, bool addToQueue) external {
        _addStrategy(newStrategy, addToQueue);
    }

    function update_max_debt_for_strategy(address strategy, uint256 newMaxDebt) external {
        strategies[strategy].max_debt = newMaxDebt;
    }

    function set_default_queue(address[] memory newQueue) external {
        queue = newQueue;
    }

    function get_default_queue() external view returns (address[] memory) {
        return queue;
    }

    function default_queue(uint256 index) external view returns (address) {
        return queue[index];
    }

    function set_auto_allocate(bool newAutoAllocate) external {
        auto_allocate = newAutoAllocate;
    }

    function set_minimum_total_idle(uint256 newMinimumTotalIdle) external {
        minimum_total_idle = newMinimumTotalIdle;
    }

    function setProfitMaxUnlockTime(uint256 newProfitMaxUnlockTime) external {
        profitMaxUnlockTime = newProfitMaxUnlockTime;
    }

    function set_deposit_limit(uint256 newDepositLimit) external {
        deposit_limit = newDepositLimit;
    }

    function set_deposit_hook(address newDepositHook) external {
        deposit_hook = newDepositHook;
    }

    function set_withdraw_hook(address newWithdrawHook) external {
        withdraw_hook = newWithdrawHook;
    }

    function process_report(address strategy) external returns (uint256 profit, uint256 loss) {
        uint256 oldAssets = reportedAssets[strategy];
        uint256 currentAssets = IStrategy(strategy).convertToAssets(IStrategy(strategy).balanceOf(address(this)));
        reportedAssets[strategy] = currentAssets;
        strategies[strategy].current_debt = currentAssets;
        strategies[strategy].last_report = block.timestamp;

        if (currentAssets > oldAssets) {
            profit = currentAssets - oldAssets;
        } else {
            loss = oldAssets - currentAssets;
        }
    }

    function totalIdle() external view returns (uint256) {
        return UNDERLYING.balanceOf(address(this));
    }

    function totalDebt() external view returns (uint256 debt) {
        for (uint256 i; i < strategyList.length; ++i) {
            debt += reportedAssets[strategyList[i]];
        }
    }

    function _addStrategy(address strategy, bool addToQueue) internal {
        if (strategies[strategy].activation == 0) {
            strategies[strategy].activation = block.timestamp == 0 ? 1 : block.timestamp;
            strategyList.push(strategy);
        }
        if (addToQueue) queue.push(strategy);
    }

    function _autoAllocate() internal {
        if (!auto_allocate || queue.length == 0) return;
        uint256 idle = UNDERLYING.balanceOf(address(this));
        if (idle <= minimum_total_idle) return;

        uint256 amount = idle - minimum_total_idle;
        address strategy = queue[0];
        UNDERLYING.forceApprove(strategy, amount);
        IStrategy(strategy).deposit(amount, address(this));
        reportedAssets[strategy] += amount;
        strategies[strategy].current_debt = reportedAssets[strategy];
    }

    function _freeFunds(uint256 amount) internal {
        uint256 idle = UNDERLYING.balanceOf(address(this));
        if (idle >= amount || queue.length == 0) return;

        uint256 needed = amount - idle;
        address strategy = queue[0];
        uint256 shares = _min(IStrategy(strategy).maxRedeem(address(this)), IStrategy(strategy).previewWithdraw(needed));
        if (shares == 0) return;

        IStrategy(strategy).redeem(shares, address(this), address(this));
        reportedAssets[strategy] = IStrategy(strategy).convertToAssets(IStrategy(strategy).balanceOf(address(this)));
        strategies[strategy].current_debt = reportedAssets[strategy];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
