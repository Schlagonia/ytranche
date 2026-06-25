// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {TokenizedStrategyLib as TokenizedStrategy} from "@tokenized-strategy/libraries/TokenizedStrategyLib.sol";

import {TrancheStrategy} from "./TrancheStrategy.sol";

/**
 * @title LockedTrancheStrategy
 * @author Yearn
 * @notice
 *  TrancheStrategy + a redemption cooldown layer used for any Tranche
 *  that needs a withdrawal delay.
 *
 *
 *  Mechanism:
 *
 *    1. `deposit` / `mint` are unchanged from the base — atomic.
 *    2. `startCooldown(shares)` records `(cooldownEnd, windowEnd, shares)`
 *       for the caller, **overwriting** any prior record. Cooled shares
 *       remain economically active in the controller's accounting.
 *    3. After `cooldownEnd` and before `windowEnd`, the user can
 *       `redeem` / `withdraw` the cooled bucket. After `windowEnd` the
 *       record is stale — `availableWithdrawLimit` returns 0 and the
 *       user must `startCooldown` again.
 *    4. `cancelCooldown()` clears the entire pending record.
 *
 *  Both `cooldownDuration` and `withdrawalWindow` are management-settable
 *  with sane bounds (`MAX_COOLDOWN_DURATION`, `MIN_WITHDRAWAL_WINDOW`).
 */
contract LockedTrancheStrategy is TrancheStrategy {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CooldownDurationUpdated(uint256 newCooldownDuration);
    event WithdrawalWindowUpdated(uint256 newWithdrawalWindow);
    event CooldownStarted(address indexed user, uint256 shares, uint256 cooldownEnd, uint256 windowEnd);
    event CooldownCancelled(address indexed user);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Hard cap on `cooldownDuration` updates.
    uint256 public constant MAX_COOLDOWN_DURATION = 30 days;

    /// @notice Floor on `withdrawalWindow` updates.
    uint256 public constant MIN_WITHDRAWAL_WINDOW = 1 days;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Cooldown duration in seconds. `0` disables the gating —
    ///         the locked variant degenerates to the base behaviour.
    uint256 public cooldownDuration;

    /// @notice Window after `cooldownEnd` during which a redemption is
    ///         valid. After `cooldownEnd + withdrawalWindow` the record
    ///         is stale and the user must restart.
    uint256 public withdrawalWindow;

    /**
     * @notice Per-user cooldown record. `startCooldown` overwrites; one
     *         pending bucket per user.
     */
    struct UserCooldown {
        uint64 cooldownEnd;
        uint64 windowEnd;
        uint128 shares;
    }

    mapping(address => UserCooldown) public cooldowns;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a fresh locked Tranche.
     * @param _cooldownDuration Initial cooldown duration in seconds (≤ MAX).
     * @param _withdrawalWindow Initial withdrawal window in seconds (≥ MIN).
     */
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _controller,
        address _hook,
        address _authorizer,
        uint256 _cooldownDuration,
        uint256 _withdrawalWindow
    ) TrancheStrategy(_asset, _name, _symbol, _controller, _hook, _authorizer) {
        require(_cooldownDuration <= MAX_COOLDOWN_DURATION, "cooldown too long");
        require(_withdrawalWindow >= MIN_WITHDRAWAL_WINDOW, "window too short");
        cooldownDuration = _cooldownDuration;
        withdrawalWindow = _withdrawalWindow;
        emit CooldownDurationUpdated(_cooldownDuration);
        emit WithdrawalWindowUpdated(_withdrawalWindow);
    }

    /*//////////////////////////////////////////////////////////////
                          MANAGEMENT CONFIG
    //////////////////////////////////////////////////////////////*/

    function setCooldownDuration(uint256 _newCooldownDuration) external onlyManagement {
        require(_newCooldownDuration <= MAX_COOLDOWN_DURATION, "cooldown too long");
        cooldownDuration = _newCooldownDuration;

        emit CooldownDurationUpdated(_newCooldownDuration);
    }

    function setWithdrawalWindow(uint256 _newWithdrawalWindow) external onlyManagement {
        require(_newWithdrawalWindow >= MIN_WITHDRAWAL_WINDOW, "window too short");
        withdrawalWindow = _newWithdrawalWindow;

        emit WithdrawalWindowUpdated(_newWithdrawalWindow);
    }

    /*//////////////////////////////////////////////////////////////
                        AVAILABLE-LIMIT OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Min of:
     *           - the Hook's `withdrawCap` (rate-limit + pause),
     *           - the user's matured-and-still-in-window cooled-shares value.
     */
    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
        uint256 baseLimit = hook.withdrawCap(address(this));

        if (cooldownDuration == 0 || TokenizedStrategy.isShutdown()) {
            return baseLimit;
        }

        UserCooldown memory cooldown = cooldowns[_owner];
        if (cooldown.shares == 0) return 0;

        if (block.timestamp < cooldown.cooldownEnd) return 0;

        if (block.timestamp > cooldown.windowEnd) return 0;

        uint256 cooldownAssets = TokenizedStrategy.convertToAssets(cooldown.shares);
        return baseLimit < cooldownAssets ? baseLimit : cooldownAssets;
    }

    /*//////////////////////////////////////////////////////////////
                            COOLDOWN LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Start (or replace) a cooldown for `_shares` of the caller's
     *         balance. Overwrites any prior pending record.
     */
    function startCooldown(uint256 _shares) external {
        require(_shares > 0, "Invalid shares");
        require(cooldownDuration > 0, "no cooldown");

        uint256 bal = TokenizedStrategy.balanceOf(msg.sender);
        require(_shares <= bal, "Insufficient balance for cooldown");

        uint256 cooldownEnd = block.timestamp + cooldownDuration;
        uint256 windowEnd = cooldownEnd + withdrawalWindow;

        cooldowns[msg.sender] =
            UserCooldown({cooldownEnd: uint64(cooldownEnd), windowEnd: uint64(windowEnd), shares: uint128(_shares)});

        emit CooldownStarted(msg.sender, _shares, cooldownEnd, windowEnd);
    }

    /// @notice Clear the caller's pending cooldown record entirely.
    function cancelCooldown() external {
        require(cooldowns[msg.sender].shares > 0, "No active cooldown");
        delete cooldowns[msg.sender];
        emit CooldownCancelled(msg.sender);
    }

    /// @notice UI helper.
    function getCooldownStatus(address _user)
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares)
    {
        UserCooldown memory cooldown = cooldowns[_user];
        return (cooldown.cooldownEnd, cooldown.windowEnd, cooldown.shares);
    }

    /*//////////////////////////////////////////////////////////////
                          BASE-HOOK OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev Meter the flow through the base Hook surface first, then consume the
    ///      cooled bucket by the shares actually burned (BaseHooks passes the
    ///      burned `_shares`).
    function _postWithdrawHook(uint256 _assets, uint256 _shares, address _receiver, address _owner, uint256 _maxLoss)
        internal
        override
    {
        super._postWithdrawHook(_assets, _shares, _receiver, _owner, _maxLoss);

        UserCooldown storage cooldown = cooldowns[_owner];

        if (cooldown.shares == 0) return;

        if (_shares >= cooldown.shares) {
            delete cooldowns[_owner];
        } else {
            cooldown.shares -= uint128(_shares);
        }
    }

    /// @dev Block transferring shares that are sitting in an active cooldown.
    function _preTransferHook(address _from, address _to, uint256 _amount) internal view override {
        if (_from == address(0) || _to == address(0)) {
            return;
        }

        if (cooldownDuration == 0 || TokenizedStrategy.isShutdown()) {
            return;
        }

        UserCooldown memory cooldown = cooldowns[_from];
        if (cooldown.shares == 0) {
            return;
        }

        uint256 userBalance = TokenizedStrategy.balanceOf(_from);
        uint256 nonCooldownShares = userBalance > cooldown.shares ? userBalance - cooldown.shares : 0;

        require(_amount <= nonCooldownShares, "Cannot transfer shares in cooldown");
    }
}
