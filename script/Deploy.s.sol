// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import {TrancheStrategy} from "../src/TrancheStrategy.sol";
import {LockedTrancheStrategy} from "../src/LockedTrancheStrategy.sol";
import {TrancheController} from "../src/TrancheController.sol";
import {Hook} from "../src/Hook.sol";
import {Authorizer} from "../src/periphery/Authorizer.sol";
import {EmergencyAdmin} from "../src/periphery/EmergencyAdmin.sol";
import {ITrancheStrategy} from "../src/interfaces/ITrancheStrategy.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles} from "@yearn-vaults/interfaces/Roles.sol";
import {Keeper} from "../src/periphery/Keeper.sol";

/// @notice One-shot deploy script.
///
///   - A: `TrancheStrategy`        — atomic
///   - B: `LockedTrancheStrategy`  — cooldown 14d, withdrawal window 7d
///   - E: `LockedTrancheStrategy`  — equity Tranche, same cooldown shape as B
///   - mainVault: deployed from Yearn Vault Factory v3.1.0
///   - reserveVault: any same-asset 4626 (e.g. Spark sUSDS, Yearn yvUSDC)
contract DeployTrancheSystem is Script {
    address internal constant VAULT_ORIGINAL_ADDRESS = 0xdD3FA86409658d207A9BE0141eE560C8db557824;
    address internal constant VAULT_FACTORY_ADDRESS = 0x310aC28ACF5E514abDbFF9Ab25e21f1bfe22bcAC;
    address internal constant TOKENIZED_STRATEGY_ADDRESS = 0x310f5Db015E9d6E542fd41bd4542640790791e76;
    uint256 internal constant MAX_BPS = 10_000;

    struct DeployConfig {
        address asset;
        address reserveVault;
        address gov;
        address management;
        address keeper;
        string vaultName;
        string vaultSymbol;
        uint256 vaultProfitMaxUnlockTime;
        address strategy;
    }

    struct Deployments {
        IVault mainVault;
        Authorizer authorizer;
        TrancheController controller;
        Hook hook;
        EmergencyAdmin emergencyAdmin;
        TrancheStrategy aTranche;
        LockedTrancheStrategy bTranche;
        LockedTrancheStrategy eTranche;
        Keeper keeper;
    }

    function run() external {
        DeployConfig memory config = _loadConfig();

        vm.startBroadcast();

        Deployments memory deployed = _deploy(config);

        vm.stopBroadcast();

        _log(deployed);
    }

    function _loadConfig() internal view returns (DeployConfig memory config) {
        config.asset;
        //config.reserveVault = vm.envAddress("RESERVE_VAULT");
        config.gov;
        config.management;
        config.vaultName = "USD yVault";
        config.vaultSymbol = "yvUSD";
        config.vaultProfitMaxUnlockTime = 2 days;
        config.strategy;
        config.keeper;
    }

    function _deploy(DeployConfig memory config) internal returns (Deployments memory deployed) {
        IVaultFactory vaultFactory = IVaultFactory(VAULT_FACTORY_ADDRESS);
        deployed.mainVault = IVault(
            vaultFactory.deploy_new_vault(
                config.asset, config.vaultName, config.vaultSymbol, config.gov, config.vaultProfitMaxUnlockTime
            )
        );

        // Authorizer owns all access control; controller is hook-agnostic, so
        // no address prediction is needed: Authorizer → Controller → Hook →
        // Tranches.
        deployed.authorizer = new Authorizer(config.gov, config.management);
        deployed.controller =
            new TrancheController(config.asset, address(deployed.mainVault), address(deployed.authorizer));
        deployed.hook = new Hook(address(deployed.authorizer), address(deployed.controller));
        deployed.emergencyAdmin = new EmergencyAdmin(address(deployed.authorizer));
        deployed.keeper = new Keeper(address(deployed.authorizer), address(deployed.controller));
        deployed.authorizer.grantRole(deployed.authorizer.KEEPER_ROLE(), address(deployed.keeper));
        if (config.keeper != address(0)) {
            deployed.authorizer.grantRole(deployed.authorizer.KEEPER_ROLE(), config.keeper);
        }

        deployed.mainVault.set_role(config.gov, Roles.ALL);
        deployed.mainVault.set_role(address(deployed.keeper), Roles.REPORTING_MANAGER | Roles.DEBT_MANAGER);
        deployed.mainVault.set_role(address(deployed.emergencyAdmin), Roles.EMERGENCY_MANAGER | Roles.MAX_DEBT_MANAGER);
        deployed.mainVault.set_deposit_limit(type(uint256).max);
        deployed.mainVault.set_deposit_hook(address(deployed.hook));
        deployed.mainVault.set_withdraw_hook(address(deployed.hook));
        deployed.mainVault.add_strategy(config.strategy);
        deployed.mainVault.update_max_debt_for_strategy(config.strategy, type(uint256).max);
        deployed.mainVault.set_auto_allocate(true);

        // Set the reserve vault. Grant KEEPER from the management address after
        // deployment if the broadcaster is not also management.
        // deployed.controller.setReserveVault(config.reserveVault);

        deployed.aTranche = new TrancheStrategy(
            config.asset,
            "Tranche A",
            "yvUSD-A",
            address(deployed.controller),
            address(deployed.hook),
            address(deployed.authorizer)
        );
        deployed.bTranche = new LockedTrancheStrategy(
            config.asset,
            "Tranche B",
            "yvUSD-B",
            address(deployed.controller),
            address(deployed.hook),
            address(deployed.authorizer),
            7 days,
            5 days
        );
        deployed.eTranche = new LockedTrancheStrategy(
            config.asset,
            "Tranche E",
            "yvUSD-E",
            address(deployed.controller),
            address(deployed.hook),
            address(deployed.authorizer),
            14 days,
            7 days
        );

        // Per-Tranche economic config (annualised target BPS, excess-share BPS)
        // is supplied at registration time. Numbers mirror the test defaults.
        deployed.controller.registerTranche(address(deployed.aTranche), 500, 0); // A: 5% target, 0% excess
        deployed.controller.registerTranche(address(deployed.bTranche), 500, 4000); // B: 5% target, 40% excess
        deployed.controller.registerTranche(address(deployed.eTranche), 0, 6000); // E: 0% target, 60% excess

        _configureTranche(address(deployed.aTranche), address(deployed.keeper), address(deployed.emergencyAdmin));
        _configureTranche(address(deployed.bTranche), address(deployed.keeper), address(deployed.emergencyAdmin));
        _configureTranche(address(deployed.eTranche), address(deployed.keeper), address(deployed.emergencyAdmin));

        _configureHook(
            deployed.hook,
            address(deployed.mainVault),
            address(deployed.aTranche),
            address(deployed.bTranche),
            address(deployed.eTranche)
        );
    }

    function _log(Deployments memory deployed) internal pure {
        console.log("Main Vault:              ", address(deployed.mainVault));
        console.log("Keeper:                  ", address(deployed.keeper));
        console.log("Hook:                    ", address(deployed.hook));
        console.log("EmergencyAdmin:          ", address(deployed.emergencyAdmin));
        console.log("TrancheController:        ", address(deployed.controller));
        console.log("TrancheStrategy A:        ", address(deployed.aTranche));
        console.log("LockedTrancheStrategy B:  ", address(deployed.bTranche));
        console.log("LockedTrancheStrategy E:  ", address(deployed.eTranche));
        console.log("");
        console.log("Operator follow-ups on the Yearn V3 main vault:");
        console.log(" - add risky strategies, set max debt, set default queue");
        console.log(" - set_auto_allocate(true)");
        console.log(" - authorizer.grantRole(KEEPER_ROLE, keeper) from MANAGEMENT");
    }

    function _configureHook(Hook hook, address mainVault, address aTranche, address bTranche, address eTranche)
        internal
    {
        hook.setDepositLimit(aTranche, type(uint256).max);
        hook.setDepositLimit(bTranche, type(uint256).max);
        hook.setDepositLimit(eTranche, type(uint256).max);
        hook.setDepositLimit(mainVault, type(uint256).max);
        hook.setDepositRateLimit(aTranche, type(uint128).max);
        hook.setDepositRateLimit(bTranche, type(uint128).max);
        hook.setDepositRateLimit(eTranche, type(uint128).max);
        hook.setDepositRateLimit(mainVault, type(uint128).max);
        hook.setWithdrawRateLimit(aTranche, type(uint128).max);
        hook.setWithdrawRateLimit(bTranche, type(uint128).max);
        hook.setWithdrawRateLimit(eTranche, type(uint128).max);
        hook.setWithdrawRateLimit(mainVault, type(uint128).max);
        //hook.setOpen(true);
    }

    function _configureTranche(address tranche, address keeper, address emergencyAdmin) internal {
        IStrategy s = IStrategy(tranche);
        s.setProfitMaxUnlockTime(2 days);
        s.setPerformanceFee(0);
        s.setKeeper(keeper);
        s.setEmergencyAdmin(emergencyAdmin);

        ITrancheStrategy t = ITrancheStrategy(tranche);
        t.setOpen(true);
    }

    function _sameString(string memory left, string memory right) internal pure returns (bool) {
        return keccak256(bytes(left)) == keccak256(bytes(right));
    }
}
