// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice The read-only surface a PRIOR version's RoundManager must expose for a later version
/// to continue the trunk from it (README "Upgrade model"). Every deployed `RoundManager` satisfies
/// this ABI; it is declared separately so a future version can point at a registry whose
/// implementation it does not share, and so the delegation loop can walk a chain of registries
/// (v3 -> v2 -> v1) without knowing any of their concrete types.
///
/// @dev `feeVault()` is declared as `address` here even though `RoundManager` declares it as
/// `IFeeVault`; the ABI encoding is identical.
interface IPriorRegistry {
    function priorRegistry() external view returns (address);
    function priorIndex() external view returns (uint256);
    function headIndex() external view returns (uint256);
    function headToken() external view returns (address);
    function genesisToken() external view returns (address);
    function canonical(uint256 index) external view returns (address);
    function poolKeyOf(uint256 index) external view returns (PoolKey memory);
    function indexOf(address token) external view returns (uint256);
    function isCanonical(address token) external view returns (bool);
    function parentOf(address token) external view returns (address);
    function creatorOf(address token) external view returns (address);
    /// @notice True when THIS registry (not one of its ancestors) wrote `token` into its history.
    function ownsToken(address token) external view returns (bool);
    function factory() external view returns (address);
    function feeVault() external view returns (address);
    /// @notice Sunset state, read by an EARLIER version to decide whether the ETH edge and the
    /// attribution trust have moved on to this registry's successor (sunset handover).
    function sunsetAt() external view returns (uint64);
    function successor() external view returns (address);
    function isSunsetEffective() external view returns (bool);
    /// @notice True when this registry has no round that could still crown a link, i.e. its head
    /// is final for as long as it stays sunset. A SUCCESSOR must see `isSunsetEffective() &&
    /// successor() == address(this) && isIdle()` before it adopts the trunk (audit F1).
    function isIdle() external view returns (bool);
    /// @notice True when this registry has adopted the trunk it continues (always meaningful only
    /// for a continuation: a root registry owns its head from the start). A SUCCESSOR must see a
    /// prior that is either a root or `adopted()` before it adopts, or an unadopted intermediate
    /// would let two versions crown the same index (audit 2).
    function adopted() external view returns (bool);
}
