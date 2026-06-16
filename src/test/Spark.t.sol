// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Sanity check that a real Spark / Sky 4626 vault works as the
///         controller's reserve sink. This test is opt-in: it skips
///         (returns early) unless run against a mainnet fork — set
///         `ETH_RPC_URL` and run `forge test --fork-url $ETH_RPC_URL --match-contract SparkReserveSanityTest`.
///
///         Uses Spark sUSDS (a USDS savings 4626) as the canonical example.
///         Production deployments can swap any same-asset 4626 (e.g. Yearn
///         yvUSDC, MetaMorpho, Aave aTokens via 4626 wrappers, etc.).
contract SparkReserveSanityTest is Test {
    // Sky / Spark sUSDS Savings vault (4626).
    IERC4626 internal constant SUSDS = IERC4626(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);

    // USDS underlying (Sky's USDC-like stable).
    IERC20 internal constant USDS = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);

    address internal constant USER = address(0xC0FFEE);

    function setUp() public {
        // Bail out cleanly when not on a fork — keeps the unit suite hermetic.
        if (block.chainid != 1) vm.skip(true);
    }

    function test_susds_4626_deposit_and_redeem() public {
        // Fund USER via foundry deal.
        deal(address(USDS), USER, 1_000e18);

        vm.startPrank(USER);
        USDS.approve(address(SUSDS), type(uint256).max);

        uint256 shares = SUSDS.deposit(1_000e18, USER);
        assertGt(shares, 0, "minted shares");

        uint256 assetsBack = SUSDS.redeem(shares, USER, USER);
        // PPS may have moved a fraction of a wei within a single block; the
        // round-trip should land within rounding.
        assertGe(assetsBack + 1, 1_000e18);
        vm.stopPrank();
    }
}
