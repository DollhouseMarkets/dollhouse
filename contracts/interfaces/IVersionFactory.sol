// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The read-only surface of a version's `FamilyFactory` that another version needs in
/// order to resolve that version's live stack (README "Upgrade model", sunset handover). Declared
/// separately from the concrete `FamilyFactory` so a hook or a vault can resolve a SUCCESSOR
/// deployment whose implementation it does not share, with a static call it can check the
/// success of rather than a typed call that would revert the swap it is inside.
interface IVersionFactory {
    function roundManager() external view returns (address);
    function feeVault() external view returns (address);
    /// @notice The version's keeper/bid contract - the only address its Locker accepts a bid
    /// from, and therefore the one a LATER version must hand an ancestor payout to.
    function bidDeployer() external view returns (address);
    function router() external view returns (address);
}
