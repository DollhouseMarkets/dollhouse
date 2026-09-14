// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IRandomnessSource
/// @notice The pluggable provable-randomness seam the RoundManager's RANDOM END is built on
/// (MECHANISM_v3 sec.3). Two calls, split in time on purpose:
///
///   `pin()`   - taken at the round's nominal end `T`. It records a FUTURE event whose value
///               nobody, including the operator, can know yet, and returns the id of it.
///   `fulfil()` - relayed by anyone once that event has happened. The source VERIFIES the proof
///               on chain and returns the random word; a proof that does not verify reverts.
///
/// The separation is what makes the end unpredictable: at `T` the offset is already committed to
/// a value that does not exist yet, so a trade placed in the last three minutes cannot know
/// whether it lands before or after the true end.
interface IRandomnessSource {
    /// @notice Pin the first future event this source can commit to. Permissionless; the caller
    /// is recorded as the holder of the id so two rounds cannot collide.
    function pin() external returns (bytes32 id);

    /// @notice Verify `proof` for `id` and return the random word. Reverts if it does not verify.
    function fulfil(bytes32 id, bytes calldata proof) external returns (uint256 word);

    /// @notice 0 = unknown id, 1 = pinned but the underlying event has not been produced yet,
    /// 2 = the event is due (a valid proof can be relayed now).
    function status(bytes32 id) external view returns (uint8);
}
