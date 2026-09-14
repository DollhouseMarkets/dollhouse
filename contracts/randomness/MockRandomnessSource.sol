// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRandomnessSource} from "../interfaces/IRandomnessSource.sol";

/// @title MockRandomnessSource
/// @notice TESTNET AND TEST ONLY. A randomness source with NO cryptography in it: it hands out
/// ids, makes them available after {DELAY_S}, and returns whatever word the relayer supplies
/// (or, for an empty proof, a deterministic default). It is labelled loudly because a mainnet
/// deployment that wired this in would let anyone choose the round's end offset.
///
/// @dev Kept in `contracts/` rather than `test/` because a testnet run deploys it: see
/// `docs/DEPLOY_CONSTANTS.md`, row RANDOMNESS_SOURCE.
contract MockRandomnessSource is IRandomnessSource {
    /// @notice Marks this source as unsuitable for a real deployment. Read by the deploy script.
    bool public constant IS_MOCK = true;

    /// @notice How long after {pin} the id becomes fulfillable, mirroring drand's few-second
    /// beacon delay so the two-phase flow is exercised exactly as it is in production.
    uint64 public immutable DELAY_S;

    /// @notice The word returned when a relayer supplies an EMPTY proof.
    uint256 public defaultWord;

    mapping(bytes32 => uint64) public dueAt;

    uint256 internal _nonce;

    event Pinned(bytes32 indexed id, uint64 dueAt);
    event Fulfilled(bytes32 indexed id, uint256 word);

    error UnknownId();
    error NotDueYet();

    constructor(uint64 delayS) {
        DELAY_S = delayS;
    }

    /// @notice Set the word an empty proof resolves to. Permissionless, because this contract is
    /// a mock and pretending otherwise would hide that fact.
    function setDefaultWord(uint256 word) external {
        defaultWord = word;
    }

    /// @inheritdoc IRandomnessSource
    function pin() external returns (bytes32 id) {
        id = keccak256(abi.encodePacked(address(this), block.timestamp, ++_nonce));
        uint64 due = uint64(block.timestamp) + DELAY_S;
        dueAt[id] = due;
        emit Pinned(id, due);
    }

    /// @inheritdoc IRandomnessSource
    /// @param proof An ABI-encoded `uint256` word, or empty for {defaultWord}.
    function fulfil(bytes32 id, bytes calldata proof) external returns (uint256 word) {
        uint64 due = dueAt[id];
        if (due == 0) revert UnknownId();
        if (block.timestamp < due) revert NotDueYet();
        word = proof.length == 0 ? defaultWord : abi.decode(proof, (uint256));
        emit Fulfilled(id, word);
    }

    /// @inheritdoc IRandomnessSource
    function status(bytes32 id) external view returns (uint8) {
        uint64 due = dueAt[id];
        if (due == 0) return 0;
        return block.timestamp < due ? 1 : 2;
    }
}
