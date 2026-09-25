// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DrandSource} from "../../contracts/randomness/DrandSource.sol";

/// @notice Property tests for the beacon source (docs/spec/PROPERTIES.md sec.3.12), tier F,
/// against the real `evmnet` group key and a real published beacon.
contract RandomnessPropTest is Test {
    uint64 internal constant GENESIS_TIME = 1727521075;
    uint64 internal constant PERIOD = 3;
    uint64 internal constant SAFETY_S = 6;

    uint256 internal constant PK_A = 0x07e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382;
    uint256 internal constant PK_B = 0x0557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f;
    uint256 internal constant PK_C = 0x0095685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6;
    uint256 internal constant PK_D = 0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b;

    uint64 internal constant ROUND_A = 20555219;
    bytes internal constant SIG_A =
        hex"04f261d0bf2f7532b25f2ccc042c093f3e7c8edde5db96e67738ed123466256e0ddc80f9dd0cd9481cd9381ecde4df1ff924d2e0bdb426492b9d49cc46ec58b1";

    DrandSource internal source;

    function setUp() public {
        source = new DrandSource(GENESIS_TIME, PERIOD, SAFETY_S, [PK_A, PK_B, PK_C, PK_D]);
    }

    /// @notice RAN-02: a tampered signature is rejected, for a flip of any bit of any byte.
    function testFuzz_RAN02_aTamperedSignatureIsRejected(uint256 byteSeed, uint8 bit) public {
        bytes32 id = _pinRound(ROUND_A);
        vm.warp(source.timeOf(ROUND_A));

        bytes memory bad = SIG_A;
        uint256 index = bound(byteSeed, 0, 63);
        bad[index] = bytes1(uint8(bad[index]) ^ uint8(1 << (bit % 8)));
        vm.assume(keccak256(bad) != keccak256(SIG_A));

        vm.expectRevert();
        source.fulfil(id, bad);
    }

    /// @notice RAN-02: a signature of the wrong length, or a point that is not on the curve, is
    /// rejected rather than accepted as a word.
    function testFuzz_RAN02_junkIsRejected(uint256 x, uint256 y, uint256 lengthSeed) public {
        bytes32 id = _pinRound(ROUND_A);
        vm.warp(source.timeOf(ROUND_A));

        uint256 length = bound(lengthSeed, 0, 96);
        vm.assume(length != 64);
        bytes memory wrongLength = new bytes(length);
        vm.expectRevert(DrandSource.BadSignatureLength.selector);
        source.fulfil(id, wrongLength);

        bytes memory point = abi.encodePacked(x, y);
        vm.expectRevert();
        source.fulfil(id, point);
    }

    /// @notice RAN-02: a valid signature for a round other than the pinned one is rejected, so a
    /// relayer cannot shop for an offset among the beacons that already exist.
    function testFuzz_RAN02_aBeaconForAnotherRoundIsRejected(uint256 roundSeed) public {
        uint64 other = uint64(bound(roundSeed, 1, ROUND_A - 1));
        bytes32 id = _pinRound(other);
        vm.warp(source.timeOf(ROUND_A));
        vm.expectRevert(DrandSource.InvalidSignature.selector);
        source.fulfil(id, SIG_A);
    }

    /// @notice RAN-03: `pin()` always records a beacon round whose scheduled production time is
    /// strictly after `block.timestamp`, for every call time.
    function testFuzz_RAN03_thePinnedBeaconIsAlwaysInTheFuture(uint256 timeSeed) public {
        uint256 t = bound(timeSeed, 1, uint256(GENESIS_TIME) + 200 * 365 days);
        vm.warp(t);

        bytes32 id = source.pin();
        uint64 round = source.roundOf(id);
        assertGt(source.timeOf(round), vm.getBlockTimestamp(), "the pinned beacon does not exist yet");
        assertGe(source.timeOf(round), vm.getBlockTimestamp() + SAFETY_S, "with the whole safety margin");
        assertEq(source.status(id), 1, "and the source says it is not due");

        vm.warp(source.timeOf(round));
        assertEq(source.status(id), 2, "until its production time");
    }

    /// @notice RAN-03: pinning twice in the same second pins the same round, and pinning later
    /// never pins an earlier round - the map is monotone in time.
    function testFuzz_RAN03_pinningIsMonotoneInTime(uint256 timeSeed, uint256 gap) public {
        vm.warp(bound(timeSeed, GENESIS_TIME, uint256(GENESIS_TIME) + 100 * 365 days));
        uint64 first = source.roundOf(source.pin());
        assertEq(source.roundOf(source.pin()), first, "the same second pins the same round");

        vm.warp(vm.getBlockTimestamp() + bound(gap, 1, 365 days));
        assertGe(source.roundOf(source.pin()), first, "a later pin is never an earlier round");
    }

    function _pinRound(uint64 round) internal returns (bytes32 id) {
        vm.warp(source.timeOf(round) - SAFETY_S);
        id = source.pin();
        assertEq(source.roundOf(id), round, "pinned the expected round");
    }
}
