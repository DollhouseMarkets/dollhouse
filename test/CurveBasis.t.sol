// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {IFamilyFactory} from "../contracts/interfaces/IFamilyFactory.sol";
import {FamilyToken} from "../contracts/FamilyToken.sol";
import {CurveMath} from "../contracts/libraries/CurveMath.sol";
import {StandardCurve} from "../contracts/libraries/StandardCurve.sol";
import {CurveRange} from "../contracts/types/CurveRange.sol";

/// @notice The curve basis: the factory stores the parent-unit amount every candidate's launch
/// curve was built against, once per round, and the BidDeployer rebuilds a pool's curve from
/// that stored figure instead of the parent's live supply, which anyone can burn down.
contract CurveBasisTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpEdge();
    }

    /// @notice A launched token's basis is its parent's total supply at registration (with the
    /// test stack's start setup - no oracle, zero fallback - the lower clamp, i.e. the supply
    /// rounded down to a multiple of 1000 wei), cached
    /// under the round, announced in an event, and priced by {FamilyFactory.startFdvOf}.
    function test_theBasisIsTheParentSupplyAtRegistration() public {
        address parent = roundManager.head();
        uint256 supply = _lowerClampBasis(IERC20(parent).totalSupply());

        vm.recordLogs();
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        uint256 roundId = roundManager.roundCount();

        assertEq(factory.curveBasisOf(a.token), supply, "basis = parent supply at registration");
        assertEq(factory.roundCurveBasis(roundId), supply, "cached under the round");
        assertEq(factory.startFdvOf(a.token), factory.startFdv(supply), "startFdvOf reads the stored basis");
        assertEq(factory.curveBasisOf(address(0xDEAD)), 0, "nothing stored for a stranger");
        assertEq(factory.startFdvOf(address(0xDEAD)), 0, "and no start FDV either");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(factory) || logs[i].topics[0] != FamilyFactory.CurveBasis.selector) {
                continue;
            }
            assertEq(uint256(logs[i].topics[1]), roundId, "event round id");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), a.token, "event token");
            assertEq(abi.decode(logs[i].data, (uint256)), supply, "event basis");
            seen = true;
        }
        assertTrue(seen, "CurveBasis emitted");
    }

    /// @notice Two siblings of one round share the basis even when the parent is burned
    /// between their registrations, so both open at the same start FDV.
    function test_siblingsShareTheBasisAcrossAParentBurn() public {
        address parent = roundManager.head();
        uint256 supply = IERC20(parent).totalSupply();
        uint256 basis = _lowerClampBasis(supply);
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        uint256 roundId = roundManager.roundCount();

        uint256 held = IERC20(parent).balanceOf(address(this));
        assertGt(held, 0, "the test holds the parent after the first round");
        FamilyToken(parent).burn(held / 2);
        assertLt(IERC20(parent).totalSupply(), supply, "the parent supply moved");

        Cand memory b = _registerCandidate(address(0xB0B), "B");
        assertEq(roundManager.roundCount(), roundId, "same round");
        assertEq(factory.curveBasisOf(b.token), basis, "the sibling reuses the round's basis");
        assertEq(factory.curveBasisOf(b.token), factory.curveBasisOf(a.token), "shared basis");
        assertEq(factory.startFdvOf(b.token), factory.startFdvOf(a.token), "same start FDV");

        (uint160 sqrtA,,,) = im.getSlot0(a.poolId);
        (uint160 sqrtB,,,) = im.getSlot0(b.poolId);
        uint256 fdvA = CurveMath.fdvAtSqrtPrice(sqrtA, SUPPLY, a.tokenIsCurrency0);
        uint256 fdvB = CurveMath.fdvAtSqrtPrice(sqrtB, SUPPLY, b.tokenIsCurrency0);
        assertApproxEqRel(fdvA, fdvB, 1e16, "both open at the same FDV");
    }

    /// @dev Crown link two, sell the winner back so its pool sits inside the first curve range
    /// again (where the cap is sized from the registered curve), then burn a large slice of
    /// link one - link two's parent. Returns the cap before the burn.
    function _linkTwoThenBurnParent() internal returns (uint256 capBefore, uint256 basis) {
        Cand memory w = _runWinningRound(1, WINNING_ABSORPTION);
        _tradeCandidate(w, false, IERC20(w.token).balanceOf(address(this)));
        basis = factory.curveBasisOf(w.token);
        capBefore = bidDeployer.bidCap(2);
        assertGt(capBefore, 0, "a cap to compare");

        address parent = roundManager.canonical(1);
        _fundDoll(address(this), 2_000_000e18);
        _buyLink(1, 2_000_000e18);
        FamilyToken(parent).burn(IERC20(parent).balanceOf(address(this)));
        uint256 live = IERC20(parent).totalSupply();
        assertLt(live, (basis * 9) / 10, "at least a tenth of the parent is gone");

        // the drift is real: a curve rebuilt from the live supply is not the launched curve
        bool orient = roundManager.canonical(2) < parent;
        (CurveRange[] memory fromLive,) =
            StandardCurve.build(factory.curveSpec(), live, SUPPLY, factory.TICK_SPACING(), orient);
        (CurveRange[] memory fromBasis,) =
            StandardCurve.build(factory.curveSpec(), basis, SUPPLY, factory.TICK_SPACING(), orient);
        assertTrue(fromLive[0].tickLower != fromBasis[0].tickLower, "the live-supply curve has moved");
    }

    /// @notice The drift bug: {BidDeployer.bidCap} used to rebuild the launch curve from the
    /// parent's live supply, so burning the parent moved every cap. It now reads the basis.
    function test_bidCapDoesNotChangeAfterTheParentIsBurned() public {
        (uint256 capBefore,) = _linkTwoThenBurnParent();
        assertEq(bidDeployer.bidCap(2), capBefore, "bidCap does not change after the parent is burned");
    }

    /// @notice A factory without {curveBasisOf} (an older version) or one that answers zero falls
    /// back to the parent's live supply - the old behaviour, drift included.
    function test_bidCapFallsBackToParentSupplyWithoutAStoredBasis() public {
        Cand memory w = _runWinningRound(1, WINNING_ABSORPTION);
        _tradeCandidate(w, false, IERC20(w.token).balanceOf(address(this)));
        uint256 capBefore = bidDeployer.bidCap(2);

        // an older factory: the getter does not exist, so the call reverts
        vm.mockCallRevert(address(factory), abi.encodeWithSelector(IFamilyFactory.curveBasisOf.selector), "");
        assertEq(bidDeployer.bidCap(2), capBefore, "undisturbed parent: supply == basis, same cap");
        vm.clearMockedCalls();

        address parent = roundManager.canonical(1);
        _fundDoll(address(this), 2_000_000e18);
        _buyLink(1, 2_000_000e18);
        FamilyToken(parent).burn(IERC20(parent).balanceOf(address(this)));

        assertEq(bidDeployer.bidCap(2), capBefore, "stored basis: no drift");

        vm.mockCallRevert(address(factory), abi.encodeWithSelector(IFamilyFactory.curveBasisOf.selector), "");
        uint256 capReverting = bidDeployer.bidCap(2);
        vm.clearMockedCalls();
        assertTrue(capReverting != capBefore, "reverting getter: the cap follows the live supply");

        vm.mockCall(
            address(factory), abi.encodeWithSelector(IFamilyFactory.curveBasisOf.selector), abi.encode(uint256(0))
        );
        assertEq(bidDeployer.bidCap(2), capReverting, "zero basis: the same live-supply fallback");
        vm.clearMockedCalls();
    }
}
