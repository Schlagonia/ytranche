// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";

import {TrancheFactory} from "../TrancheFactory.sol";
import {TrancheStrategy} from "../TrancheStrategy.sol";
import {LockedTrancheStrategy} from "../LockedTrancheStrategy.sol";
import {ITrancheStrategy, ILockedTrancheStrategy} from "../interfaces/ITrancheStrategy.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

contract TrancheFactoryTest is Setup {
    TrancheFactory public trancheFactory;

    event NewTrancheStrategy(
        address indexed tranche,
        address indexed asset,
        address indexed controller,
        address hook,
        address governance,
        string symbol
    );
    event NewLockedTrancheStrategy(
        address indexed tranche,
        address indexed asset,
        address indexed controller,
        address hook,
        address governance,
        string symbol,
        uint256 cooldownDuration,
        uint256 withdrawalWindow
    );

    function setUp() public override {
        super.setUp();

        trancheFactory = new TrancheFactory(management, treasury, keeper, address(emergencyAdmin), governance);
    }

    function test_setHookIsGovernanceGated() public {
        address newHook = address(0xF00);

        vm.prank(management);
        vm.expectRevert(bytes("!governance"));
        ITrancheStrategy(address(aTranche)).setHook(newHook);

        vm.prank(governance);
        ITrancheStrategy(address(aTranche)).setHook(newHook);
        assertEq(ITrancheStrategy(address(aTranche)).hook(), newHook, "A hook rotated");
    }

    function test_lockedSetHookIsGovernanceGated() public {
        address newHook = address(0xF00);

        vm.prank(management);
        vm.expectRevert(bytes("!governance"));
        ITrancheStrategy(address(bTranche)).setHook(newHook);

        vm.prank(governance);
        ITrancheStrategy(address(bTranche)).setHook(newHook);
        assertEq(ITrancheStrategy(address(bTranche)).hook(), newHook, "B hook rotated");
    }

    function test_trancheFactoryDeploysAndConfiguresStrategy() public {
        address deployed = trancheFactory.newTrancheStrategy(
            address(asset), "Factory Tranche", "FT", address(controller), address(hook)
        );
        ITrancheStrategy tranche = ITrancheStrategy(deployed);

        assertEq(trancheFactory.performanceFeeRecipient(), treasury, "factory fee recipient");
        assertEq(tranche.asset(), address(asset), "asset");
        assertEq(tranche.symbol(), "FT", "symbol");
        assertEq(tranche.hook(), address(hook), "hook");
        assertEq(tranche.keeper(), keeper, "keeper");
        assertEq(tranche.emergencyAdmin(), address(emergencyAdmin), "emergency admin");
        assertEq(tranche.pendingManagement(), management, "pending management");
        assertTrue(trancheFactory.isDeployedTranche(deployed), "tracked deployment");

        vm.prank(management);
        tranche.acceptManagement();
        assertEq(tranche.management(), management, "management accepted");
    }

    function test_lockedTrancheFactoryDeploysAndConfiguresStrategy() public {
        address deployed = trancheFactory.newLockedTrancheStrategy(
            address(asset), "Factory Locked Tranche", "FLT", address(controller), address(hook), 14 days, 7 days
        );
        ILockedTrancheStrategy tranche = ILockedTrancheStrategy(deployed);

        assertEq(trancheFactory.performanceFeeRecipient(), treasury, "factory fee recipient");
        assertEq(tranche.asset(), address(asset), "asset");
        assertEq(tranche.symbol(), "FLT", "symbol");
        assertEq(tranche.hook(), address(hook), "hook");
        assertEq(tranche.cooldownDuration(), 14 days, "cooldown");
        assertEq(tranche.withdrawalWindow(), 7 days, "window");
        assertEq(tranche.keeper(), keeper, "keeper");
        assertEq(tranche.emergencyAdmin(), address(emergencyAdmin), "emergency admin");
        assertEq(tranche.pendingManagement(), management, "pending management");
        assertTrue(trancheFactory.isDeployedLockedTranche(deployed), "tracked deployment");

        vm.prank(management);
        tranche.acceptManagement();
        assertEq(tranche.management(), management, "management accepted");
    }

    function test_factoryAddressUpdatesAreManagementGated() public {
        vm.prank(alice);
        vm.expectRevert(bytes("!management"));
        trancheFactory.setAddresses(alice, bob, carol);

        vm.prank(management);
        trancheFactory.setAddresses(alice, bob, carol);
        assertEq(trancheFactory.management(), alice, "management");
        assertEq(trancheFactory.performanceFeeRecipient(), bob, "fee recipient");
        assertEq(trancheFactory.keeper(), carol, "keeper");
    }

    /*//////////////////////////////////////////////////////////////
                    §6 — FACTORY / KEEPER GAP COVERAGE
    //////////////////////////////////////////////////////////////*/

    /// §6.1 — full post-deploy wiring (a factory tranche is NOT ready out of the box)
    /// then a deposit -> settle -> report -> redeem round trip.
    function test_factory_deployRegisterAcceptConfigureOperate() public {
        address deployed = trancheFactory.newTrancheStrategy(
            address(asset), "Factory Tranche", "FT", address(controller), address(hook)
        );
        ITrancheStrategy t = ITrancheStrategy(deployed);

        // 1. register with excessShareBps = 0 (A/B/E already sum to MAX_BPS).
        //    Must happen before any strategy op that reads totalAssets, since the
        //    strategy's totalAssets routes to controller.liveAssets (which reverts
        //    "!tranche" until registered).
        vm.prank(governance);
        controller.registerTranche(deployed, 0, 0);
        assertTrue(controller.isTranche(deployed), "registered");

        // 2. accept management (factory only set it pending)
        vm.prank(management);
        t.acceptManagement();
        assertEq(t.management(), management, "management accepted");

        // 3. open + configure (gated by the strategy's management)
        vm.startPrank(management);
        t.setProfitMaxUnlockTime(0);
        t.setPerformanceFee(0);
        t.setKeeper(keeper);
        t.setOpen(true);
        t.setProfitLimitRatio(type(uint16).max);
        t.setLossLimitRatio(uint16(MAX_BPS - 1));
        vm.stopPrank();

        // 4. lift the Hook limits for the new tranche
        vm.startPrank(management);
        hook.setDepositLimit(deployed, type(uint256).max);
        hook.setDepositRateLimit(deployed, type(uint128).max);
        hook.setWithdrawRateLimit(deployed, type(uint128).max);
        vm.stopPrank();

        // 5. operate
        uint256 amt = 100e18;
        _airdrop(alice, amt);
        vm.startPrank(alice);
        asset.approve(deployed, amt);
        uint256 shares = IStrategy(deployed).deposit(amt, alice);
        vm.stopPrank();
        assertGt(shares, 0, "minted shares");

        vm.prank(keeper);
        controller.settle();
        vm.prank(management);
        t.setDoHealthCheck(false);
        vm.prank(keeper);
        IStrategy(deployed).report();

        vm.prank(alice);
        uint256 got = IStrategy(deployed).redeem(shares, alice, alice);
        assertApproxEqAbs(got, amt, 1e12, "round trip");
    }

    /// §6.2 — the factory's immutable GOVERNANCE propagates to both strategy types.
    function test_factory_governanceImmutablePropagates() public {
        address atomic =
            trancheFactory.newTrancheStrategy(address(asset), "FA", "FA", address(controller), address(hook));
        address locked = trancheFactory.newLockedTrancheStrategy(
            address(asset), "FL", "FL", address(controller), address(hook), 14 days, 7 days
        );
        assertEq(TrancheStrategy(atomic).GOVERNANCE(), governance, "atomic governance");
        assertEq(LockedTrancheStrategy(locked).GOVERNANCE(), governance, "locked governance");
        assertEq(trancheFactory.GOVERNANCE(), governance, "factory governance immutable");
    }

    /// §6.3 — setAddresses changes apply to FUTURE deployments only, and the old
    /// management loses the power once it transfers it.
    function test_factory_setAddresses_futureScopeAndPowerTransfer() public {
        address s1 = trancheFactory.newTrancheStrategy(address(asset), "S1", "S1", address(controller), address(hook));

        vm.prank(management);
        trancheFactory.setAddresses(alice, bob, carol); // management -> alice, keeper -> carol

        address s2 = trancheFactory.newTrancheStrategy(address(asset), "S2", "S2", address(controller), address(hook));

        // S1 keeps the old keeper / pending-management; S2 picks up the new ones.
        assertEq(ITrancheStrategy(s1).keeper(), keeper, "S1 old keeper");
        assertEq(ITrancheStrategy(s1).pendingManagement(), management, "S1 old pending mgmt");
        assertEq(ITrancheStrategy(s2).keeper(), carol, "S2 new keeper");
        assertEq(ITrancheStrategy(s2).pendingManagement(), alice, "S2 new pending mgmt");

        // Old management can no longer call setAddresses.
        vm.prank(management);
        vm.expectRevert(bytes("!management"));
        trancheFactory.setAddresses(management, treasury, keeper);
    }

    /// §6.4 — KNOWN GAP: the factory stores performanceFeeRecipient but never applies
    /// it to deployed strategies (`_configureStrategy` does not call
    /// setPerformanceFeeRecipient). This locks the CURRENT behavior; if the intended
    /// behavior is to propagate it, change the factory and flip this assertion.
    function test_factory_performanceFeeRecipientNotApplied() public {
        address deployed =
            trancheFactory.newTrancheStrategy(address(asset), "FF", "FF", address(controller), address(hook));
        assertEq(trancheFactory.performanceFeeRecipient(), treasury, "factory stores it");
        assertTrue(
            IStrategy(deployed).performanceFeeRecipient() != treasury,
            "GAP: factory fee recipient not propagated to strategy"
        );
    }

    /// §6.6 — deployment tracking mappings are set per type (and not the other).
    function test_factory_deploymentMappings() public {
        address atomic =
            trancheFactory.newTrancheStrategy(address(asset), "A1", "A1", address(controller), address(hook));
        assertTrue(trancheFactory.isDeployedTranche(atomic), "atomic tracked");
        assertFalse(trancheFactory.isDeployedLockedTranche(atomic), "atomic not flagged locked");

        address locked = trancheFactory.newLockedTrancheStrategy(
            address(asset), "L1", "L1", address(controller), address(hook), 14 days, 7 days
        );
        assertTrue(trancheFactory.isDeployedLockedTranche(locked), "locked tracked");
        assertFalse(trancheFactory.isDeployedTranche(locked), "locked not flagged atomic");
    }

    /// §6.6 — both deploy paths emit their events with the right args (the tranche
    /// address is unknown pre-deploy, so topic1 is not checked).
    function test_factory_emitsEvents() public {
        vm.expectEmit(false, true, true, true);
        emit NewTrancheStrategy(address(0), address(asset), address(controller), address(hook), governance, "A1");
        trancheFactory.newTrancheStrategy(address(asset), "A1", "A1", address(controller), address(hook));

        vm.expectEmit(false, true, true, true);
        emit NewLockedTrancheStrategy(
            address(0), address(asset), address(controller), address(hook), governance, "L1", 14 days, 7 days
        );
        trancheFactory.newLockedTrancheStrategy(
            address(asset), "L1", "L1", address(controller), address(hook), 14 days, 7 days
        );
    }

    /// §6.5 — locked constructor bounds propagate through the factory.
    function test_factory_lockedBoundsEnforced() public {
        vm.expectRevert(bytes("cooldown too long"));
        trancheFactory.newLockedTrancheStrategy(
            address(asset), "TooLong", "TL", address(controller), address(hook), 31 days, 7 days
        );

        vm.expectRevert(bytes("window too short"));
        trancheFactory.newLockedTrancheStrategy(
            address(asset), "TooShort", "TS", address(controller), address(hook), 14 days, 1 days - 1
        );
    }
}
