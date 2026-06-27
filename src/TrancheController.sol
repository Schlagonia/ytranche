// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {Authorized} from "./periphery/Authorized.sol";

/**
 * @title TrancheController
 * @author Yearn
 * @notice
 *  Economic source of truth for the Tranche system. Every Tranche shares
 *  the same `Tranche` struct — a target rate, an excess-share BPS, a
 *  baseline-assets accumulator, an accrual checkpoint, and an accrual pause flag.
 *  The struct is keyed by the Tranche strategy's address; the controller
 *  has no A/B/E specialised surface.
 *
 *  Tranches register themselves into the system via `registerTranche`,
 *  which appends them to `tranchesByPriority`. Index `0` is the most
 *  senior Tranche. Settlement walks the list in priority order to fund
 *  per-Tranche targets, then in reverse to absorb losses (junior first,
 *  senior last).
 *
 *  There is an option reserve and lives in any same-asset 4626 vault. Reserve
 *  absorbs loss before any Tranche.
 *
 *  Excess profit recorded at settlement is NOT immediately reflected in
 *  a Tranche's live NAV — it sits in `pendingExcess` until the Tranche
 *  strategy calls {realizeExcess} during its `report()`, letting the
 *  strategy lock the chunky profit over its unlock period.
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
    event TrancheAccrualPausedSet(address indexed tranche, bool accrualPaused);
    event TrancheLoss(address indexed tranche, uint256 amount);
    event ReserveFunded(address indexed funder, uint256 amount);
    event ReserveSwept(address indexed receiver, uint256 amount);
    event TokenSwept(address indexed token, address indexed receiver, uint256 amount);
    event Settled(int256 pnl);
    event ExcessRealized(address indexed tranche, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                           TRANCHE STRUCT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configuration + live state for a single Tranche.
     * @param registered             Set to `true` when the Tranche is bound.
     * @param accrualPaused          When true, target accrual is paused.
     * @param excessShareBps         BPS share of post-target excess profit.
     * @param targetRatePerSecondWad Continuous per-second target rate (WAD).
     * @param baselineAssets         Principal + realised target + realised excess.
     * @param lastAccrual            Timestamp of the last baseline accrual.
     * @param pendingExcess          Excess profit recorded at settlement but
     *                               not yet realised into `baselineAssets`.
     *                               Excluded from live NAV until the Tranche
     *                               calls {realizeExcess} during `report()`.
     */
    struct Tranche {
        bool registered;
        bool accrualPaused;
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

    /// @notice True only while reserve assets are being moved into the main vault.
    bool public reserveDepositInProgress;

    /**
     * @notice Tranches in priority order — senior first, junior last.
     *         Profit waterfall walks this in order; loss waterfall in
     *         reverse.
     */
    address[] public tranchesByPriority;

    /// @notice Per-Tranche config + live state, keyed by Tranche address.
    mapping(address => Tranche) public tranches;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a fresh controller. Tranches are not bound at
     *         construction — governance calls `registerTranche` once per
     *         Tranche after deployment (the Tranche strategies themselves
     *         require this controller's address in their constructor). The
     *         reserve vault is set afterwards via {setReserveVault}.
     */
    constructor(address _asset, address _mainVault, address _authorizer) Authorized(_authorizer) {
        ASSET = IERC20(_asset);
        VAULT = IVault(_mainVault);

        require(VAULT.asset() == _asset, "asset mismatch");

        // Approve the main vault once — deposits and reserve draws never
        // need to re-approve per call.
        ASSET.forceApprove(_mainVault, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            GOVERNANCE CONFIG
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register a Tranche as the new most-junior Tranche (appended to
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
     * @notice Register a Tranche at a specific priority `_index`, shifting every
     *         Tranche at or after that index one rung more junior. Use this to
     *         slot a new Tranche into the middle of the order. `_index` equal to
     *         the current length appends (same as {registerTranche}).
     * @dev    Existing Tranches keep all of their state — only the ordering
     *         changes. There is no removal: to retire a Tranche, zero its target
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
        require(_targetBps < MAX_BPS, "target > MAX_BPS");

        uint256 ratePerSecondWad = _bpsToPerSecondWad(_targetBps);
        tranches[_tranche] = Tranche({
            registered: true,
            targetRatePerSecondWad: ratePerSecondWad,
            excessShareBps: _excessShareBps,
            baselineAssets: 0,
            lastAccrual: block.timestamp,
            accrualPaused: false,
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

    /// @notice Set a Tranche's annualised target rate in basis points.
    /// @dev Accrues against the old rate first.
    function setTrancheTargetBps(address _tranche, uint16 _newBps) external isAuthorized(GOVERNANCE_ROLE) {
        require(_newBps < MAX_BPS, "target > MAX_BPS");
        Tranche storage tranche = tranches[_tranche];
        require(tranche.registered, "!tranche");

        _accrue(tranche);
        tranche.targetRatePerSecondWad = _bpsToPerSecondWad(_newBps);

        emit TrancheTargetRateSet(_tranche, tranche.targetRatePerSecondWad);
    }

    /// @notice Set a Tranche's excess-share in basis points.
    function setTrancheExcessShareBps(address _tranche, uint16 _newBps) external isAuthorized(GOVERNANCE_ROLE) {
        Tranche storage tranche = tranches[_tranche];
        require(tranche.registered, "!tranche");
        require(uint256(_newBps) + _totalExcessShareBpsExcluding(_tranche) <= MAX_BPS, "excess > MAX_BPS");

        tranche.excessShareBps = _newBps;

        emit TrancheExcessShareSet(_tranche, _newBps);
    }

    /// @notice Resume target accrual for a Tranche that previously absorbed loss.
    function resumeAccrual(address _tranche) external isAuthorized(MANAGEMENT_ROLE) {
        Tranche storage tranche = tranches[_tranche];
        require(tranche.registered, "!tranche");
        require(tranche.accrualPaused, "!paused");

        tranche.accrualPaused = false;
        tranche.lastAccrual = block.timestamp;

        emit TrancheAccrualPausedSet(_tranche, false);
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

    /// @notice Sweep stray ERC20 tokens. Main vault shares are protected because
    ///         they are Tranche backing, not recoverable dust.
    function sweep(address _token, uint256 _amount, address _receiver) external isAuthorized(GOVERNANCE_ROLE) {
        require(_token != address(VAULT), "protected token");
        require(_token != address(0) && _amount > 0 && _receiver != address(0), "bad arg");
        IERC20(_token).safeTransfer(_receiver, _amount);

        emit TokenSwept(_token, _receiver, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of registered Tranches.
    function tranchesLength() external view returns (uint256) {
        return tranchesByPriority.length;
    }

    function getTranchesByPriority() external view returns (address[] memory) {
        return tranchesByPriority;
    }

    /// @notice Whether `_tranche` is a registered Tranche. Consulted by the
    ///         Hook to gate per-Tranche rate-limit consumption.
    function isTranche(address _tranche) external view returns (bool) {
        return tranches[_tranche].registered;
    }

    function isAccrualPaused(address _tranche) external view returns (bool) {
        return tranches[_tranche].accrualPaused;
    }

    /// @notice Live NAV for a Tranche — its NAV source. Reverts if the Tranche
    ///         is not registered.
    function liveAssets(address _tranche) external view returns (uint256) {
        Tranche memory tranche = tranches[_tranche];
        require(tranche.registered, "!tranche");
        return _liveAssetsView(tranche);
    }

    /// @notice Excess recorded at settlement awaiting realisation via
    ///         {realizeExcess}. Not part of the Tranche's live NAV.
    function pendingExcess(address _tranche) external view returns (uint256) {
        return tranches[_tranche].pendingExcess;
    }

    /// @notice NAV — main vault assets attributable to this controller.
    function vaultAssets() public view returns (uint256) {
        return VAULT.convertToAssets(VAULT.balanceOf(address(this)));
    }

    /// @notice Maximum amount the controller can currently pull out of the vault.
    /// @dev We use maxRedeem to match how actual withdraws are done. To allow lossy
    ///      values to flow through.
    function vaultMaxWithdraw() external view returns (uint256) {
        return VAULT.convertToAssets(VAULT.maxRedeem(address(this)));
    }

    /// @notice Reserve held in the 4626 vault.
    function reserveAssets() public view returns (uint256) {
        if (address(reserveVault) == address(0)) return 0;
        return reserveVault.convertToAssets(reserveVault.balanceOf(address(this)));
    }

    /// @notice Total assets backing Tranche claims: main-vault NAV plus reserve.
    function backingAssets() public view returns (uint256) {
        return vaultAssets() + reserveAssets();
    }

    /// @notice Sum of every Tranche's current claim — live NAV plus unrealised
    ///         pending excess. This is the figure `settle` measures the main
    ///         vault against to compute PnL.
    function totalClaims() public view returns (uint256 total) {
        address[] memory trancheAddresses = tranchesByPriority;
        for (uint256 i = 0; i < trancheAddresses.length; ++i) {
            Tranche memory tranche = tranches[trancheAddresses[i]];
            total += _liveAssetsView(tranche) + tranche.pendingExcess;
        }
    }

    /// @notice Coverage for `_tranche` after senior Tranches consume backing assets.
    /// @return claim Full current claim: live NAV plus pending excess.
    /// @return covered Amount of `_tranche` claim covered by current backing.
    function trancheCoverage(address _tranche) external view returns (uint256 claim, uint256 covered) {
        require(tranches[_tranche].registered, "!tranche");

        uint256 remainingBacking = backingAssets();
        address[] memory trancheAddresses = tranchesByPriority;

        for (uint256 i = 0; i < trancheAddresses.length; ++i) {
            address trancheAddress = trancheAddresses[i];
            Tranche memory tranche = tranches[trancheAddress];
            uint256 trancheClaim = _liveAssetsView(tranche) + tranche.pendingExcess;
            uint256 trancheCovered = _min(trancheClaim, remainingBacking);

            if (trancheAddress == _tranche) {
                return (trancheClaim, trancheCovered);
            }

            remainingBacking -= trancheCovered;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ASSET ROUTING HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pull `_amount` underlying from the calling Tranche and
     *         route it into the main risky vault.
     */
    function depositFromTranche(uint256 _amount) external onlyTranche {
        if (_amount == 0) return;

        // Roll the Tranche's baseline forward, then credit the new principal.
        Tranche storage tranche = tranches[msg.sender];
        _accrue(tranche);
        tranche.baselineAssets += _amount;

        // Pull the underlying from the Tranche and route it into the main vault.
        ASSET.safeTransferFrom(msg.sender, address(this), _amount);
        VAULT.deposit(_amount, address(this));
    }

    /**
     * @notice Withdraws, `_amount` from the main vault to send back to
     *         the calling Tranche.
     * @dev The full claim (`_amount`) is debited from the baseline, but
     *      only realized withdrawals are handed back. The Tranche's own
     *      max_loss should limit the realizable loss.
     */
    function withdrawFromTranche(uint256 _amount) external onlyTranche {
        if (_amount == 0) return;

        // Roll the Tranche's baseline forward. A Tranche can never source more
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
     * @notice Realise the calling Tranche's pending excess into its
     *         baseline. Called by the Tranche during `report()` so the
     *         chunky settlement profit is recorded and locked over the
     *         strategy's profit-unlock period instead of surfacing
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
     * @notice Apply the Tranche waterfall.
     *
     *   1. Accrue every Tranche.
     *   2. pnl = vaultAssets() − Σ (Tranche.baselineAssets + Tranche.pendingExcess)
     *   3. Profit path — a strictly profitable settle resumes accrual for any
     *      Tranche paused by an earlier loss, then records the surplus by
     *      each Tranche's `excessShareBps` as `pendingExcess`. It does NOT
     *      enter live NAV until the Tranche realises it via {realizeExcess}
     *      during its `report()`, so the strategy can lock the chunky
     *      profit. Any remainder (sum < MAX_BPS) stays in the main vault.
     *   4. Loss path — the reserve absorbs first, then each Tranche in
     *      REVERSE priority (junior first) absorbs from its total claim:
     *      pending excess first, then baseline. Any loss — pending or
     *      baseline — pauses accrual for the Tranche and emits one combined
     *      {TrancheLoss}. Pending excess is treated as part of the claim, so
     *      the loss order is constant regardless of unrealised excess.
     */
    function settle() external isAuthorized(KEEPER_ROLE) {
        uint256 numberOfTranches = tranchesByPriority.length;

        // 1. Accrue every Tranche and total up the system's claim:
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

                // Resume accrual for any Tranche paused by an earlier loss.
                if (tranche.accrualPaused) {
                    tranche.accrualPaused = false;
                    emit TrancheAccrualPausedSet(trancheAddress, false);
                }

                // Record this Tranche's slice of the excess as pending.
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
            uint256 fromReserve = _min(loss, reserveAssets());
            if (fromReserve > 0) {
                uint256 drawn = _drawReserveToMain(fromReserve);
                loss -= _min(loss, drawn);
            }

            // 4b. Then Tranches in REVERSE priority (junior first). Each Tranche
            //     absorbs from its total claim, pending excess first, then baseline.
            //     Any loss to the Tranche (pending and/or baseline) pauses target accrual.
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

                // Any loss to the Tranche (pending and/or baseline) pauses target accrual.
                uint256 absorbed = fromPending + fromBaseline;
                if (absorbed > 0) {
                    if (!tranche.accrualPaused) {
                        tranche.accrualPaused = true;
                        emit TrancheAccrualPausedSet(trancheAddress, true);
                    }
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
     * @dev Redeem reserve-vault shares and deposit the received assets into the
     *      main vault. Uses share-exact redemption for full drains so 4626
     *      rounding cannot make asset-exact `withdraw` revert.
     */
    function _drawReserveToMain(uint256 _amount) internal returns (uint256 received) {
        uint256 sharesToRedeem = _min(reserveVault.maxRedeem(address(this)), reserveVault.previewWithdraw(_amount));

        uint256 balanceBefore = ASSET.balanceOf(address(this));
        reserveVault.redeem(sharesToRedeem, address(this), address(this));
        received = ASSET.balanceOf(address(this)) - balanceBefore;

        if (received > 0) {
            reserveDepositInProgress = true;
            VAULT.deposit(received, address(this));
            reserveDepositInProgress = false;
        }
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev View-only live NAV for `_tranche` (no state change).
    function _liveAssetsView(Tranche memory _tranche) internal view returns (uint256) {
        if (_tranche.accrualPaused) return _tranche.baselineAssets;
        uint256 dt = block.timestamp - _tranche.lastAccrual;
        if (dt == 0) return _tranche.baselineAssets;
        return _tranche.baselineAssets + (_tranche.baselineAssets * _tranche.targetRatePerSecondWad * dt) / WAD;
    }

    /// @dev Roll `_tranche.baselineAssets` forward by its target accrual.
    function _accrue(Tranche storage _tranche) internal {
        _tranche.baselineAssets = _liveAssetsView(_tranche);
        _tranche.lastAccrual = block.timestamp;
    }

    /// @dev Sum of `excessShareBps` across all registered Tranches except
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
