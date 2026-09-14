// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FamilyTestBase} from "./utils/FamilyTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoundManager} from "../contracts/RoundManager.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FamilyHook} from "../contracts/FamilyHook.sol";
import {CurveRange} from "../contracts/types/CurveRange.sol";
import {FamilyToken} from "../contracts/FamilyToken.sol";
import {DevVestingDeployer} from "../contracts/DevVesting.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";

/// @notice C2: the genesis curve and the genesis opening price are deploy constants computed
/// in-contract, not arguments. Two unrelated callers get a bit-identical launch.
contract GenesisCurveTest is FamilyTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployProtocol();
    }

    /// @notice Two different callers, two independent factories with the same deploy constants:
    /// identical ranges, identical liquidity, identical opening price. Nothing a caller controls
    /// can move the price by a single tick, because there is no parameter to move it with.
    function test_twoCallersGetAnIdenticalGenesisCurve() public {
        (FamilyFactory fA,) = _deployFactory(address(swapRouter));
        (FamilyFactory fB,) = _deployFactory(address(swapRouter));

        (CurveRange[] memory rA, uint160 pA) = fA.genesisCurve();
        (CurveRange[] memory rB, uint160 pB) = fB.genesisCurve();
        assertEq(rA.length, rB.length, "same number of ranges");
        assertEq(rA.length, _standardCurveSpec().length, "one range per standard-curve segment");
        for (uint256 i = 0; i < rA.length; i++) {
            assertEq(rA[i].tickLower, rB[i].tickLower, "same lower tick");
            assertEq(rA[i].tickUpper, rB[i].tickUpper, "same upper tick");
            assertEq(rA[i].liquidity, rB[i].liquidity, "same liquidity");
        }
        assertEq(pA, pB, "same opening price");

        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        vm.prank(alice);
        (, PoolKey memory keyA) = fA.createGenesis("A", "A", "");
        vm.prank(bob);
        (, PoolKey memory keyB) = fB.createGenesis("B", "B", "");

        (uint160 spotA,,,) = im.getSlot0(keyA.toId());
        (uint160 spotB,,,) = im.getSlot0(keyB.toId());
        assertEq(spotA, pA, "the pool opened at the derived price");
        assertEq(spotA, spotB, "the caller cannot influence the price");
        assertEq(fA.genesisCreator(), alice, "the caller gets the attribution and nothing else");
        assertEq(fB.genesisCreator(), bob);
    }

    /// @notice The genesis curve really is the standard curve in GENESIS_UNIT terms: every
    /// segment is placed, contiguous, token-only and strictly below the opening price.
    function test_genesisCurveIsTheStandardShapeInGenesisUnits() public {
        _createGenesis();
        assertEq(factory.GENESIS_UNIT(), GENESIS_UNIT, "the unit is a deploy constant");
        assertEq(ranges.length, _standardCurveSpec().length);
        int24 top = ranges[0].tickUpper;
        for (uint256 i = 0; i < ranges.length; i++) {
            assertLt(ranges[i].tickLower, ranges[i].tickUpper, "non-empty");
            assertLe(ranges[i].tickUpper, top, "at or below the opening tick");
            if (i > 0) assertEq(ranges[i].tickUpper, ranges[i - 1].tickLower, "contiguous");
        }
        assertEq(token.balanceOf(address(locker)), 0, "the whole supply went into the curve");
        IFamilyHook.RegisteredPool memory p = hook.poolInfo(poolId);
        assertEq(p.initSqrtPriceX96, initSqrtPriceX96, "registered at the derived price");
    }

    /// @notice L7: nothing can be launched into a half-deployed stack, and the check is a
    /// permissionless one-time latch rather than an admin switch.
    function test_wireRefusesAHalfDeployedStack() public {
        // a factory whose "FeeVault", "BidDeployer" and "router" are plain EOAs with no code
        address ghostVault = address(0xDEAD01);
        address ghostRouter = address(0xDEAD02);
        address ghostDeployer = address(0xDEAD03);
        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        address predictedLocker = vm.computeCreateAddress(predictedFactory, 1);
        FamilyToken impl = new FamilyToken(predictedFactory);
        DevVestingDeployer vestingDeployer = new DevVestingDeployer();
        bytes memory args =
            abi.encode(address(manager), predictedFactory, predictedLocker, ghostVault, ghostRouter, HOP_FEE_PPM);
        (, bytes32 salt) = _mine(predictedFactory, args);

        FamilyFactory f = new FamilyFactory(
            IPoolManager(address(manager)),
            ghostVault,
            ghostDeployer,
            ghostRouter,
            HOP_FEE_PPM,
            H_FRAC_WAD,
            H_MIN_FRAC_WAD,
            GENESIS_UNIT,
            _bondSchedule(),
            maxIndex,
            steward,
            sunsetDelay,
            address(0),
            _standardCurveSpec(),
            salt,
            address(impl),
            FamilyFactory.DevAllocation({
                deployer: address(vestingDeployer),
                bps: devAllocationBps,
                cliff: vestingCliffS,
                duration: vestingDurationS
            }),
            FamilyFactory.RoundSetup({
                deployer: address(roundManagerDeployer),
                randomness: address(randomness),
                endTimeout: endTimeout,
                durationScaleDiv: durationScaleDiv
            })
        );
        assertFalse(f.wired());
        vm.expectRevert(FamilyFactory.NotWired.selector);
        f.createGenesis("G", "G", "");
        vm.expectRevert(FamilyFactory.NotWired.selector);
        f.wire();

        // the BidDeployer is checked too: two of three is still a half-deployed stack
        vm.etch(ghostVault, hex"00");
        vm.etch(ghostRouter, hex"00");
        vm.expectRevert(FamilyFactory.NotWired.selector);
        f.wire();

        // give all three addresses code and the latch closes, for anyone, with no admin
        vm.etch(ghostDeployer, hex"00");
        vm.prank(address(0xBEEF));
        f.wire();
        assertTrue(f.wired());
    }
}
