// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRandomnessSource} from "../interfaces/IRandomnessSource.sol";
import {BN254} from "./BN254.sol";

/// @title DrandSource
/// @notice The provable randomness behind the RANDOM END (MECHANISM_v3 sec.3): drand's public
/// `evmnet` beacon, verified on chain.
///
/// `evmnet` is the League of Entropy chain whose scheme is `bls-bn254-unchained-on-g1` - BLS
/// signatures in G1 over BN254, which is exactly the pairing the EVM can check natively through
/// precompile 0x08. Verified live against the public API on 2026-09-11: the beacon is served, its
/// period is 3 s, its public key is a 128-byte G2 point and its signatures are 64-byte G1 points.
///
/// @dev How the unpredictability is obtained. At the round's nominal end `T` the RoundManager
/// calls {pin}, which records the FIRST drand round whose beacon does not exist yet
/// (`block.timestamp + SAFETY_S` or later). Nobody - the operator included - can know that
/// beacon's value: it is produced by a threshold of independent parties a few seconds later.
/// Anyone may then relay the 64-byte signature to {fulfil}, which verifies it against the
/// beacon's immutable public key and returns `keccak256(signature)` as the random word. A forged
/// signature does not verify; a withheld one is handled by the RoundManager's own timeout.
///
/// The message a drand round signs, for this UNCHAINED scheme, is `keccak256(round)` with the
/// round as a big-endian `uint64` - keccak, not sha256, because the chain is meant to be verified
/// by an EVM; the signature is that message hashed to G1 under the domain
/// `BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_` and multiplied by the chain's secret key. Both
/// facts were established EMPIRICALLY here, against real beacons: see `test/Drand.t.sol`.
///
/// TRUST STATEMENT (for the public docs). The beacon is public, verifiable and NOT controlled by
/// Dollhouse; what this contract trusts is that a threshold of the League of Entropy does not
/// collude, and that somebody relays the signature. Neither can bias the end in Dollhouse's
/// favour: a withheld beacon ends the round deterministically at `T`, which is the one outcome a
/// late buyer can already plan for.
contract DrandSource is IRandomnessSource {
    /// @notice Domain separation tag of the `bls-bn254-unchained-on-g1` scheme.
    bytes public constant DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";

    /// @notice `genesis_time` and `period` of the beacon, from its `/info` endpoint. Immutable:
    /// a source that could be repointed at another chain would be a switch on the randomness.
    uint64 public immutable GENESIS_TIME;
    uint64 public immutable PERIOD;
    /// @notice How far into the future {pin} reaches. It must exceed the time between the pinning
    /// transaction being broadcast and being included, or the pinned beacon could already exist.
    uint64 public immutable SAFETY_S;

    /// @notice The beacon's group public key, a G2 point.
    uint256 internal immutable PK_X0;
    uint256 internal immutable PK_X1;
    uint256 internal immutable PK_Y0;
    uint256 internal immutable PK_Y1;

    /// @notice The drand round each pinned id refers to.
    mapping(bytes32 => uint64) public roundOf;

    event Pinned(bytes32 indexed id, uint64 drandRound, uint64 dueAt);
    event Fulfilled(bytes32 indexed id, uint64 drandRound, uint256 word);

    error UnknownId();
    error NotDueYet();
    error BadSignatureLength();
    error SignatureNotOnCurve();
    error InvalidSignature();

    /// @param publicKey The beacon's 128-byte G2 key in EIP-197 order: `x1, x0, y1, y0`.
    constructor(uint64 genesisTime, uint64 period, uint64 safetyS, uint256[4] memory publicKey) {
        GENESIS_TIME = genesisTime;
        PERIOD = period;
        SAFETY_S = safetyS;
        PK_X0 = publicKey[0];
        PK_X1 = publicKey[1];
        PK_Y0 = publicKey[2];
        PK_Y1 = publicKey[3];
    }

    /// @notice The drand round produced at or after `timestamp`.
    function roundAt(uint64 timestamp) public view returns (uint64) {
        if (timestamp <= GENESIS_TIME) return 1;
        uint64 elapsed = timestamp - GENESIS_TIME;
        return (elapsed + PERIOD - 1) / PERIOD;
    }

    /// @notice The time drand round `round` is produced at.
    function timeOf(uint64 round) public view returns (uint64) {
        return GENESIS_TIME + round * PERIOD;
    }

    /// @inheritdoc IRandomnessSource
    function pin() external returns (bytes32 id) {
        uint64 round = roundAt(uint64(block.timestamp) + SAFETY_S);
        id = bytes32(uint256(round));
        roundOf[id] = round;
        emit Pinned(id, round, timeOf(round));
    }

    /// @inheritdoc IRandomnessSource
    /// @param proof The beacon's 64-byte BLS signature for the pinned round.
    function fulfil(bytes32 id, bytes calldata proof) external returns (uint256 word) {
        uint64 round = roundOf[id];
        if (round == 0) revert UnknownId();
        if (block.timestamp < timeOf(round)) revert NotDueYet();
        if (proof.length != 64) revert BadSignatureLength();

        BN254.G1Point memory signature =
            BN254.G1Point({x: uint256(bytes32(proof[0:32])), y: uint256(bytes32(proof[32:64]))});
        if (!BN254.isOnCurve(signature)) revert SignatureNotOnCurve();

        BN254.G1Point memory messagePoint = BN254.hashToPoint(DST, abi.encodePacked(keccak256(abi.encodePacked(round))));
        BN254.G2Point memory pk = BN254.G2Point({x: [PK_X0, PK_X1], y: [PK_Y0, PK_Y1]});
        if (!BN254.verifySingle(signature, pk, messagePoint)) revert InvalidSignature();

        word = uint256(keccak256(proof));
        emit Fulfilled(id, round, word);
    }

    /// @inheritdoc IRandomnessSource
    function status(bytes32 id) external view returns (uint8) {
        uint64 round = roundOf[id];
        if (round == 0) return 0;
        return block.timestamp < timeOf(round) ? 1 : 2;
    }
}
