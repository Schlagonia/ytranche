// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

/// @notice §5.1 — re-runs the core waterfall scenarios on a 6-decimal asset
///         (USDC/USDS shape) to surface any 18-decimal assumptions / PPS rounding.
contract SixDecimalTest is Setup {
    uint256 internal constant UNIT = 1e6; // 1 token at 6 decimals
    uint256 internal constant YEAR = 31_556_952;

    function _deployAsset() internal override returns (MockERC20) {
        MockERC20 a = new MockERC20("Mock USDC", "mUSDC");
        a.setDecimals(6);
        return a;
    }

    function test_sixDecimals_assetIsSixDecimals() public view {
        assertEq(asset.decimals(), 6, "asset 6 decimals");
    }

    function test_sixDecimals_roundTripConservesPrincipal() public {
        uint256 amt = 100 * UNIT;
        uint256 shares = _depositA(alice, amt);
        vm.prank(alice);
        uint256 received = ITrancheStrategy(address(aTranche)).redeem(shares, alice, alice);
        assertApproxEqAbs(received, amt, 2, "atomic round trip conserves principal");
    }

    /// Mirror of the 18-decimal equity-promote scenario, scaled to 6 decimals.
    function test_sixDecimals_profitWaterfall_eEquityPromote() public {
        _depositA(alice, 70 * UNIT);
        _depositB(bob, 20 * UNIT);
        _depositE(eve, 1 * UNIT);
        skip(YEAR);
        _simulateRiskyPnL(int256(45 * UNIT / 10)); // 4.50
        _settle();
        _reportTranches();
        // E.baseline = principal (1.0) + 60% × 0.675 = 1.405 (in 6-decimal units)
        uint256 e = controller.liveAssets(address(eTranche));
        assertGt(e, 1_400_000, "E captured equity promote");
        assertLt(e, 1_410_000, "E promote bounded");
    }

    /// Junior-first loss ordering at 6 decimals: a loss within the junior buffer
    /// leaves the senior whole.
    function test_sixDecimals_lossOrderingJuniorFirst() public {
        _depositA(alice, 70 * UNIT);
        _depositB(bob, 20 * UNIT);
        _depositE(eve, 10 * UNIT);
        _fundReserve(10 * UNIT);

        _simulateRiskyPnL(-int256(25 * UNIT)); // reserve(10) + E(10) + B(5) absorb; A untouched
        _settle();

        assertApproxEqAbs(controller.liveAssets(address(aTranche)), 70 * UNIT, 2, "senior untouched");
        assertFalse(controller.isFrozen(address(aTranche)), "A not frozen");
        assertTrue(controller.isFrozen(address(eTranche)), "E absorbed/frozen");
        assertTrue(controller.isFrozen(address(bTranche)), "B absorbed/frozen");
    }
}
