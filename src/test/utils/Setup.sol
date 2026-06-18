// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";
import {TrancheStrategy} from "../../TrancheStrategy.sol";
import {LockedTrancheStrategy} from "../../LockedTrancheStrategy.sol";
import {TrancheController} from "../../TrancheController.sol";
import {Hook} from "../../Hook.sol";
import {Authorizer} from "../../periphery/Authorizer.sol";
import {EmergencyAdmin} from "../../periphery/EmergencyAdmin.sol";

import {ITrancheStrategy} from "../../interfaces/ITrancheStrategy.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles} from "@yearn-vaults/interfaces/Roles.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFactory} from "../mocks/MockFactory.sol";
import {MockReserveVault} from "../mocks/MockReserveVault.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {VyperDeployer} from "../../../lib/yearn-vaults-v3/foundry_tests/utils/VyperDeployer.sol";

/// @notice Shared deployment / wiring for all Tranche tests.
///   Three Tranches all built from the same generic mapping-driven
///   controller / hook surface — A, B, E are just three addresses
///   registered in priority order.
contract Setup is Test {
    address public governance = address(0xA1);
    address public management = address(0xA3);
    address public keeper = address(0xA2);
    address public alice = address(0xB1);
    address public bob = address(0xB2);
    address public carol = address(0xB3);
    address public eve = address(0xB4);
    address public treasury = address(0xC1);

    MockERC20 public asset;
    MockFactory public factory;
    IVault public mainVault;
    IVaultFactory public vaultFactory;
    VyperDeployer public vyperDeployer;
    MockReserveVault public reserveVault;
    Authorizer public authorizer;
    Hook public hook;
    EmergencyAdmin public emergencyAdmin;
    TokenizedStrategy public tokenizedStrategyImplementation;
    MockStrategy public riskyStrategy;
    TrancheController public controller;
    TrancheStrategy public aTranche;
    LockedTrancheStrategy public bTranche;
    LockedTrancheStrategy public eTranche;

    // Default per-Tranche economic config used by `setUp`.
    uint16 internal constant DEFAULT_A_TARGET_BPS = 425; // 4.25 % / yr
    uint16 internal constant DEFAULT_A_EXCESS_BPS = 0;
    uint16 internal constant DEFAULT_B_TARGET_BPS = 425; // 4.25 % / yr
    uint16 internal constant DEFAULT_B_EXCESS_BPS = 4000; // 40 %
    uint16 internal constant DEFAULT_E_TARGET_BPS = 0;
    uint16 internal constant DEFAULT_E_EXCESS_BPS = 6000; // 60 %

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_556_952;
    // Mirrors BaseStrategy.tokenizedStrategyAddress in the constant_accual branch.
    address internal constant TOKENIZED_STRATEGY_ADDRESS = 0x2e234DAe75C793f67A35089C9d99245E1C58470b;

    function setUp() public virtual {
        asset = new MockERC20("Mock USD", "mUSD");

        // Burn the deterministic holder address before deploying the real factory.
        new MockFactory();
        factory = new MockFactory();
        tokenizedStrategyImplementation = new TokenizedStrategy(address(factory));
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, address(tokenizedStrategyImplementation).code);

        vyperDeployer = new VyperDeployer();
        address vaultOriginal = vyperDeployer.deployContract("lib/yearn-vaults-v3/contracts/", "VaultV3");
        vaultFactory = IVaultFactory(
            vyperDeployer.deployContract(
                "lib/yearn-vaults-v3/contracts/",
                "VaultFactory",
                abi.encode("YTranche Test Vault Factory", vaultOriginal, governance)
            )
        );
        mainVault = IVault(vaultFactory.deploy_new_vault(address(asset), "Main", "MAIN", address(this), 0));
        mainVault.set_role(address(this), Roles.ALL);
        mainVault.set_role(keeper, Roles.REPORTING_MANAGER | Roles.DEBT_MANAGER);
        mainVault.set_deposit_limit(type(uint256).max);

        riskyStrategy = new MockStrategy(address(asset));
        IStrategy(address(riskyStrategy)).setProfitMaxUnlockTime(0);
        IStrategy(address(riskyStrategy)).setPerformanceFee(0);
        IStrategy(address(riskyStrategy)).setKeeper(keeper);

        mainVault.add_strategy(address(riskyStrategy));
        mainVault.update_max_debt_for_strategy(address(riskyStrategy), type(uint256).max);
        address[] memory queue = new address[](1);
        queue[0] = address(riskyStrategy);
        mainVault.set_default_queue(queue);
        mainVault.set_auto_allocate(true);
        mainVault.set_minimum_total_idle(0);
        mainVault.setProfitMaxUnlockTime(0);

        reserveVault = new MockReserveVault(address(asset));

        authorizer = new Authorizer(governance, management);
        controller = new TrancheController(address(asset), address(mainVault), address(authorizer));

        hook = new Hook(address(authorizer), address(controller));
        mainVault.set_deposit_hook(address(hook));
        mainVault.set_withdraw_hook(address(hook));

        // Central emergency contract gets the vault roles it needs to pause,
        // shut down, and zero strategy max debt.
        emergencyAdmin = new EmergencyAdmin(address(authorizer));
        mainVault.set_role(address(emergencyAdmin), Roles.EMERGENCY_MANAGER | Roles.MAX_DEBT_MANAGER);

        // Governance sets the reserve vault; management grants operational roles.
        vm.prank(governance);
        controller.setReserveVault(address(reserveVault));
        vm.startPrank(management);
        authorizer.grantRole(authorizer.KEEPER_ROLE(), keeper);
        vm.stopPrank();

        aTranche = new TrancheStrategy(address(asset), "Tranche A", address(controller), address(hook), governance);
        bTranche = new LockedTrancheStrategy(
            address(asset), "Tranche B", address(controller), address(hook), governance, 14 days, 7 days
        );
        eTranche = new LockedTrancheStrategy(
            address(asset), "Tranche E", address(controller), address(hook), governance, 14 days, 7 days
        );

        // Governance-side wiring.
        vm.startPrank(governance);
        controller.registerTranche(address(aTranche), DEFAULT_A_TARGET_BPS, DEFAULT_A_EXCESS_BPS);
        controller.registerTranche(address(bTranche), DEFAULT_B_TARGET_BPS, DEFAULT_B_EXCESS_BPS);
        controller.registerTranche(address(eTranche), DEFAULT_E_TARGET_BPS, DEFAULT_E_EXCESS_BPS);
        vm.stopPrank();

        // Lift the Hook's (zero-by-default) rate + aggregate limits so the
        // permissionless test flows aren't throttled.
        _configureVault(address(aTranche));
        _configureVault(address(bTranche));
        _configureVault(address(eTranche));
        _configureVault(address(mainVault));

        // Open the main vault for direct deposits (per-Tranche gating lives on
        // each Tranche, configured in `_configureTranche`).
        vm.prank(management);
        hook.setOpen(true);

        // Tranche-side configuration (this contract is management).
        _configureTranche(address(aTranche));
        _configureTranche(address(bTranche));
        _configureTranche(address(eTranche));

        vm.label(address(asset), "asset");
        vm.label(address(mainVault), "mainVault");
        vm.label(address(reserveVault), "reserveVault");
        vm.label(address(controller), "controller");
        vm.label(management, "management");
        vm.label(address(aTranche), "aTranche");
        vm.label(address(bTranche), "bTranche");
        vm.label(address(eTranche), "eTranche");
        vm.label(address(riskyStrategy), "riskyStrategy");
        vm.label(address(hook), "hook");
        vm.label(address(emergencyAdmin), "emergencyAdmin");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "tokenizedStrategy");
    }

    // ------------------------------------------------------------------
    //  Helpers
    // ------------------------------------------------------------------
    function _airdrop(address _to, uint256 _amount) internal {
        asset.mint(_to, _amount);
    }

    /// @dev Lift a target's (zero-by-default) Hook deposit/withdraw limits so
    ///      permissionless test flows aren't blocked. Pranked as management.
    function _configureVault(address _vault) internal {
        vm.startPrank(management);
        hook.setDepositLimit(_vault, type(uint256).max);
        hook.setDepositRateLimit(_vault, type(uint128).max);
        hook.setWithdrawRateLimit(_vault, type(uint128).max);
        vm.stopPrank();
    }

    /// @dev Tranche-side setup (this contract is management): unlock time, fees,
    ///      keeper, open its deposit gate, and widen the {BaseHealthCheck} report
    ///      limits so the economic tests can record arbitrary profit / loss.
    ///      Must run after the Tranche is registered (setters trigger accrual).
    function _configureTranche(address _tranche) internal {
        ITrancheStrategy t = ITrancheStrategy(_tranche);
        t.setProfitMaxUnlockTime(0);
        t.setPerformanceFee(0);
        t.setKeeper(keeper);
        t.setEmergencyAdmin(address(emergencyAdmin));
        t.setOpen(true);
        t.setProfitLimitRatio(type(uint16).max);
        t.setLossLimitRatio(MAX_BPS - 1);
    }

    function _fundReserve(uint256 _amount) internal {
        _airdrop(address(this), _amount);
        asset.approve(address(controller), _amount);
        controller.fundReserve(_amount);
    }

    function _depositA(address _user, uint256 _amount) internal returns (uint256 shares) {
        _airdrop(_user, _amount);
        vm.startPrank(_user);
        asset.approve(address(aTranche), _amount);
        shares = ITrancheStrategy(address(aTranche)).deposit(_amount, _user);
        vm.stopPrank();
    }

    function _depositB(address _user, uint256 _amount) internal returns (uint256 shares) {
        _airdrop(_user, _amount);
        vm.startPrank(_user);
        asset.approve(address(bTranche), _amount);
        shares = ITrancheStrategy(address(bTranche)).deposit(_amount, _user);
        vm.stopPrank();
    }

    function _depositE(address _user, uint256 _amount) internal returns (uint256 shares) {
        _airdrop(_user, _amount);
        vm.startPrank(_user);
        asset.approve(address(eTranche), _amount);
        shares = ITrancheStrategy(address(eTranche)).deposit(_amount, _user);
        vm.stopPrank();
    }

    function _simulateRiskyPnL(int256 _delta) internal {
        if (_delta > 0) {
            asset.mint(address(riskyStrategy), uint256(_delta));
        } else if (_delta < 0) {
            uint256 amount = uint256(-_delta);
            uint256 balance = asset.balanceOf(address(riskyStrategy));
            require(balance >= amount, "burn too much");
            asset.burn(address(riskyStrategy), amount);
        }
        vm.prank(keeper);
        IStrategy(address(riskyStrategy)).report();
        vm.prank(keeper);
        mainVault.process_report(address(riskyStrategy));
    }

    function _settle() internal {
        vm.prank(keeper);
        controller.settle();
    }

    /// @dev Report every Tranche — realizes any pending excess recorded
    ///      at settlement into the Tranches' baselines. Settlement produces
    ///      large, *expected* swings (e.g. the equity Tranche absorbing the
    ///      bulk of the excess), so the health check is bypassed for these
    ///      reports just as management would around a settlement.
    function _reportTranches() internal {
        ITrancheStrategy(address(aTranche)).setDoHealthCheck(false);
        ITrancheStrategy(address(bTranche)).setDoHealthCheck(false);
        ITrancheStrategy(address(eTranche)).setDoHealthCheck(false);
        vm.prank(keeper);
        ITrancheStrategy(address(aTranche)).report();
        vm.prank(keeper);
        ITrancheStrategy(address(bTranche)).report();
        vm.prank(keeper);
        ITrancheStrategy(address(eTranche)).report();
    }
}
