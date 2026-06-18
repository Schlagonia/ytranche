// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";

import {Authorized} from "./periphery/Authorized.sol";
import {IHook} from "./interfaces/IHook.sol";
import {ITrancheController} from "./interfaces/ITrancheController.sol";
import {VaultV3WithdrawLimit} from "./libraries/VaultV3WithdrawLimit.sol";

/**
 * @title Hook
 * @author ytranche
 * @notice
 *  Central security / policy contract for the Tranche system. Wired
 *  directly as the Yearn V3 main-vault `deposit_hook` /
 *  `withdraw_hook` and consulted by every Tranche's
 *  `deposit` / `mint` / `withdraw` / `redeem` flow.
 *
 *  The controller is immutable and remains the source of truth for
 *  Tranche registration + priority. Hook only keeps local policy state:
 *  rolling rate limits and the main-vault open/allow-list gate (per-Tranche
 *  deposit gating lives on each Tranche's {BaseHealthCheck}). System-wide halts
 *  live on the {EmergencyAdmin} — it pauses/shuts down the vault and strategies
 *  directly. Solvency is controller state, not a Hook-level exit gate.
 *
 *  Access control is delegated to the shared {Authorizer}: limit and allow-list
 *  config requires MANAGEMENT (governance, the superuser, satisfies it too).
 */
contract Hook is IHook, Authorized {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RateLimitWindowSet(uint256 newRateLimitWindow);
    event DepositLimitSet(address indexed target, uint256 newLimit);
    event DepositRateLimitSet(address indexed target, uint128 newRateLimit);
    event WithdrawRateLimitSet(address indexed target, uint128 newRateLimit);

    event OpenSet(bool open);
    event AllowedSet(address indexed allowee, bool allowed);

    /*//////////////////////////////////////////////////////////////
                             BUCKET STRUCT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rolling-window rate-limit state for a single target.
     * @param used        Amount used in the current window, in asset units.
     * @param windowStart Timestamp the current window opened.
     * @param rateLimit   Max assets per window; `0` allows none (limits are opt-in).
     */
    struct Bucket {
        uint128 used;
        uint64 windowStart;
        uint128 rateLimit;
    }

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Yearn V3 multi-strategy vault, read from the controller.
    IVault public immutable VAULT;

    /// @notice Immutable controller. Hook reads Tranche metadata from here.
    ITrancheController public immutable CONTROLLER;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Main-vault open switch. The main vault is gated by default; when
    ///         `open` is true anyone may deposit into it directly. Per-Tranche
    ///         deposit gating lives on each Tranche (its {BaseHealthCheck}
    ///         `open`/`allowed`). Withdrawals are never gated.
    bool public open;

    /// @notice Main-vault allow-list. A gated main vault still admits an address
    ///         whose `allowed[who]` is true.
    mapping(address => bool) public allowed;

    /// @notice Rolling-window length in seconds shared by every rate limit.
    uint256 public rateLimitWindow;

    /// @notice Aggregate deposit ceiling keyed by address; `address(VAULT)` is
    ///         the main vault ingress ceiling. `0` (default) allows none —
    ///         limits are opt-in and must be configured by management.
    mapping(address => uint256) public depositLimits;

    /// @notice Per-Tranche rolling deposit rate limit.
    ///         `address(VAULT)` is reserved for the main vault ingress.
    mapping(address => Bucket) public depositRateLimit;

    /// @notice Per-Tranche rolling withdraw rate limit.
    mapping(address => Bucket) public withdrawRateLimit;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a fresh Hook.
     * @param _authorizer Shared access-control authority.
     * @param _controller Immutable TrancheController address.
     */
    constructor(address _authorizer, address _controller) Authorized(_authorizer) {
        require(_controller != address(0), "ZERO controller");
        CONTROLLER = ITrancheController(_controller);
        VAULT = IVault(ITrancheController(_controller).VAULT());
        rateLimitWindow = 1 hours;
    }

    /*//////////////////////////////////////////////////////////////
                            LIMITS CONFIG
    //////////////////////////////////////////////////////////////*/

    function setDepositLimit(address _target, uint256 _newLimit) external isAuthorized(MANAGEMENT_ROLE) {
        require(_target != address(0), "ZERO target");
        depositLimits[_target] = _newLimit;

        emit DepositLimitSet(_target, _newLimit);
    }

    function setRateLimitWindow(uint256 _newRateLimitWindow) external isAuthorized(MANAGEMENT_ROLE) {
        require(_newRateLimitWindow > 0, "zero window");
        rateLimitWindow = _newRateLimitWindow;

        emit RateLimitWindowSet(_newRateLimitWindow);
    }

    /// @notice Set the per-window deposit rate limit for a target (Tranche, or
    ///         the main vault via `address(VAULT)`). `0` (default) allows none.
    function setDepositRateLimit(address _target, uint128 _newRateLimit) external isAuthorized(MANAGEMENT_ROLE) {
        require(_target != address(0), "ZERO target");
        depositRateLimit[_target].rateLimit = _newRateLimit;

        emit DepositRateLimitSet(_target, _newRateLimit);
    }

    /// @notice Set the per-window withdraw rate limit for a target (Tranche, or
    ///         the main vault via `address(VAULT)`). `0` (default) allows none.
    function setWithdrawRateLimit(address _target, uint128 _newRateLimit) external isAuthorized(MANAGEMENT_ROLE) {
        require(_target != address(0), "ZERO target");
        withdrawRateLimit[_target].rateLimit = _newRateLimit;

        emit WithdrawRateLimitSet(_target, _newRateLimit);
    }

    /*//////////////////////////////////////////////////////////////
                             ACCESS CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Open (or re-gate) the main vault for permissionless direct
    ///         deposits. Per-Tranche gating lives on each Tranche.
    function setOpen(bool _open) external isAuthorized(MANAGEMENT_ROLE) {
        open = _open;

        emit OpenSet(_open);
    }

    /// @notice Set whether `_allowee` may deposit directly into the main vault.
    function setAllowed(address _allowee, bool _isAllowed) external isAuthorized(MANAGEMENT_ROLE) {
        allowed[_allowee] = _isAllowed;

        emit AllowedSet(_allowee, _isAllowed);
    }

    /*//////////////////////////////////////////////////////////////
                       CAPS FOR TRANCHE STRATEGIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Rate / aggregate deposit cap for a Tranche. The per-Tranche
    ///         open / allow-list gate is enforced on the Tranche itself
    ///         ({BaseHealthCheck}); this only meters throughput.
    function depositCap(address _tranche) external view returns (uint256) {
        // Bound by the Tranche's own deposit limit AND the shared main-vault
        // ingress — a Tranche deposit routes straight into the main vault, so it
        // can never exceed what the main vault will accept.
        return _min(_vaultDepositLimit(_tranche), _vaultDepositLimit(address(VAULT)));
    }

    function withdrawCap(address _tranche) external view returns (uint256) {
        // Withdrawals are never allow-list gated — holders can always exit, so
        // there is no owner to check. Bound by the rolling rate limit and the
        // controller's main-vault deliverable so a redemption never out-runs
        // main-vault liquidity (the reserve is a settlement-time backstop, not
        // a redemption source).
        return _min(_rateLimitAvailable(withdrawRateLimit[_tranche]), CONTROLLER.vaultMaxWithdraw());
    }

    /*//////////////////////////////////////////////////////////////
                    SHARED DEPOSIT / WITHDRAW HOOK SURFACE
    //////////////////////////////////////////////////////////////*/

    function available_deposit_limit(address _receiver) external view returns (uint256) {
        // No limits for the reserve vault deposits.
        if (_receiver == address(CONTROLLER) && CONTROLLER.reserveDepositInProgress()) {
            return type(uint256).max;
        }

        // Main-vault gate. The controller itself (Tranche-routed deposits) is
        // always permitted — end users are already gated at the Tranche level.
        if (_receiver != address(CONTROLLER) && !open && !allowed[_receiver]) {
            return 0;
        }

        return _vaultDepositLimit(address(VAULT));
    }

    function available_withdraw_limit(address _owner, uint256 _maxLoss, address[] calldata _strategies)
        external
        view
        returns (uint256)
    {
        return _min(
            _rateLimitAvailable(withdrawRateLimit[address(VAULT)]),
            VaultV3WithdrawLimit.maxWithdraw(VAULT, _owner, _maxLoss, _strategies)
        );
    }

    /// @notice Meter a deposit against the caller's rolling rate limit. Wired as
    ///         the main vault's `deposit_hook` and reused by each Tranche's
    ///         post-deposit hook. The bucket is keyed by `msg.sender`, so no
    ///         caller check is needed — a caller can only ever fill its own
    ///         bucket, never the main vault's or another Tranche's.
    function post_deposit(
        address _sender,
        address _receiver,
        uint256 _assets,
        uint256 /*_shares*/
    )
        external
    {
        // Don't consume the rate limit if the deposit is from the reserve vault.
        if (
            msg.sender == address(VAULT) && _sender == address(CONTROLLER) && _receiver == address(CONTROLLER)
                && CONTROLLER.reserveDepositInProgress()
        ) {
            return;
        }

        _consume(depositRateLimit[msg.sender], _assets);
    }

    /// @notice Meter a withdrawal against the caller's rolling rate limit. Wired
    ///         as the main vault's `withdraw_hook` and reused by each Tranche's
    ///         post-withdraw hook. Keyed by `msg.sender` (see {post_deposit}).
    function post_withdraw(
        address, /*_sender*/
        address, /*_receiver*/
        address, /*_owner*/
        uint256 _assets,
        uint256 /*_shares*/
    )
        external
    {
        _consume(withdrawRateLimit[msg.sender], _assets);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Remaining rate-limit headroom in `_bucket` for the current window.
    ///      A `rateLimit` of `0` means zero is allowed (limits are opt-in).
    function _rateLimitAvailable(Bucket memory _bucket) internal view returns (uint256) {
        uint256 used = _bucket.used;
        if (block.timestamp >= uint256(_bucket.windowStart) + rateLimitWindow) {
            used = 0;
        }
        if (used >= _bucket.rateLimit) return 0;
        return uint256(_bucket.rateLimit) - used;
    }

    /// @dev Stateful rate-limit consumption.
    function _consume(Bucket storage _bucket, uint256 _assets) internal {
        if (block.timestamp >= uint256(_bucket.windowStart) + rateLimitWindow) {
            _bucket.windowStart = uint64(block.timestamp);
            _bucket.used = 0;
        }
        uint256 next = uint256(_bucket.used) + _assets;
        require(next <= _bucket.rateLimit, "rate limit");
        _bucket.used = uint128(next);
    }

    /// @dev Remaining headroom under an aggregate deposit ceiling. A `_limit`
    ///      of `0` means zero is allowed (limits are opt-in).
    function _depositLimitAvailable(uint256 _limit, uint256 _currentAssets) internal pure returns (uint256) {
        if (_currentAssets >= _limit) return 0;
        return _limit - _currentAssets;
    }

    /// @dev Asset amount a vault will currently accept — the min of its rolling
    ///      deposit rate limit and aggregate deposit ceiling. `_target` is a
    ///      Tranche, or `address(VAULT)` for the main vault. Shared by the vault
    ///      deposit hook and every Tranche's `depositCap`.
    function _vaultDepositLimit(address _target) internal view returns (uint256) {
        return _min(
            _rateLimitAvailable(depositRateLimit[_target]),
            _depositLimitAvailable(depositLimits[_target], IVault(_target).totalAssets())
        );
    }

    function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a < _b ? _a : _b;
    }
}
