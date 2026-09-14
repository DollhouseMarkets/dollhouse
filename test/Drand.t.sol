// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BN254} from "../contracts/randomness/BN254.sol";
import {DrandSource} from "../contracts/randomness/DrandSource.sol";

/// @notice The random end's provable source, checked against REAL beacons of drand's `evmnet`
/// chain fetched from `https://api.drand.sh/v2/beacons/evmnet` on 2026-09-11.
///
/// The fixtures below are the live beacon's own parameters and two of its signatures. Nothing in
/// this test is synthetic: if the on-chain verifier disagrees with the League of Entropy, these
/// fail.
contract DrandTest is Test {
    /// @dev `/v2/beacons/evmnet/info`: scheme `bls-bn254-unchained-on-g1`, period 3 s.
    uint64 internal constant GENESIS_TIME = 1727521075;
    uint64 internal constant PERIOD = 3;

    /// @dev The 128-byte group public key of `evmnet`, as four 32-byte words in the order the
    /// API serves them.
    uint256 internal constant PK_A = 0x07e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382;
    uint256 internal constant PK_B = 0x0557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f;
    uint256 internal constant PK_C = 0x0095685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6;
    uint256 internal constant PK_D = 0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b;

    /// @dev `/v2/beacons/evmnet/rounds/20555219` and `/rounds/20000000`.
    uint64 internal constant ROUND_A = 20555219;
    bytes internal constant SIG_A =
        hex"04f261d0bf2f7532b25f2ccc042c093f3e7c8edde5db96e67738ed123466256e0ddc80f9dd0cd9481cd9381ecde4df1ff924d2e0bdb426492b9d49cc46ec58b1";
    uint64 internal constant ROUND_B = 20000000;
    bytes internal constant SIG_B =
        hex"1ad7a10ece71f082a5c931983eca674ecb297b22f9396cde3a5015b9d91795411f11d5de506f74f17645ac04a2fe6b53458a123f66e2fcb1e2ab86cb8c2d5409";

    DrandSource internal source;

    function setUp() public {
        source = new DrandSource(GENESIS_TIME, PERIOD, 6, [PK_A, PK_B, PK_C, PK_D]);
    }

    /// @notice The SVDW constants are what RFC 9380 says they are for this curve, derived rather
    /// than trusted: a wrong one would only ever show up as "nothing verifies".
    function test_svdwConstantsAreConsistent() public view {
        uint256 p = BN254.P;
        assertEq(mulmod(BN254.SVDW_C2, 2, p), p - 1, "c2 = -Z/2");
        assertEq(mulmod(BN254.SVDW_C4, 3, p), p - 16, "c4 = -16/3");
        uint256 c3 = BN254.svdwC3();
        assertEq(mulmod(c3, c3, p), p - 12, "c3^2 = -g(Z) * 3Z^2");
        assertEq(c3 & 1, 0, "c3 is the even root");
    }

    /// @notice A signature really is a G1 point of the curve the precompiles implement.
    function test_realSignaturesAreOnTheCurve() public pure {
        BN254.G1Point memory a =
            BN254.G1Point({x: uint256(bytes32(_slice(SIG_A, 0))), y: uint256(bytes32(_slice(SIG_A, 32)))});
        assertTrue(BN254.isOnCurve(a), "evmnet round 20555219 is a G1 point");
        BN254.G1Point memory b =
            BN254.G1Point({x: uint256(bytes32(_slice(SIG_B, 0))), y: uint256(bytes32(_slice(SIG_B, 32)))});
        assertTrue(BN254.isOnCurve(b), "evmnet round 20000000 is a G1 point");
    }

    /// @notice Hashing to the curve lands on the curve, for real beacon messages.
    function test_hashToPointLandsOnTheCurve() public view {
        BN254.G1Point memory m = BN254.hashToPoint(source.DST(), abi.encodePacked(keccak256(abi.encodePacked(ROUND_A))));
        assertTrue(BN254.isOnCurve(m), "H(m) is on the curve");
    }

    /// @notice THE ONE THAT MATTERS: a real evmnet beacon verifies on chain against the beacon's
    /// own published public key, and the random word is its hash.
    function test_realBeaconVerifies() public {
        bytes32 id = _pinRound(ROUND_A);
        vm.warp(source.timeOf(ROUND_A));
        uint256 word = source.fulfil(id, SIG_A);
        assertEq(word, uint256(keccak256(SIG_A)), "the word is the signature hash");
    }

    function test_aSecondRealBeaconVerifies() public {
        bytes32 id = _pinRound(ROUND_B);
        vm.warp(source.timeOf(ROUND_B));
        uint256 word = source.fulfil(id, SIG_B);
        assertEq(word, uint256(keccak256(SIG_B)), "the word is the signature hash");
    }

    /// @notice A beacon for the WRONG round does not verify, so a relayer cannot shop for an
    /// offset among the beacons that already exist.
    function test_aBeaconForAnotherRoundIsRefused() public {
        bytes32 id = _pinRound(ROUND_A);
        vm.warp(source.timeOf(ROUND_A));
        vm.expectRevert(DrandSource.InvalidSignature.selector);
        source.fulfil(id, SIG_B);
    }

    /// @notice And neither does a tampered one.
    function test_aTamperedSignatureIsRefused() public {
        bytes32 id = _pinRound(ROUND_A);
        vm.warp(source.timeOf(ROUND_A));
        bytes memory bad = SIG_A;
        bad[63] = bytes1(uint8(bad[63]) ^ 0x01);
        vm.expectRevert();
        source.fulfil(id, bad);
    }

    /// @notice {pin} always reaches a round that does not exist yet.
    function test_pinIsAlwaysInTheFuture() public {
        vm.warp(GENESIS_TIME + 1_000_000);
        bytes32 id = source.pin();
        uint64 round = source.roundOf(id);
        assertGe(source.timeOf(round), block.timestamp + source.SAFETY_S(), "the pinned beacon is not due yet");
        assertEq(source.status(id), 1, "and the source says so");
        vm.warp(source.timeOf(round));
        assertEq(source.status(id), 2, "until it is");
    }

    function test_fulfilBeforeTheBeaconExistsIsRefused() public {
        vm.warp(GENESIS_TIME + 1_000_000);
        bytes32 id = source.pin();
        vm.expectRevert(DrandSource.NotDueYet.selector);
        source.fulfil(id, SIG_A);
    }

    function test_unknownIdIsRefused() public {
        vm.expectRevert(DrandSource.UnknownId.selector);
        source.fulfil(bytes32(uint256(1)), SIG_A);
    }

    /// @dev Pin one specific round by warping to the moment {pin} would choose it.
    function _pinRound(uint64 round) internal returns (bytes32 id) {
        vm.warp(source.timeOf(round) - source.SAFETY_S());
        id = source.pin();
        assertEq(source.roundOf(id), round, "pinned the expected round");
    }

    function _slice(bytes memory b, uint256 offset) internal pure returns (bytes32 out) {
        assembly ("memory-safe") {
            out := mload(add(add(b, 32), offset))
        }
    }
}
