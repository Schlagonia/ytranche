// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {TrancheController} from "../../../TrancheController.sol";
import {Hook} from "../../../Hook.sol";
import {ILockedTrancheStrategy} from "../../../interfaces/ITrancheStrategy.sol";
import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice Revert-safe action surface for the stateful invariant suite. Every
///         action bounds its inputs and is a no-op when its preconditions fail,
///         so the suite can run with `fail_on_revert = true`.
contract TrancheHandler is Test {
    struct Refs {
        TrancheController controller;
        Hook hook;
        MockERC20 asset;
        IStrategy riskyStrategy;
        IVault mainVault;
        address keeper;
        address management;
        address aTranche; // atomic (senior)
        address bTranche; // locked (junior)
        address eTranche; // locked (equity)
    }

    TrancheController public immutable controller;
    Hook public immutable hook;
    MockERC20 public immutable asset;
    IStrategy public immutable riskyStrategy;
    IVault public immutable mainVault;
    address public immutable keeper;
    address public immutable management;
    address public immutable aTranche;
    address public immutable bTranche;
    address public immutable eTranche;

    address[] public actors;
    address internal currentActor;

    // Deposits/PnL kept in a sane band: large enough to avoid dust (which would
    // make the vault round share mints/redeems to zero and revert — a test
    // artifact, not a protocol bug) and small enough to stay clear of overflow.
    uint256 internal constant MIN_DEPOSIT = 1e18;
    uint256 internal constant MAX_DEPOSIT = 1_000_000e18;
    uint256 internal constant MIN_REDEEM = 1e9; // skip dust redemptions
    uint256 internal constant MAX_PNL = 100_000e18;

    // -------- ghost accounting --------
    uint256 public ghost_principalIn; // Σ assets deposited
    uint256 public ghost_principalOut; // Σ assets actually delivered (received)
    uint256 public ghost_redemptionLoss; // Σ (nominal claim debited − received)
    uint256 public ghost_reserveFunded; // Σ fundReserve
    uint256 public ghost_processedProfit; // Σ profit folded into the vault
    uint256 public ghost_processedLoss; // Σ |loss| folded into the vault
    uint256 public ghost_unprocessedProfit; // recorded at strategy level, not yet folded
    uint256 public ghost_unprocessedLoss; // recorded at strategy level, not yet folded

    // True iff the most recent action was settle() (for the post-settle invariant).
    bool public lastCallWasSettle;

    mapping(bytes32 => uint256) public calls;

    constructor(Refs memory r, address[] memory actors_) {
        controller = r.controller;
        hook = r.hook;
        asset = r.asset;
        riskyStrategy = r.riskyStrategy;
        mainVault = r.mainVault;
        keeper = r.keeper;
        management = r.management;
        aTranche = r.aTranche;
        bTranche = r.bTranche;
        eTranche = r.eTranche;
        actors = actors_;
    }

    modifier useActor(uint256 seed) {
        currentActor = actors[bound(seed, 0, actors.length - 1)];
        _;
    }

    modifier track(bytes32 name, bool isSettle) {
        calls[name]++;
        lastCallWasSettle = isSettle;
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function depositA(uint256 actorSeed, uint256 amtSeed) external useActor(actorSeed) track("depositA", false) {
        _deposit(aTranche, amtSeed);
    }

    function depositB(uint256 actorSeed, uint256 amtSeed) external useActor(actorSeed) track("depositB", false) {
        _deposit(bTranche, amtSeed);
    }

    function depositE(uint256 actorSeed, uint256 amtSeed) external useActor(actorSeed) track("depositE", false) {
        _deposit(eTranche, amtSeed);
    }

    function _deposit(address tranche, uint256 amtSeed) internal {
        uint256 cap = hook.depositCap(tranche);
        uint256 ceil = cap < MAX_DEPOSIT ? cap : MAX_DEPOSIT;
        if (ceil < MIN_DEPOSIT) return;
        uint256 amt = bound(amtSeed, MIN_DEPOSIT, ceil);
        // Skip if any mint leg (tranche shares or the main-vault shares the deposit
        // routes into) would round to zero at the current PPS — a dust artifact.
        if (IStrategy(tranche).previewDeposit(amt) == 0) return;
        if (mainVault.previewDeposit(amt) == 0) return;
        if (riskyStrategy.previewDeposit(amt) == 0) return; // vault auto-allocates here

        asset.mint(currentActor, amt);
        vm.startPrank(currentActor);
        asset.approve(tranche, amt);
        IStrategy(tranche).deposit(amt, currentActor);
        vm.stopPrank();
        ghost_principalIn += amt;
    }

    /*//////////////////////////////////////////////////////////////
                              WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    function withdrawA(uint256 actorSeed, uint256 shareSeed) external useActor(actorSeed) track("withdrawA", false) {
        _redeem(aTranche, shareSeed);
    }

    // maxRedeem on the locked tranches already encodes cooldown maturity, so this
    // only frees a bucket that is inside its withdrawal window.
    function redeemIfMatureB(uint256 actorSeed, uint256 shareSeed)
        external
        useActor(actorSeed)
        track("redeemIfMatureB", false)
    {
        _redeem(bTranche, shareSeed);
    }

    function redeemIfMatureE(uint256 actorSeed, uint256 shareSeed)
        external
        useActor(actorSeed)
        track("redeemIfMatureE", false)
    {
        _redeem(eTranche, shareSeed);
    }

    function _redeem(address tranche, uint256 shareSeed) internal {
        uint256 maxShares = IStrategy(tranche).maxRedeem(currentActor);
        if (maxShares == 0) return;
        uint256 s = bound(shareSeed, 1, maxShares);

        uint256 nominal = IStrategy(tranche).previewRedeem(s);
        if (nominal < MIN_REDEEM) return; // skip dust redemptions (would round to 0)
        vm.prank(currentActor);
        uint256 received = IStrategy(tranche).redeem(s, currentActor, currentActor);

        ghost_principalOut += received;
        if (nominal > received) ghost_redemptionLoss += (nominal - received);
    }

    /*//////////////////////////////////////////////////////////////
                                COOLDOWN
    //////////////////////////////////////////////////////////////*/

    function startCooldownB(uint256 actorSeed, uint256 shareSeed)
        external
        useActor(actorSeed)
        track("startCooldownB", false)
    {
        _startCooldown(bTranche, shareSeed);
    }

    function startCooldownE(uint256 actorSeed, uint256 shareSeed)
        external
        useActor(actorSeed)
        track("startCooldownE", false)
    {
        _startCooldown(eTranche, shareSeed);
    }

    function _startCooldown(address tranche, uint256 shareSeed) internal {
        uint256 bal = IStrategy(tranche).balanceOf(currentActor);
        if (bal == 0) return; // startCooldown(0) reverts; zero balance is a no-op
        uint256 s = bound(shareSeed, 1, bal);
        vm.prank(currentActor);
        ILockedTrancheStrategy(tranche).startCooldown(s);
    }

    function cancelCooldownB(uint256 actorSeed) external useActor(actorSeed) track("cancelCooldownB", false) {
        _cancelCooldown(bTranche);
    }

    function cancelCooldownE(uint256 actorSeed) external useActor(actorSeed) track("cancelCooldownE", false) {
        _cancelCooldown(eTranche);
    }

    function _cancelCooldown(address tranche) internal {
        (,, uint256 shares) = ILockedTrancheStrategy(tranche).getCooldownStatus(currentActor);
        if (shares == 0) return;
        vm.prank(currentActor);
        ILockedTrancheStrategy(tranche).cancelCooldown();
    }

    // A cooled-share transfer is *expected* to revert; the catch keeps the action
    // revert-safe. The strict assertion lives in a deterministic scenario test.
    function transferAttemptB(uint256 actorSeed, uint256 toSeed, uint256 shareSeed)
        external
        useActor(actorSeed)
        track("transferAttemptB", false)
    {
        _transferAttempt(bTranche, toSeed, shareSeed);
    }

    function transferAttemptE(uint256 actorSeed, uint256 toSeed, uint256 shareSeed)
        external
        useActor(actorSeed)
        track("transferAttemptE", false)
    {
        _transferAttempt(eTranche, toSeed, shareSeed);
    }

    function _transferAttempt(address tranche, uint256 toSeed, uint256 shareSeed) internal {
        uint256 bal = IStrategy(tranche).balanceOf(currentActor);
        if (bal == 0) return;
        uint256 s = bound(shareSeed, 1, bal);
        address to = actors[bound(toSeed, 0, actors.length - 1)];
        if (to == currentActor) return;
        vm.prank(currentActor);
        try IStrategy(tranche).transfer(to, s) {} catch {}
    }

    /*//////////////////////////////////////////////////////////////
                                TIME / PnL
    //////////////////////////////////////////////////////////////*/

    function warp(uint256 timeSeed) external track("warp", false) {
        vm.warp(block.timestamp + bound(timeSeed, 0, 30 days));
    }

    function injectProfit(uint256 amtSeed) external track("injectProfit", false) {
        uint256 va = controller.vaultAssets();
        if (va < MIN_DEPOSIT) return; // no profit on a dust/empty vault
        uint256 ceil = va / 100 < MAX_PNL ? va / 100 : MAX_PNL; // <= 1%/call keeps PPS near 1
        uint256 amt = bound(amtSeed, 0, ceil);
        if (amt == 0) return;
        asset.mint(address(riskyStrategy), amt);
        vm.prank(keeper);
        riskyStrategy.report();
        vm.prank(keeper);
        mainVault.process_report(address(riskyStrategy));
        ghost_processedProfit += amt;
        _foldUnprocessed();
    }

    function injectLoss(uint256 amtSeed) external track("injectLoss", false) {
        uint256 bal = asset.balanceOf(address(riskyStrategy));
        if (bal == 0) return;
        uint256 amt = bound(amtSeed, 0, bal / 10); // <= 10%/call keeps PPS near 1
        if (amt == 0) return;
        asset.burn(address(riskyStrategy), amt);
        vm.prank(keeper);
        riskyStrategy.report();
        vm.prank(keeper);
        mainVault.process_report(address(riskyStrategy));
        ghost_processedLoss += amt;
        _foldUnprocessed();
    }

    // Strategy-level markdown WITHOUT process_report: the vault does not yet
    // reflect the loss (the undercollateralized window).
    function injectUnsettledLoss(uint256 amtSeed) external track("injectUnsettledLoss", false) {
        uint256 bal = asset.balanceOf(address(riskyStrategy));
        if (bal == 0) return;
        uint256 amt = bound(amtSeed, 0, bal / 10); // <= 10%/call keeps PPS near 1
        if (amt == 0) return;
        asset.burn(address(riskyStrategy), amt);
        vm.prank(keeper);
        riskyStrategy.report();
        ghost_unprocessedLoss += amt;
    }

    // The ONLY call that folds risky-strategy PnL into vault accounting.
    function processVaultReport() external track("processVaultReport", false) {
        vm.prank(keeper);
        mainVault.process_report(address(riskyStrategy));
        _foldUnprocessed();
    }

    function _foldUnprocessed() internal {
        ghost_processedProfit += ghost_unprocessedProfit;
        ghost_processedLoss += ghost_unprocessedLoss;
        ghost_unprocessedProfit = 0;
        ghost_unprocessedLoss = 0;
    }

    /*//////////////////////////////////////////////////////////////
                            RESERVE / SETTLE / REPORT
    //////////////////////////////////////////////////////////////*/

    function fundReserve(uint256 amtSeed) external track("fundReserve", false) {
        uint256 amt = bound(amtSeed, MIN_DEPOSIT, MAX_PNL); // no dust reserves
        asset.mint(address(this), amt);
        asset.approve(address(controller), amt);
        controller.fundReserve(amt);
        ghost_reserveFunded += amt;
    }

    function settle() external track("settle", true) {
        vm.prank(keeper);
        try controller.settle() {}
        catch Error(string memory reason) {
            // Tolerate ONLY the trusted vault's dust-rounding revert, where settle
            // redeposits a sub-one-share reserve amount into a PPS-above-1 vault
            // ("ZERO_SHARES"). This is a vault rounding artifact at dust scale,
            // not a protocol bug; re-revert anything else so fail_on_revert still
            // catches real settle failures.
            require(keccak256(bytes(reason)) == keccak256("ZERO_SHARES"), reason);
            lastCallWasSettle = false; // settle did not complete; skip post-settle checks
        }
    }

    // The handler is set as each tranche's strategy-management in the test setUp,
    // so it can disable the health check around the large, expected settlement
    // swings (the check auto-re-enables after every report).
    function reportTranches() external track("reportTranches", false) {
        address[3] memory ts = [aTranche, bTranche, eTranche];
        for (uint256 i; i < 3; ++i) {
            IBaseHealthCheck(ts[i]).setDoHealthCheck(false);
            vm.prank(keeper);
            IStrategy(ts[i]).report();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}
