// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

/// @notice B (LockedTrancheStrategy) cooldown semantics — modelled after
///         the LockedVault reference: per-user `(cooldownEnd, windowEnd,
///         shares)` record, `startCooldown` overwrites, `cancelCooldown`
///         clears entirely, redemption only valid in `[end, end + window]`.
contract CooldownTest is Setup {
    function _start(address user, uint256 shares) internal {
        vm.prank(user);
        bTranche.startCooldown(shares);
    }

    function test_cooledShares_cannotTransfer() public {
        uint256 s = _depositB(alice, 20e18);
        _start(alice, s / 2);
        vm.prank(alice);
        ITrancheStrategy(address(bTranche)).transfer(bob, s / 2);
        assertEq(ITrancheStrategy(address(bTranche)).balanceOf(bob), s / 2);
        vm.prank(alice);
        vm.expectRevert(bytes("Cannot transfer shares in cooldown"));
        ITrancheStrategy(address(bTranche)).transfer(bob, 1);
    }

    function test_partialCooldown_onlyCooledRedeemable() public {
        _depositB(alice, 30e18);
        _fundReserve(1e18);
        _start(alice, 10e18);
        skip(14 days);
        vm.prank(alice);
        ITrancheStrategy(address(bTranche)).redeem(10e18, alice, alice);
        uint256 received = asset.balanceOf(alice);
        assertGt(received, 10e18, "received >= 10");
        assertLt(received, 10e18 + 5e16, "close to 10 + tiny target accrual");
        vm.prank(alice);
        vm.expectRevert();
        ITrancheStrategy(address(bTranche)).redeem(1, alice, alice);
    }

    function test_cancelCooldown_freesShares() public {
        uint256 s = _depositB(alice, 10e18);
        _start(alice, s);
        vm.prank(alice);
        bTranche.cancelCooldown();
        (,, uint256 cooled) = bTranche.getCooldownStatus(alice);
        assertEq(cooled, 0);
        vm.prank(alice);
        ITrancheStrategy(address(bTranche)).transfer(bob, s);
        assertEq(ITrancheStrategy(address(bTranche)).balanceOf(bob), s);
    }

    /// @dev Per the LockedVault reference, calling `startCooldown` again
    ///      OVERWRITES the prior record (does not extend / accumulate).
    function test_startCooldown_twice_overwrites() public {
        _depositB(alice, 20e18);
        _start(alice, 5e18);
        (,, uint256 cooledA) = bTranche.getCooldownStatus(alice);
        assertEq(cooledA, 5e18);
        skip(7 days);
        _start(alice, 12e18);
        (,, uint256 cooledB) = bTranche.getCooldownStatus(alice);
        assertEq(cooledB, 12e18, "overwritten, not added");
    }

    function test_cooldown_stillEconomicallyActive() public {
        _depositB(alice, 20e18);
        uint256 nav0 = controller.liveAssets(address(bTranche));
        _start(alice, ITrancheStrategy(address(bTranche)).balanceOf(alice));
        assertEq(controller.liveAssets(address(bTranche)), nav0, "nav unchanged on cooldown");
    }

    /// @dev After the withdrawal window closes the record is stale.
    function test_cooldown_staleAfterWindow() public {
        _depositB(alice, 20e18);
        _fundReserve(1e18);
        _start(alice, 20e18);
        skip(14 days + 7 days + 1);
        vm.prank(alice);
        vm.expectRevert();
        ITrancheStrategy(address(bTranche)).redeem(20e18, alice, alice);
    }

    function test_expiredCooldown_doesNotLockTransfers() public {
        uint256 shares = _depositB(alice, 20e18);
        _start(alice, shares);

        skip(14 days + 7 days + 1);

        assertEq(bTranche.availableWithdrawLimit(alice), 0, "expired cooldown cannot redeem");

        vm.prank(alice);
        ITrancheStrategy(address(bTranche)).transfer(bob, shares);

        assertEq(ITrancheStrategy(address(bTranche)).balanceOf(bob), shares, "expired cooldown no longer locks");
    }

    function test_cooldown_checkpoint_advancesBaseline() public {
        _depositB(alice, 20e18);
        skip(100 days);
        _start(alice, 1e18);
        // Live B NAV reflects the accrued target.
        assertGt(controller.liveAssets(address(bTranche)), 20e18, "B accrued live");
    }
}
