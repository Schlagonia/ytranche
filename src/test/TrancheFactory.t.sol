// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";

import {TrancheFactory} from "../TrancheFactory.sol";
import {ITrancheStrategy, ILockedTrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

contract TrancheFactoryTest is Setup {
    TrancheFactory public trancheFactory;

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
        address deployed =
            trancheFactory.newTrancheStrategy(address(asset), "Factory Tranche", address(controller), address(hook));
        ITrancheStrategy tranche = ITrancheStrategy(deployed);

        assertEq(trancheFactory.performanceFeeRecipient(), treasury, "factory fee recipient");
        assertEq(tranche.asset(), address(asset), "asset");
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
            address(asset), "Factory Locked Tranche", address(controller), address(hook), 14 days, 7 days
        );
        ILockedTrancheStrategy tranche = ILockedTrancheStrategy(deployed);

        assertEq(trancheFactory.performanceFeeRecipient(), treasury, "factory fee recipient");
        assertEq(tranche.asset(), address(asset), "asset");
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
}
