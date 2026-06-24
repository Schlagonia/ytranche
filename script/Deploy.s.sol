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
    }

    function run() external {
        DeployConfig memory config = _loadConfig();
        _validateYearnV31();

        vm.startBroadcast();

        Deployments memory deployed = _deploy(config);

        vm.stopBroadcast();

        _log(deployed);
    }

    function _loadConfig() internal view returns (DeployConfig memory config) {
        config.asset = vm.envAddress("ASSET");
        config.reserveVault = vm.envAddress("RESERVE_VAULT");
        config.gov = vm.envAddress("GOV");
        config.management = vm.envAddress("MANAGEMENT");
        config.keeper = vm.envAddress("KEEPER");
        config.vaultName = vm.envOr("MAIN_VAULT_NAME", string("YTranche Main Vault"));
        config.vaultSymbol = vm.envOr("MAIN_VAULT_SYMBOL", string("ytMAIN"));
        config.vaultProfitMaxUnlockTime = vm.envOr("MAIN_VAULT_PROFIT_MAX_UNLOCK_TIME", uint256(0));
    }

    function _validateYearnV31() internal view {
        IVaultFactory vaultFactory = IVaultFactory(VAULT_FACTORY_ADDRESS);
        require(VAULT_FACTORY_ADDRESS.code.length != 0, "VAULT_FACTORY_NOT_DEPLOYED");
        require(TOKENIZED_STRATEGY_ADDRESS.code.length != 0, "TOKENIZED_STRATEGY_NOT_DEPLOYED");
        require(vaultFactory.vault_original() == VAULT_ORIGINAL_ADDRESS, "BAD_VAULT_ORIGINAL");
        require(_sameString(vaultFactory.apiVersion(), "3.1.0"), "BAD_VAULT_FACTORY_VERSION");
        require(_sameString(IStrategy(TOKENIZED_STRATEGY_ADDRESS).apiVersion(), "3.1.0"), "BAD_TOKENIZED_VERSION");
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

        deployed.mainVault.set_role(config.gov, Roles.ALL);
        deployed.mainVault.set_role(config.keeper, Roles.REPORTING_MANAGER | Roles.DEBT_MANAGER);
        deployed.mainVault.set_role(address(deployed.emergencyAdmin), Roles.EMERGENCY_MANAGER | Roles.MAX_DEBT_MANAGER);
        deployed.mainVault.set_deposit_limit(type(uint256).max);
        deployed.mainVault.set_deposit_hook(address(deployed.hook));
        deployed.mainVault.set_withdraw_hook(address(deployed.hook));
        deployed.mainVault.set_minimum_total_idle(0);

        // Set the reserve vault. Grant KEEPER from the management address after
        // deployment if the broadcaster is not also management.
        deployed.controller.setReserveVault(config.reserveVault);

        deployed.aTranche = new TrancheStrategy(
            config.asset, "Tranche A", address(deployed.controller), address(deployed.hook), config.gov
        );
        deployed.bTranche = new LockedTrancheStrategy(
            config.asset, "Tranche B", address(deployed.controller), address(deployed.hook), config.gov, 14 days, 7 days
        );
        deployed.eTranche = new LockedTrancheStrategy(
            config.asset, "Tranche E", address(deployed.controller), address(deployed.hook), config.gov, 14 days, 7 days
        );

        // Per-Tranche economic config (annualised target BPS, excess-share BPS)
        // is supplied at registration time. Numbers mirror the test defaults.
        deployed.controller.registerTranche(address(deployed.aTranche), 425, 0); // A: 4.25% target, 0% excess
        deployed.controller.registerTranche(address(deployed.bTranche), 425, 4000); // B: 4.25% target, 40% excess
        deployed.controller.registerTranche(address(deployed.eTranche), 0, 6000); // E: 0% target, 60% excess

        _configureTranche(address(deployed.aTranche), config.keeper, address(deployed.emergencyAdmin));
        _configureTranche(address(deployed.bTranche), config.keeper, address(deployed.emergencyAdmin));
        _configureTranche(address(deployed.eTranche), config.keeper, address(deployed.emergencyAdmin));

        _configureHook(
            deployed.hook,
            address(deployed.mainVault),
            address(deployed.aTranche),
            address(deployed.bTranche),
            address(deployed.eTranche)
        );
    }

    function _log(Deployments memory deployed) internal pure {
        console.log("VaultFactory:            ", VAULT_FACTORY_ADDRESS);
        console.log("VaultOriginal:           ", VAULT_ORIGINAL_ADDRESS);
        console.log("TokenizedStrategy:       ", TOKENIZED_STRATEGY_ADDRESS);
        console.log("Main Vault:              ", address(deployed.mainVault));
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
        hook.setOpen(true);
    }

    function _configureTranche(address tranche, address keeper, address emergencyAdmin) internal {
        IStrategy s = IStrategy(tranche);
        s.setProfitMaxUnlockTime(0);
        s.setPerformanceFee(0);
        s.setKeeper(keeper);
        s.setEmergencyAdmin(emergencyAdmin);

        ITrancheStrategy t = ITrancheStrategy(tranche);
        t.setOpen(true);
        t.setProfitLimitRatio(type(uint16).max);
        t.setLossLimitRatio(MAX_BPS - 1);
    }

    function _sameString(string memory left, string memory right) internal pure returns (bool) {
        return keccak256(bytes(left)) == keccak256(bytes(right));
    }
}
