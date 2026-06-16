// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {Authorized} from "./utils/Authorized.sol";

/**
 * @title TrancheController
 * @author ytranche
 * @notice
 *  Economic source of truth for the tranche system. Every tranche shares
 *  the same `Tranche` struct — a target rate, an excess-share BPS, a
 *  baseline-assets accumulator, an accrual checkpoint, and a frozen flag.
 *  The struct is keyed by the tranche strategy's address; the controller
 *  has no A/B/E specialised surface.
 *
 *  Tranches register themselves into the system via `registerTranche`,
 *  which appends them to `tranchesByPriority`. Index `0` is the most
 *  senior tranche. Settlement walks the list in priority order to fund
 *  per-tranche targets, then in reverse to absorb losses (junior first,
 *  senior last).
 *
 *  Reserve is mandatory and lives in any same-asset 4626 vault. Reserve
 *  absorbs loss before any tranche baseline (unrealised pending excess
 *  is clawed back even earlier).
 *
 *  Excess profit recorded at settlement is NOT immediately reflected in
 *  a tranche's live NAV — it sits in `pendingExcess` until the tranche
 *  strategy calls {realizeExcess} during its `report()`, letting the
 *  strategy lock the chunky profit over its unlock period.
 *
 *  Defaults at deployment: no tranches registered. Governance calls
 *  `registerTranche` once per tranche, supplying its target rate and
 *  excess-share BPS up-front.
 */
contract TrancheController is Authorized {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ReserveVaultSet(address indexed newReserveVault);
    event TrancheRegistered(
        address indexed tranche, uint256 indexed priority, uint256 targetRatePerSecondWad, uint16 excessShareBps
    );
    event TrancheTargetRateSet(address indexed tranche, uint256 newRatePerSecondWad);
    event TrancheExcessShareSet(address indexed tranche, uint16 newExcessShareBps);
    event TrancheFrozenSet(address indexed tranche, bool frozen);
    event TrancheLoss(address indexed tranche, uint256 amount);
    event ReserveFunded(address indexed funder, uint256 amount);
    event ReserveSwept(address indexed receiver, uint256 amount);
    event Settled(int256 pnl);
    event ExcessRealized(address indexed tranche, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                           TRANCHE STRUCT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configuration + live state for a single tranche.
     * @param registered             Set to `true` when the tranche is bound.
     * @param frozen                 When true, target accrual is paused.
     * @param excessShareBps         BPS share of post-target excess profit.
     * @param targetRatePerSecondWad Continuous per-second target rate (WAD).
     * @param baselineAssets         Principal + realised target + realised excess.
     * @param lastAccrual            Timestamp of the last baseline accrual.
     * @param pendingExcess          Excess profit recorded at settlement but
     *                               not yet realised into `baselineAssets`.
     *                               Excluded from live NAV until the tranche
     *                               calls {realizeExcess} during `report()`.
     */
    struct Tranche {
        bool registered;
        bool frozen;
        uint16 excessShareBps;
        uint256 targetRatePerSecondWad;
        uint256 baselineAssets;
        uint256 lastAccrual;
        uint256 pendingExcess;
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyTranche() {
        require(tranches[msg.sender].registered, "!tranche");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_556_952;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Underlying asset of the whole system.
    IERC20 public immutable ASSET;

    /// @notice Yearn V3 multi-strategy vault.
    IVault public immutable VAULT;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Optional same-asset 4626 vault holding the reserve buffer
    ///         (e.g. sUSDS / yvUSDC). Earns the underlying yield.
    IERC4626 public reserveVault;

    /**
     * @notice Tranches in priority order — senior first, junior last.
     *         Profit waterfall walks this in order; loss waterfall in
     *         reverse.
     */
    address[] public tranchesByPriority;

    /// @notice Per-tranche config + live state, keyed by tranche address.
    mapping(address => Tranche) public tranches;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a fresh controller. Tranches are not bound at
     *         construction — governance calls `registerTranche` once per
     *         tranche after deployment (the tranche strategies themselves
     *         require this controller's address in their constructor). The
     *         reserve vault is set afterwards via {setReserveVault}.
     */
    constructor(address _asset, address _mainVault, address _authorizer) Authorized(_authorizer) {
        require(_asset != address(0), "ZERO asset");
        require(_mainVault != address(0), "ZERO mainVault");

        ASSET = IERC20(_asset);
        VAULT = IVault(_mainVault);

        // Approve the main vault once — deposits and reserve draws never
        // need to re-approve per call.
        ASSET.forceApprove(_mainVault, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            GOVERNANCE CONFIG
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register a tranche as the new most-junior tranche (appended to
     *         the end of the priority list). Index `0` is the most senior.
     * @param _tranche         Tranche strategy address.
     * @param _targetBps       Annualised target rate in basis points.
     * @param _excessShareBps  Share of post-target excess profit.
     */
    function registerTranche(address _tranche, uint16 _targetBps, uint16 _excessShareBps)
        external
        isAuthorized(GOVERNANCE_ROLE)
    {
        _registerTrancheAt(_tranche, _targetBps, _excessShareBps, tranchesByPriority.length);
    }

    /**
     * @notice Register a tranche at a specific priority `_index`, shifting every
     *         tranche at or after that index one rung more junior. Use this to
     *         slot a new tranche into the middle of the order. `_index` equal to
     *         the current length appends (same as {registerTranche}).
     * @dev    Existing tranches keep all of their state — only the ordering
     *         changes. There is no removal: to retire a tranche, zero its target
     *         rate and excess share (it then stops accruing/earning but stays in
     *         the waterfall so holders can still wind down).
     */
    function registerTrancheAt(address _tranche, uint16 _targetBps, uint16 _excessShareBps, uint256 _index)
        external
        isAuthorized(GOVERNANCE_ROLE)
    {
        _registerTrancheAt(_tranche, _targetBps, _excessShareBps, _index);
    }

    function _registerTrancheAt(address _tranche, uint16 _targetBps, uint16 _excessShareBps, uint256 _index) internal {
        require(_tranche != address(0), "ZERO tranche");
        require(!tranches[_tranche].registered, "already registered");
        require(_index <= tranchesByPriority.length, "bad index");
        require(_excessShareBps + _totalExcessShareBpsExcluding(_tranche) <= MAX_BPS, "excess > MAX_BPS");

        uint256 ratePerSecondWad = _bpsToPerSecondWad(_targetBps);
        tranches[_tranche] = Tranche({
            registered: true,
            targetRatePerSecondWad: ratePerSecondWad,
            excessShareBps: _excessShareBps,
            baselineAssets: 0,
            lastAccrual: block.timestamp,
            frozen: false,
            pendingExcess: 0
        });

        // Insert at `_index`, shifting the tail one rung more junior.
        uint256 len = tranchesByPriority.length;
        tranchesByPriority.push(_tranche);
        for (uint256 i = len; i > _index; --i) {
            tranchesByPriority[i] = tranchesByPriority[i - 1];
        }
        tranchesByPriority[_index] = _tranche;

        emit TrancheRegistered(_tranche, _index, ratePerSecondWad, _excessShareBps);
    }

    /// @notice Replace the reserve vault, or clear it with `address(0)`. A
    ///         non-zero vault must hold the system asset. The previous vault
    ///         must already be swept (shares moved out via {withdrawReserve})
    ///         so no reserve is stranded behind the old address.
    function setReserveVault(address _newReserveVault) external isAuthorized(GOVERNANCE_ROLE) {
        if (_newReserveVault != address(0)) {
            require(IERC4626(_newReserveVault).asset() == address(ASSET), "asset mismatch");
        }
        if (address(reserveVault) != address(0)) {
            require(reserveVault.balanceOf(address(this)) == 0, "reserve not empty");
        }
        reserveVault = IERC4626(_newReserveVault);

        emit ReserveVaultSet(_newReserveVault);
    }

    /// @notice Set a tranche's annualised target rate in basis points.
    /// @dev Accrues against the old rate first.
    function setTrancheTargetBps(address _tranche, uint16 _newBps) external isAuthorized(GOVERNANCE_ROLE) {
        Tranche storage tranche = tranches[_tranche];
        require(tranche.registered, "!tranche");

        _accrue(tranche);
        tranche.targetRatePerSecondWad = _bpsToPerSecondWad(_newBps);

        emit TrancheTargetRateSet(_tranche, tranche.targetRatePerSecondWad);
    }

    /// @notice Set a tranche's excess-share in basis points.
    function setTrancheExcessShareBps(address _tranche, uint16 _newBps) external isAuthorized(GOVERNANCE_ROLE) {
        Tranche storage tranche = tranches[_tranche];
        require(tranche.registered, "!tranche");
        require(uint256(_newBps) + _totalExcessShareBpsExcluding(_tranche) <= MAX_BPS, "excess > MAX_BPS");

        tranche.excessShareBps = _newBps;

        emit TrancheExcessShareSet(_tranche, _newBps);
    }

    /// @notice Clear a tranche's accrual-frozen flag.
    function unfreeze(address _tranche) external isAuthorized(MANAGEMENT_ROLE) {
        Tranche storage tranche = tranches[_tranche];
        require(tranche.registered, "!tranche");

        tranche.frozen = false;
        tranche.lastAccrual = block.timestamp;

        emit TrancheFrozenSet(_tranche, false);
    }

    /*//////////////////////////////////////////////////////////////
                            RESERVE FUNDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Add underlying to the reserve. Anyone may call.
    function fundReserve(uint256 _amount) external {
        require(_amount > 0, "zero");
        ASSET.safeTransferFrom(msg.sender, address(this), _amount);
        ASSET.forceApprove(address(reserveVault), _amount);
        reserveVault.deposit(_amount, address(this));

        emit ReserveFunded(msg.sender, _amount);
    }

    /// @notice Sweep reserve-vault shares out of the system (e.g. ahead of a
    ///         migration). Transfers the 4626 shares themselves rather than
    ///         redeeming to underlying, so the receiver can redeem at will and
    ///         the controller's reserve balance can be brought to zero.
    function withdrawReserve(uint256 _shares, address _receiver) external isAuthorized(GOVERNANCE_ROLE) {
        require(_shares > 0 && _receiver != address(0), "bad arg");
        IERC20(address(reserveVault)).safeTransfer(_receiver, _shares);

        emit ReserveSwept(_receiver, _shares);
    }

    /*//////////////////////////////////////////////////////////////
                              LIVE NAV VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Live NAV for a tranche — its NAV source. Reverts if the tranche
    ///         is not registered.
    function liveAssets(address _tranche) external view returns (uint256) {
        Tranche memory tranche = tranches[_tranche];
        require(tranche.registered, "!tranche");
        return _liveAssetsView(tranche);
    }

    function isFrozen(address _tranche) external view returns (bool) {
        return tranches[_tranche].frozen;
    }

    /// @notice Whether `_tranche` is a registered tranche. Consulted by the
    ///         Hook to gate per-tranche rate-limit consumption.
    function isTranche(address _tranche) external view returns (bool) {
        return tranches[_tranche].registered;
    }

    /// @notice Excess recorded at settlement awaiting realisation via
    ///         {realizeExcess}. Not part of the tranche's live NAV.
    function pendingExcess(address _tranche) external view returns (uint256) {
        return tranches[_tranche].pendingExcess;
    }

    /// @notice Reserve held in the 4626 vault.
    function reserveAssets() public view returns (uint256) {
        if (address(reserveVault) == address(0)) return 0;
        return reserveVault.convertToAssets(reserveVault.balanceOf(address(this)));
    }

    /// @notice NAV — main vault assets attributable to this controller.
    function vaultAssets() public view returns (uint256) {
        return VAULT.convertToAssets(VAULT.balanceOf(address(this)));
    }

    /// @notice Maximum amount the controller can currently pull out of the vault.
    function vaultMaxWithdraw() external view returns (uint256) {
        // Full deliverable allowing loss realisation — a redeemer may exit
        // during a vault deficit and take the loss (passed through in
        // {withdrawFromTranche}); the reserve is not a redemption source.
        return VAULT.maxWithdraw(address(this), MAX_BPS);
    }

    /// @notice Number of registered tranches.
    function tranchesLength() external view returns (uint256) {
        return tranchesByPriority.length;
    }

    function getTranchesByPriority() external view returns (address[] memory) {
        return tranchesByPriority;
    }

    function isSolvent() external view returns (bool) {
        return vaultAssets() + reserveAssets() >= totalClaims();
    }

    /// @notice Sum of every tranche's current claim — live NAV plus unrealised
    ///         pending excess. This is the figure `settle` measures the main
    ///         vault against to compute PnL.
    function totalClaims() public view returns (uint256 total) {
        address[] memory trancheAddresses = tranchesByPriority;
        for (uint256 i = 0; i < trancheAddresses.length; ++i) {
            Tranche memory tranche = tranches[trancheAddresses[i]];
            total += _liveAssetsView(tranche) + tranche.pendingExcess;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ASSET ROUTING HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pull `_amount` underlying from the calling tranche and
     *         route it into the main risky vault.
     */
    function depositFromTranche(uint256 _amount) external onlyTranche {
        if (_amount == 0) return;

        // Roll the tranche's baseline forward, then credit the new principal.
        Tranche storage tranche = tranches[msg.sender];
        _accrue(tranche);
        tranche.baselineAssets += _amount;

        // Pull the underlying from the tranche and route it into the main vault.
        ASSET.safeTransferFrom(msg.sender, address(this), _amount);
        VAULT.deposit(_amount, address(this));
    }

    /**
     * @notice Source `_amount` underlying for the calling tranche from the main
     *         vault. The full claim (`_amount`) is debited from the baseline,
     *         but only the assets the vault actually delivers are handed back —
     *         so a redemption that realises a vault loss passes that loss
     *         through to the withdrawing tranche/user (booked against them by
     *         the TokenizedStrategy per the redeemer's `maxLoss`). The reserve
     *         is a settlement-time backstop only, never a redemption source.
     */
    function withdrawFromTranche(uint256 _amount) external onlyTranche {
        if (_amount == 0) return;

        // Roll the tranche's baseline forward. A tranche can never source more
        // than its own claim, so cap the withdrawal to its baseline and debit it.
        Tranche storage tranche = tranches[msg.sender];
        _accrue(tranche);

        if (_amount > tranche.baselineAssets) {
            _amount = tranche.baselineAssets;
        }

        if (_amount == 0) return;
        tranche.baselineAssets -= _amount;

        //  Redeem from the  main vault and hand back exactly what was received,
        // so any loss is borne by the redeemer and can be limited by its max_loss input value.
        uint256 sharesToRedeem = _min(VAULT.maxRedeem(address(this)), VAULT.previewWithdraw(_amount));

        uint256 balanceBefore = ASSET.balanceOf(address(this));
        VAULT.redeem(sharesToRedeem, address(this), address(this));
        uint256 received = ASSET.balanceOf(address(this)) - balanceBefore;

        ASSET.safeTransfer(msg.sender, received);
    }

    /**
     * @notice Realise the calling tranche's pending excess into its
     *         baseline. Called by the tranche during `report()` so the
     *         chunky settlement profit is recorded — and locked over the
     *         strategy's profit-unlock period — instead of surfacing
     *         immediately in `totalAssets`.
     * @return realized Amount moved from pending into the baseline.
     */
    function realizeExcess() external onlyTranche returns (uint256 realized) {
        Tranche storage tranche = tranches[msg.sender];
        _accrue(tranche);

        realized = tranche.pendingExcess;
        if (realized == 0) return 0;

        tranche.pendingExcess = 0;
        tranche.baselineAssets += realized;

        emit ExcessRealized(msg.sender, realized);
    }

    /*//////////////////////////////////////////////////////////////
                              SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Apply the tranche waterfall.
     *
     *   1. Accrue every tranche.
     *   2. pnl = vaultAssets() − Σ (tranche.baselineAssets + tranche.pendingExcess)
     *   3. Profit path — a strictly profitable settle auto-unfreezes any
     *      tranche frozen by an earlier loss, then records the surplus by
     *      each tranche's `excessShareBps` as `pendingExcess`. It does NOT
     *      enter live NAV until the tranche realises it via {realizeExcess}
     *      during its `report()`, so the strategy can lock the chunky
     *      profit. Any remainder (sum < MAX_BPS) stays in the main vault.
     *   4. Loss path — the reserve absorbs first, then each tranche in
     *      REVERSE priority (junior first) absorbs from its total claim:
     *      pending excess first, then baseline. Any loss — pending or
     *      baseline — freezes the tranche and emits one combined
     *      {TrancheLoss}. Pending excess is treated as part of the claim, so
     *      the loss order is constant regardless of unrealised excess.
     */
    function settle() external isAuthorized(KEEPER_ROLE) {
        uint256 numberOfTranches = tranchesByPriority.length;

        // 1. Accrue every tranche and total up the system's claim:
        //    Σ (baselineAssets + pendingExcess).
        uint256 totalClaim;
        for (uint256 i = 0; i < numberOfTranches; ++i) {
            Tranche storage tranche = tranches[tranchesByPriority[i]];
            _accrue(tranche);
            totalClaim += tranche.baselineAssets + tranche.pendingExcess;
        }

        // 2. PnL is the main-vault NAV measured against that claim.
        int256 pnl = int256(vaultAssets()) - int256(totalClaim);

        if (pnl > 0) {
            // 3. Profit path — record the surplus as pending excess by share.
            uint256 excess = uint256(pnl);

            for (uint256 i = 0; i < numberOfTranches; ++i) {
                address trancheAddress = tranchesByPriority[i];
                Tranche storage tranche = tranches[trancheAddress];

                // A strictly profitable settle means the vault is earning
                // beyond every live target again — resume accrual for any
                // tranche frozen by an earlier loss. `lastAccrual` was just
                // checkpointed in the accrual loop above.
                if (tranche.frozen) {
                    tranche.frozen = false;
                    emit TrancheFrozenSet(trancheAddress, false);
                }

                // Record this tranche's slice of the excess as pending — it
                // enters live NAV only when the tranche calls {realizeExcess}.
                uint256 share = (excess * tranche.excessShareBps) / MAX_BPS;
                if (share > 0) {
                    tranche.pendingExcess += share;
                }
            }

            // Any remainder (sum of excessShareBps < MAX_BPS) simply stays in
            // the main vault — surfaces again on the next settlement as profit.
        } else if (pnl < 0) {
            // 4. Loss path — absorb the loss in waterfall order.
            uint256 loss = uint256(-pnl);

            // 4a. The reserve (equity first-loss buffer) absorbs first, drawn
            //     into the main vault.
            uint256 reserveAvailable = reserveAssets();
            uint256 fromReserve = _min(loss, reserveAvailable);
            if (fromReserve > 0) {
                _drawReserveToMain(fromReserve);
                loss -= fromReserve;
            }

            // 4b. Then tranches in REVERSE priority (junior first). Each tranche
            //     absorbs from its total claim — pending excess first (earned-
            //     but-unrealised yield), then baseline. Pending excess is part
            //     of the claim, so the loss order is constant regardless of
            //     whether the excess has been realised, and any loss — pending
            //     or baseline — freezes the tranche.
            for (uint256 i = numberOfTranches; i > 0; --i) {
                if (loss == 0) break;

                address trancheAddress = tranchesByPriority[i - 1];
                Tranche storage tranche = tranches[trancheAddress];

                uint256 fromPending = _min(loss, tranche.pendingExcess);
                if (fromPending > 0) {
                    tranche.pendingExcess -= fromPending;
                    loss -= fromPending;
                }

                uint256 fromBaseline = _min(loss, tranche.baselineAssets);
                if (fromBaseline > 0) {
                    tranche.baselineAssets -= fromBaseline;
                    loss -= fromBaseline;
                }

                // Any loss to the tranche (pending and/or baseline) freezes it
                // and is reported as one combined amount.
                uint256 absorbed = fromPending + fromBaseline;
                if (absorbed > 0) {
                    tranche.frozen = true;
                    emit TrancheFrozenSet(trancheAddress, true);
                    emit TrancheLoss(trancheAddress, absorbed);
                }
            }
        }

        emit Settled(pnl);
    }

    /*//////////////////////////////////////////////////////////////
                          RESERVE PLUMBING
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Pull `_amount` from the reserve vault and deposit it into the
     *      main vault.
     */
    function _drawReserveToMain(uint256 _amount) internal {
        reserveVault.withdraw(_amount, address(this), address(this));
        VAULT.deposit(_amount, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev View-only live NAV for `_tranche` (no state change).
    function _liveAssetsView(Tranche memory _tranche) internal view returns (uint256) {
        if (_tranche.frozen) return _tranche.baselineAssets;
        uint256 dt = block.timestamp - _tranche.lastAccrual;
        if (dt == 0) return _tranche.baselineAssets;
        return _tranche.baselineAssets + (_tranche.baselineAssets * _tranche.targetRatePerSecondWad * dt) / WAD;
    }

    /// @dev Roll `_tranche.baselineAssets` forward by its target accrual.
    function _accrue(Tranche storage _tranche) internal {
        _tranche.baselineAssets = _liveAssetsView(_tranche);
        _tranche.lastAccrual = block.timestamp;
    }

    /// @dev Sum of `excessShareBps` across all registered tranches except
    ///      `_excluded`. Used to validate excess-share updates.
    function _totalExcessShareBpsExcluding(address _excluded) internal view returns (uint256 totalBps) {
        uint256 numberOfTranches = tranchesByPriority.length;
        for (uint256 i = 0; i < numberOfTranches; ++i) {
            address trancheAddress = tranchesByPriority[i];
            if (trancheAddress == _excluded) continue;
            totalBps += tranches[trancheAddress].excessShareBps;
        }
    }

    /// @dev Convert an annualised BPS rate to a per-second WAD rate.
    function _bpsToPerSecondWad(uint16 _bps) internal pure returns (uint256) {
        return (uint256(_bps) * WAD) / (MAX_BPS * SECONDS_PER_YEAR);
    }

    function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a < _b ? _a : _b;
    }
}
