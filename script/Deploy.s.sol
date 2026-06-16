// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import {TrancheStrategy} from "../src/TrancheStrategy.sol";
import {LockedTrancheStrategy} from "../src/LockedTrancheStrategy.sol";
import {TrancheController} from "../src/TrancheController.sol";
import {Hook} from "../src/Hook.sol";
import {Authorizer} from "../src/periphery/Authorizer.sol";
import {EmergencyAdmin} from "../src/periphery/EmergencyAdmin.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

/// @notice One-shot deploy script.
///
///   - A: `TrancheStrategy`        — atomic
///   - B: `LockedTrancheStrategy`  — cooldown 14d, withdrawal window 7d
///   - E: `LockedTrancheStrategy`  — equity Tranche, same cooldown shape as B
///   - reserveVault: any same-asset 4626 (e.g. Spark sUSDS, Yearn yvUSDC)
contract DeployTrancheSystem is Script {
    // Mirrors BaseStrategy.tokenizedStrategyAddress in the constant_accual branch.
    address internal constant TOKENIZED_STRATEGY_ADDRESS = 0x2e234DAe75C793f67A35089C9d99245E1C58470b;

    function run() external {
        address asset = vm.envAddress("ASSET");
        address mainVault = vm.envAddress("MAIN_VAULT");
        address reserveVault = vm.envAddress("RESERVE_VAULT");
        address gov = vm.envAddress("GOV");
        address management = vm.envAddress("MANAGEMENT");
        address keeper = vm.envAddress("KEEPER");
        require(TOKENIZED_STRATEGY_ADDRESS.code.length != 0, "TOKENIZED_STRATEGY_NOT_DEPLOYED");

        vm.startBroadcast();

        // Authorizer owns all access control; controller is hook-agnostic, so
        // no address prediction is needed: Authorizer → Controller → Hook →
        // Tranches.
        Authorizer authorizer = new Authorizer(gov, management);
        TrancheController controller = new TrancheController(asset, mainVault, address(authorizer));
        Hook hook = new Hook(address(authorizer), address(controller));
        EmergencyAdmin emergencyAdmin = new EmergencyAdmin(address(authorizer));

        // Set the reserve vault. Grant KEEPER from the management address after
        // deployment if the broadcaster is not also management.
        controller.setReserveVault(reserveVault);

        TrancheStrategy aTranche = new TrancheStrategy(asset, "Tranche A", address(controller), address(hook));
        LockedTrancheStrategy bTranche =
            new LockedTrancheStrategy(asset, "Tranche B", address(controller), address(hook), 14 days, 7 days);
        LockedTrancheStrategy eTranche =
            new LockedTrancheStrategy(asset, "Tranche E", address(controller), address(hook), 14 days, 7 days);

        // Per-Tranche economic config (annualised target BPS, excess-share BPS)
        // is supplied at registration time. Numbers mirror the test defaults.
        controller.registerTranche(address(aTranche), 425, 0); // A: 4.25% target, 0% excess
        controller.registerTranche(address(bTranche), 425, 4000); // B: 4.25% target, 40% excess
        controller.registerTranche(address(eTranche), 0, 6000); // E: 0% target, 60% excess

        IStrategy(address(aTranche)).setProfitMaxUnlockTime(0);
        IStrategy(address(aTranche)).setPerformanceFee(0);
        IStrategy(address(aTranche)).setKeeper(keeper);
        IStrategy(address(aTranche)).setEmergencyAdmin(address(emergencyAdmin));

        IStrategy(address(bTranche)).setProfitMaxUnlockTime(0);
        IStrategy(address(bTranche)).setPerformanceFee(0);
        IStrategy(address(bTranche)).setKeeper(keeper);
        IStrategy(address(bTranche)).setEmergencyAdmin(address(emergencyAdmin));

        IStrategy(address(eTranche)).setProfitMaxUnlockTime(0);
        IStrategy(address(eTranche)).setPerformanceFee(0);
        IStrategy(address(eTranche)).setKeeper(keeper);
        IStrategy(address(eTranche)).setEmergencyAdmin(address(emergencyAdmin));

        vm.stopBroadcast();

        console.log("TokenizedStrategy:       ", TOKENIZED_STRATEGY_ADDRESS);
        console.log("Hook:                    ", address(hook));
        console.log("EmergencyAdmin:          ", address(emergencyAdmin));
        console.log("TrancheController:        ", address(controller));
        console.log("TrancheStrategy A:        ", address(aTranche));
        console.log("LockedTrancheStrategy B:  ", address(bTranche));
        console.log("LockedTrancheStrategy E:  ", address(eTranche));
        console.log("");
        console.log("Operator follow-ups on the Yearn V3 main vault:");
        console.log(" - add risky strategies, set max debt, set default queue");
        console.log(" - set_auto_allocate(true)");
        console.log(" - set_minimum_total_idle(0)");
        console.log(" - set_deposit_hook(hook)");
        console.log(" - set_withdraw_hook(hook)");
        console.log(" - authorizer.grantRole(KEEPER_ROLE, keeper) from MANAGEMENT");
        console.log(" - set_role(emergencyAdmin, EMERGENCY_MANAGER | MAX_DEBT_MANAGER)");
        console.log("   // lets EmergencyAdmin pause/shutdown the vault and zero strategy max debt");
    }
}
