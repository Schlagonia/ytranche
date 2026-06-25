// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";
import {TrancheStrategy} from "../TrancheStrategy.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

/// @notice Positional Tranche registration (insert-in-middle) and deprecation
///   via zeroed rates. Default order from Setup is [A, B, E].
contract TrancheRegistryTest is Setup {
    /// @dev Deploy only — configuration that triggers accrual must wait until
    ///      after the Tranche is registered (else `liveAssets` reverts).
    function _newTranche(string memory _name) internal returns (TrancheStrategy t) {
        t = new TrancheStrategy(address(asset), _name, _name, address(controller), address(hook), governance);
    }

    function _deposit(address _tranche, address _user, uint256 _amt) internal {
        _airdrop(_user, _amt);
        vm.startPrank(_user);
        asset.approve(_tranche, _amt);
        ITrancheStrategy(_tranche).deposit(_amt, _user);
        vm.stopPrank();
    }

    function test_registerTrancheAt_insertsInMiddle() public {
        TrancheStrategy c = _newTranche("Tranche C");
        vm.prank(governance);
        controller.registerTrancheAt(address(c), 0, 0, 1);

        address[] memory order = controller.getTranchesByPriority();
        assertEq(order.length, 4, "length");
        assertEq(order[0], address(aTranche), "A still senior");
        assertEq(order[1], address(c), "C inserted at 1");
        assertEq(order[2], address(bTranche), "B shifted down");
        assertEq(order[3], address(eTranche), "E shifted down");
        assertTrue(controller.isTranche(address(c)));
    }

    function test_registerTranche_appendsAtEnd() public {
        TrancheStrategy c = _newTranche("Tranche C");
        vm.prank(governance);
        controller.registerTranche(address(c), 0, 0);

        address[] memory order = controller.getTranchesByPriority();
        assertEq(order.length, 4);
        assertEq(order[3], address(c), "appended last");
    }

    function test_registerTrancheAt_badIndexReverts() public {
        TrancheStrategy c = _newTranche("Tranche C");
        vm.prank(governance);
        vm.expectRevert(bytes("bad index"));
        controller.registerTrancheAt(address(c), 0, 0, 5);
    }

    function test_registerTrancheAt_excessGuard() public {
        TrancheStrategy c = _newTranche("Tranche C");
        // A(0) + B(40%) + E(60%) already sums to MAX_BPS — any positive excess reverts.
        vm.prank(governance);
        vm.expectRevert(bytes("excess > MAX_BPS"));
        controller.registerTrancheAt(address(c), 0, 1, 1);
    }

    /// @dev Loss waterfall must honor the inserted Tranche's priority: order
    ///      [A, C, B, E] absorbs junior-first E -> B -> C -> A.
    function test_insertedTranche_honorsWaterfallOrder() public {
        TrancheStrategy c = _newTranche("Tranche C");
        vm.prank(governance);
        controller.registerTrancheAt(address(c), 0, 0, 1); // [A, C, B, E]
        _configureVault(address(c));
        _configureTranche(address(c));

        _depositA(alice, 70e18);
        _deposit(address(c), bob, 10e18);
        _depositB(carol, 20e18);
        // No E deposit / no reserve / no time skip: totalClaim = 100.

        _simulateRiskyPnL(-int256(35e18));
        _settle();

        // E(0) -> B(20) -> C(10) -> A(5) absorb the 35 loss.
        assertEq(controller.liveAssets(address(bTranche)), 0, "B wiped first");
        assertEq(controller.liveAssets(address(c)), 0, "C wiped after B");
        assertApproxEqAbs(controller.liveAssets(address(aTranche)), 65e18, 1e15, "A haircut by the remainder");
        assertTrue(controller.isFrozen(address(bTranche)));
        assertTrue(controller.isFrozen(address(c)));
        assertTrue(controller.isFrozen(address(aTranche)));
    }

    /// @dev Deprecate a Tranche by zeroing its target + excess: it stops earning
    ///      but stays usable (holders can still withdraw their baseline).
    function test_deprecateViaZeroRates() public {
        vm.startPrank(governance);
        controller.setTrancheTargetBps(address(bTranche), 0);
        controller.setTrancheExcessShareBps(address(bTranche), 0);
        vm.stopPrank();

        _depositA(alice, 70e18);
        uint256 bShares = _depositB(bob, 20e18);
        skip(365 days);
        _simulateRiskyPnL(int256(10e18)); // profit
        _settle();

        // B accrues no target and is allocated no excess (normally it would
        // take 40% of the surplus).
        assertApproxEqAbs(controller.liveAssets(address(bTranche)), 20e18, 1e15, "B flat (no target)");
        assertEq(controller.pendingExcess(address(bTranche)), 0, "B no excess");

        // A still earns its target, proving the system is otherwise live.
        assertGt(controller.liveAssets(address(aTranche)), 70e18, "A still accruing");

        // B holder can still exit their baseline (B is locked — cooldown first).
        vm.prank(bob);
        bTranche.startCooldown(bShares);
        skip(14 days + 1);
        vm.prank(bob);
        ITrancheStrategy(address(bTranche)).redeem(bShares, bob, bob);
        assertApproxEqAbs(asset.balanceOf(bob), 20e18, 1e15, "B holder withdrew baseline");
    }
}
