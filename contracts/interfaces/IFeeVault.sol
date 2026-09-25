// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "v4-core/src/types/Currency.sol";

interface IFeeVault {
    /// @notice Fee bookkeeping pushed by the hook inside a swap. The claims themselves are
    /// ERC-6909 balances the hook already minted to this vault; this call only splits them.
    /// @param currency The parent currency the fee was taken in (the edge currency on an edge
    /// pool, the parent token on every other pool).
    /// @param parentToken The token whose pool produced the hop fee.
    /// @param hopFee Parent-side hop fee (plus any snipe tax), protocol-owned reinforcement.
    /// @param protocolFee The 1% edge fee; zero on every non-edge pool, and zero on an edge pool
    /// for the duration of its snipe window.
    /// @param terminalIndex Canonical index of the attributed terminal token.
    /// @param attributed False when the swap did not come through the canonical router.
    /// @dev Reentrancy-locked: the post-sunset branch hands control to a successor vault that is
    /// unknown code, and the ledger is complete before it does.
    function accrue(
        Currency currency,
        address parentToken,
        uint256 hopFee,
        uint256 protocolFee,
        uint256 terminalIndex,
        bool attributed
    ) external;

    /// @notice SUNSET HANDOVER: book `amount` of already-delivered edge fee on this version's
    /// ledgers, with this version's own split constants. Callable only by the FeeVault of a
    /// version this one continues; the value arrives in the same call as an ERC-6909 claim that
    /// vault transferred, so there is nothing to pull.
    /// @param attribution The attribution the charging hook accepted, interpreted against THIS
    /// version's registry (a prior-era canonical index still resolves, by delegation).
    /// `type(uint256).max` means the swap was unattributed.
    /// @param amount Edge currency (as a PoolManager claim) already transferred to this vault.
    /// @param hopsLeft Accepted for ABI compatibility and IGNORED: a version that is
    /// itself sunset queues the fee for its own `flushForward` instead of recursing.
    function accrueForwarded(uint256 attribution, uint256 amount, uint256 hopsLeft) external;

    /// @notice SUNSET HANDOVER, flushed leg: book `amount` of already-delivered edge
    /// fee, or queue it for this version's own `flushForward` if this version is sunset too.
    /// Callable only by the FeeVault of a version this one continues; the tokens arrive as a real
    /// balance in the instruction before this call, because a flush runs outside a swap and can
    /// redeem its claims first. The receiving vault verifies the delivery against its own
    /// solvency inequality.
    function receiveForward(uint256 attribution, uint256 amount) external;

    /// @notice Earmark forfeited candidate bonds as an edge-currency bid under link one
    /// (RoundManager only). The tokens are transferred in the instruction before this call.
    function depositEdgeBidEarmark(uint256 amount) external;

    /// @notice The current recipient of the developer fee share.
    function developer() external view returns (address);
}
