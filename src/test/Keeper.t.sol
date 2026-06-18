// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";
import {Keeper as PeripheryKeeper} from "../periphery/Keeper.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

contract KeeperTest is Setup {
    PeripheryKeeper public batchKeeper;

    function setUp() public override {
        super.setUp();

        batchKeeper = new PeripheryKeeper(address(authorizer), address(controller));

        bytes32 keeperRole = authorizer.KEEPER_ROLE();
        vm.prank(management);
        authorizer.grantRole(keeperRole, address(batchKeeper));

        ITrancheStrategy(address(aTranche)).setKeeper(address(batchKeeper));
        ITrancheStrategy(address(bTranche)).setKeeper(address(batchKeeper));
        ITrancheStrategy(address(eTranche)).setKeeper(address(batchKeeper));
    }

    function test_settleAndReport_requiresKeeperRole() public {
        vm.prank(alice);
        vm.expectRevert(bytes("!authorized"));
        batchKeeper.settleAndReport();
    }

    function test_settleAndReport_allowsKeeperRoleHolder() public {
        bytes32 keeperRole = authorizer.KEEPER_ROLE();
        vm.prank(management);
        authorizer.grantRole(keeperRole, alice);

        vm.prank(alice);
        batchKeeper.settleAndReport();
    }

    function test_settleAndReport_settlesAndReportsEveryTranche() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _depositE(carol, 10e18);
        skip(SECONDS_PER_YEAR);
        _simulateRiskyPnL(int256(54e17));

        uint256 aLastReport = ITrancheStrategy(address(aTranche)).lastReport();
        uint256 bLastReport = ITrancheStrategy(address(bTranche)).lastReport();
        uint256 eLastReport = ITrancheStrategy(address(eTranche)).lastReport();

        vm.prank(keeper);
        batchKeeper.settleAndReport();

        assertEq(controller.pendingExcess(address(aTranche)), 0, "A pending");
        assertEq(controller.pendingExcess(address(bTranche)), 0, "B pending");
        assertEq(controller.pendingExcess(address(eTranche)), 0, "E pending");

        assertGt(ITrancheStrategy(address(aTranche)).lastReport(), aLastReport, "A reported");
        assertGt(ITrancheStrategy(address(bTranche)).lastReport(), bLastReport, "B reported");
        assertGt(ITrancheStrategy(address(eTranche)).lastReport(), eLastReport, "E reported");
    }
}
