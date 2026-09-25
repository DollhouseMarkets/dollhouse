// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice The cross-version surface of a deployment's `BidDeployer`: the one entrypoint a
/// LATER version calls on an EARLIER one. Declared separately from the concrete contract so a
/// version can pay an ancestor whose implementation it does not share.
interface IBidDeployer {
    /// @notice Permissionless: deposit `parentAmount` of `token`'s PARENT currency as a locked
    /// bid just below spot in `token`'s pool, where `token` is a canonical link of THIS version.
    /// The parent tokens must be approved to this contract first. The deposit is a gift - no
    /// bounty, no ledger credit, no claim - and it is band- and size-capped exactly like the
    /// keeper path. Canonical index 0 is refused: it is quoted outside this protocol.
    ///
    /// @dev This is how a LATER version pays an ancestor whose pool belongs to an earlier one: a
    /// v2 Locker can never add liquidity to a v1 pool (v1's hook only accepts v1's Locker), so
    /// v2's BidDeployer hands the parent tokens to v1's BidDeployer and lets v1's own Locker
    /// place the bid. See `BidDeployer.deployAncestor` and README "Upgrade model".
    function depositExternalBid(address token, uint256 parentAmount) external returns (uint256 deposited);
}
