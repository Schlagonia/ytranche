// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseHooks, BaseHealthCheck} from "@periphery/Bases/Hooks/BaseHooks.sol";
import {TokenizedStrategyLib as TokenizedStrategy} from "@tokenized-strategy/libraries/TokenizedStrategyLib.sol";

import {ITrancheController} from "./interfaces/ITrancheController.sol";
import {IHook} from "./interfaces/IHook.sol";
import {Authorized} from "./periphery/Authorized.sol";

/**
 * @title TrancheStrategy
 * @author ytranche
 * @notice
 *  Base Tranche strategy — atomic deposit & withdraw, no cooldown. Used
 *  directly for the senior Tranche (A). The junior (B) and equity (E)
 *  Tranches extend this contract via {LockedTrancheStrategy} to add a
 *  cooldown + withdrawal-window layer.
 *
 *  All economics live in `TrancheController`. The Hook contract is the
 *  central security/policy gate; this strategy queries it for actual
 *  per-flow caps (returned in asset units) and `min`s them with whatever
 *  local constraints it has (cooldown availability for the locked variant).
 *
 *  The Hook reference is **settable** by governance through the shared
 *  Authorizer — governance can rotate to a new Hook implementation without
 *  redeploying the Tranche.
 */
contract TrancheStrategy is BaseHooks, Authorized {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SetHook(address indexed hook);

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Central economic controller (NAV source, settlement, waterfall).
    ITrancheController public immutable CONTROLLER;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Settable Hook contract — security / policy gate.
    IHook public hook;

    /// @dev Explicit ERC20 symbol for this Tranche. TokenizedStrategy defaults
    ///      to `ys<asset symbol>`, which is useless when several Tranches share
    ///      the same asset.
    string private _symbol;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _asset,
        string memory _name,
        string memory _trancheSymbol,
        address _controller,
        address _hook,
        address _authorizer
    ) BaseHealthCheck(_asset, _name) Authorized(_authorizer) {
        require(_controller != address(0) && _hook != address(0), "ZERO");
        require(bytes(_trancheSymbol).length != 0, "ZERO symbol");
        CONTROLLER = ITrancheController(_controller);
        hook = IHook(_hook);
        _symbol = _trancheSymbol;

        // Avoid the management setter: it accrues and hits controller.liveAssets before registration.
        TokenizedStrategy.strategyStorage().performanceFee = 0;

        // Pre-approve the controller to pull underlying during `_deployFunds`.
        IERC20(_asset).forceApprove(_controller, type(uint256).max);
    }

    /// @notice ERC20 symbol set at deployment.
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /*//////////////////////////////////////////////////////////////
                          MANAGEMENT CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Rotate to a new Hook contract. Governance only.
    function setHook(address _newHook) external isAuthorized(GOVERNANCE_ROLE) {
        require(_newHook != address(0), "ZERO hook");
        hook = IHook(_newHook);

        emit SetHook(_newHook);
    }

    /*//////////////////////////////////////////////////////////////
                            YEARN BASE HOOKS
    //////////////////////////////////////////////////////////////*/

    function _deployFunds(uint256 _amount) internal override {
        CONTROLLER.depositFromTranche(_amount);
    }

    function _freeFunds(uint256 _amount) internal override {
        CONTROLLER.withdrawFromTranche(_amount);
    }

    function _strategyTotalAssets() internal view override returns (uint256) {
        return CONTROLLER.liveAssets(address(this));
    }

    function _harvestAndReport() internal override returns (uint256) {
        // Pull any excess recorded at settlement into the baseline so the
        // profit is captured by this report and locked over the unlock
        // period instead of hitting `totalAssets` instantly.
        CONTROLLER.realizeExcess();
        return _strategyTotalAssets();
    }

    /// @dev Meter the deposit against this Tranche's rolling rate limit through
    ///      the same Hook surface the main vault calls. Runs after shares mint.
    function _postDepositHook(uint256 _assets, uint256 _shares, address _receiver) internal virtual override {
        hook.post_deposit(msg.sender, _receiver, _assets, _shares);
    }

    /// @dev Meter the withdrawal against this Tranche's rolling rate limit
    ///      through the same Hook surface the main vault calls. Runs after the
    ///      shares burn.
    function _postWithdrawHook(uint256 _assets, uint256 _shares, address _receiver, address _owner, uint256)
        internal
        virtual
        override
    {
        hook.post_withdraw(msg.sender, _receiver, _owner, _assets, _shares);
    }

    /*//////////////////////////////////////////////////////////////
                        AVAILABLE-LIMIT OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Asset amount that can be deposited right now.
     * @dev {BaseHealthCheck} gates on this Tranche's own open / allow-list; when
     *      it admits the receiver, bound by the Hook's rolling-rate / aggregate
     *      caps (which also fold in the shared main-vault ingress).
     */
    function availableDepositLimit(address _receiver) public view virtual override returns (uint256) {
        uint256 gated = super.availableDepositLimit(_receiver);
        return Math.min(gated, hook.depositCap(address(this)));
    }

    /**
     * @notice Asset amount that can be withdrawn right now.
     * @dev Pulls the actual cap from the Hook, which already bounds the result
     *      by the rolling rate limit and the controller's loss-free main-vault
     *      deliverable. Derived contracts (e.g. {LockedTrancheStrategy}) further
     *      `min` this with their own constraint (cooldown availability).
     */
    function availableWithdrawLimit(
        address /*_owner*/
    )
        public
        view
        virtual
        override
        returns (uint256)
    {
        return hook.withdrawCap(address(this));
    }
}
