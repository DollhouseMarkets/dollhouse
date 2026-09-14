// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/src/types/Currency.sol";

interface IFeeVault {
    /// @notice Fee bookkeeping pushed by the hook inside a swap. The claims themselves are
    /// ERC-6909 balances the hook already minted to this vault; this call only splits them.
    /// @param currency The parent currency the fee was taken in (native ETH on the genesis pool).
    /// @param parentToken The token whose pool produced the hop fee (address(0) = genesis/ETH).
    /// @param hopFee Parent-side hop fee (plus any snipe tax), protocol-owned reinforcement.
    /// @param protocolFee 1% ETH-edge fee; zero on every non-genesis pool.
    /// @param terminalIndex Canonical index of the attributed terminal token.
    /// @param attributed False when the swap did not come through the canonical router.
    /// @dev Reentrancy-locked: the post-sunset branch hands control to a successor vault that is
    /// unknown code, and the ledger is complete before it does (F-4).
    function accrue(
        Currency currency,
        address parentToken,
        uint256 hopFee,
        uint256 protocolFee,
        uint256 terminalIndex,
        bool attributed
    ) external;

    /// @notice SUNSET HANDOVER: book `amount` of already-delivered ETH-edge fee on this
    /// version's ledgers, with this version's own split constants. Callable only by the FeeVault
    /// of a version this one continues; the value arrives in the same call as an ERC-6909 claim
    /// that vault transferred, so there is nothing to pull.
    /// @param attribution The attribution the charging hook accepted, interpreted against THIS
    /// version's registry (a prior-era canonical index still resolves, by delegation).
    /// `type(uint256).max` means the swap was unattributed.
    /// @param amount ETH (as a PoolManager claim) already transferred to this vault.
    /// @param hopsLeft Accepted for ABI compatibility and IGNORED (audit 4): a version that is
    /// itself sunset queues the fee for its own `flushForward` instead of recursing.
    function accrueForwarded(uint256 attribution, uint256 amount, uint256 hopsLeft) external;

    /// @notice SUNSET HANDOVER, flushed leg (audit 4): book `msg.value` of already-delivered
    /// ETH-edge fee, or queue it for this version's own `flushForward` if this version is sunset
    /// too. Callable only by the FeeVault of a version this one continues; the value arrives as
    /// real ETH, because a flush runs outside a swap and can redeem its claims first.
    function receiveForward(uint256 attribution) external payable;

    /// @notice Earmark forfeited candidate bonds as an ETH bid under genesis (RoundManager only).
    function depositGenesisBidEarmark() external payable;

    /// @notice The current recipient of the developer fee share; the factory snapshots it as the
    /// initial beneficiary of the genesis developer allocation.
    function developer() external view returns (address);
}
