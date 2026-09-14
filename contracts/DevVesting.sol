// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DevVesting
/// @notice The Dollhouse developer allocation: a share of the GENESIS token supply, held here
/// and released to a single beneficiary on a fixed, immutable schedule. There is no owner, no
/// pause, no clawback and no acceleration: nobody — beneficiary included — can change the
/// schedule, revoke it, or take a token out ahead of it. The only mutable thing in this contract
/// is WHO receives the released tokens, and that moves on the same public 7-day delay the
/// steward and the developer fee address move on ({announceBeneficiaryTransfer}), so a lost key
/// can be recovered before the cliff without giving anyone power over the schedule itself.
///
/// @dev Schedule, stated exactly (this is the part that is easy to get wrong): the linear
/// accrual runs from `start` over `duration`, but NOTHING is releasable until `start + cliff`.
/// At the cliff, therefore, the amount that has accrued linearly SINCE `start` — `cliff/duration`
/// of the allocation — unlocks in one step, and the rest continues to accrue linearly until
/// `start + duration`. With the mainnet constants (cliff 30 days, duration 365 days) the cliff
/// releases 30/365 ≈ 8.2% of the allocation, not zero and not a thirteenth.
///
/// The allocation is not stored: it is `balanceOf(this) + released`, so a transfer of extra
/// tokens to this contract simply vests on the same schedule, and {release} can never pay out
/// more than has actually arrived.
contract DevVesting {
    using SafeERC20 for IERC20;

    /// @notice Public delay between announcing a beneficiary transfer and being able to execute
    /// it. Identical to `RoundManager.ROLE_TRANSFER_DELAY` and `FeeVault.ROLE_TRANSFER_DELAY`.
    uint64 public constant ROLE_TRANSFER_DELAY = 7 days;

    /// @notice The vesting token (the genesis FamilyToken).
    IERC20 public immutable token;
    /// @notice Unix timestamp the linear accrual starts at (the genesis creation timestamp).
    uint64 public immutable start;
    /// @notice Seconds after {start} before anything is releasable.
    uint64 public immutable cliff;
    /// @notice Seconds after {start} at which the whole allocation is vested.
    uint64 public immutable duration;

    /// @notice Who {release} pays. Transferable on a {ROLE_TRANSFER_DELAY} announce/execute.
    address public beneficiary;
    /// @notice Total released so far.
    uint256 public released;

    /// @notice The announced next beneficiary, or address(0) when nothing is pending.
    address public pendingBeneficiary;
    /// @notice The timestamp {executeBeneficiaryTransfer} becomes callable at, or 0.
    uint64 public beneficiaryTransferAt;

    event Released(address indexed to, uint256 amount);
    event BeneficiaryTransferAnnounced(address indexed from, address indexed to, uint64 effectiveAt);
    event BeneficiaryTransferExecuted(address indexed from, address indexed to);
    event BeneficiaryTransferCancelled(address indexed from, address indexed cancelled);

    error BadSchedule();
    error NotBeneficiary();
    error BadRecipient();
    error TransferPending();
    error NoTransferPending();
    error TransferNotReady();
    error NothingToRelease();

    /// @param _token The vesting token.
    /// @param _beneficiary The initial recipient; may never be address(0).
    /// @param _start Unix timestamp the linear accrual starts at.
    /// @param _cliff Seconds after `_start` before anything is releasable (may be 0).
    /// @param _duration Seconds after `_start` at which everything is vested; must be at least
    /// `_cliff` and non-zero.
    constructor(IERC20 _token, address _beneficiary, uint64 _start, uint64 _cliff, uint64 _duration) {
        if (address(_token) == address(0) || _beneficiary == address(0)) revert BadRecipient();
        if (_duration == 0 || _duration < _cliff) revert BadSchedule();
        token = _token;
        beneficiary = _beneficiary;
        start = _start;
        cliff = _cliff;
        duration = _duration;
    }

    /// @notice The whole allocation this contract will ever release: what it still holds plus
    /// what it has already paid out.
    function total() public view returns (uint256) {
        return token.balanceOf(address(this)) + released;
    }

    /// @notice How much of {total} has vested as of `timestamp`.
    /// @dev Zero strictly before `start + cliff`; from the cliff onwards it is the plain linear
    /// share of the time elapsed SINCE `start` (so the cliff unlocks `cliff/duration` at once),
    /// and it is the whole allocation from `start + duration`.
    function vested(uint64 timestamp) public view returns (uint256) {
        if (timestamp < start + cliff) return 0;
        uint256 allocation = total();
        if (timestamp >= start + duration) return allocation;
        return (allocation * (timestamp - start)) / duration;
    }

    /// @notice How much can be released right now.
    function releasable() public view returns (uint256) {
        return vested(uint64(block.timestamp)) - released;
    }

    /// @notice Release everything vested so far to {beneficiary}. Callable by anyone: the
    /// destination is fixed, so there is nothing to gain by calling it for someone else.
    function release() external returns (uint256 amount) {
        amount = releasable();
        if (amount == 0) revert NothingToRelease();
        released += amount;
        address to = beneficiary;
        token.safeTransfer(to, amount);
        emit Released(to, amount);
    }

    // -------------------------------------------------------------------------------------
    // beneficiary transfer: announce -> wait ROLE_TRANSFER_DELAY -> execute
    // -------------------------------------------------------------------------------------

    /// @notice Announce a transfer of the beneficiary right to `to`. Current beneficiary only,
    /// one pending transfer at a time; {cancelBeneficiaryTransfer} to replace it.
    function announceBeneficiaryTransfer(address to) external {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        if (to == address(0)) revert BadRecipient();
        if (beneficiaryTransferAt != 0) revert TransferPending();
        uint64 at = uint64(block.timestamp) + ROLE_TRANSFER_DELAY;
        pendingBeneficiary = to;
        beneficiaryTransferAt = at;
        emit BeneficiaryTransferAnnounced(msg.sender, to, at);
    }

    /// @notice Execute an announced transfer once its delay has elapsed. Permissionless, so a
    /// beneficiary who has lost the announcing key can still be replaced by the new holder.
    function executeBeneficiaryTransfer() external {
        if (beneficiaryTransferAt == 0) revert NoTransferPending();
        if (block.timestamp < beneficiaryTransferAt) revert TransferNotReady();
        address from = beneficiary;
        address to = pendingBeneficiary;
        beneficiary = to;
        pendingBeneficiary = address(0);
        beneficiaryTransferAt = 0;
        emit BeneficiaryTransferExecuted(from, to);
    }

    /// @notice Take an announced transfer back before it takes effect. Current beneficiary only.
    function cancelBeneficiaryTransfer() external {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        if (beneficiaryTransferAt == 0) revert NoTransferPending();
        address cancelled = pendingBeneficiary;
        pendingBeneficiary = address(0);
        beneficiaryTransferAt = 0;
        emit BeneficiaryTransferCancelled(msg.sender, cancelled);
    }
}

/// @title DevVestingDeployer
/// @notice A one-function, permissionless helper that CREATEs a {DevVesting}. It exists purely
/// for EIP-3860: the FamilyFactory already embeds the Locker, the hook and the RoundManager in
/// its own init code, and carrying DevVesting's creation code as well put the factory's
/// deployment transaction over the 49,152-byte initcode limit. The factory is deployed AFTER
/// this contract and holds its address as an immutable, so the vesting contract the factory
/// creates at genesis is still created in the genesis transaction, with arguments only the
/// factory chooses.
contract DevVestingDeployer {
    /// @notice Deploy a {DevVesting}. Callable by anyone - a vesting contract deployed by a
    /// stranger holds nothing and is referenced by nothing; only the one the factory creates at
    /// genesis is ever funded.
    function deploy(IERC20 token, address beneficiary, uint64 start, uint64 cliff, uint64 duration)
        external
        returns (DevVesting vesting)
    {
        vesting = new DevVesting(token, beneficiary, start, cliff, duration);
    }
}
