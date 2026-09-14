// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "./interfaces/IFamilyHook.sol";
import {IFeeVault} from "./interfaces/IFeeVault.sol";
import {IPriorRegistry} from "./interfaces/IPriorRegistry.sol";
import {IRandomnessSource} from "./interfaces/IRandomnessSource.sol";
import {FenwickRangeAdd} from "./libraries/FenwickRangeAdd.sol";
import {V4UnlockGuard} from "./libraries/V4UnlockGuard.sol";

/// @title RoundManager
/// @notice The succession state machine and the canonical history of the family. No owner, no
/// pause, no upgrade: rounds open on demand when someone registers the first candidate, phases
/// are pure functions of `block.timestamp`, scores are submitted permissionlessly out of the
/// hook's own accumulator, and `finalize()` is deterministic and idempotent.
///
/// Lifecycle (DESIGN_BRIEF_v2 sec.2, and `sim/rounds.py`):
///
///   Idle -> Registration ({REGISTRATION_S}) -> Trading ({TRADING_S}, all candidates share
///   `tradingStart`) -> Submission ({SUBMIT_S}) -> finalize() -> Idle
///
/// The scores are snapshots as of `T_end`: `submitScore` reads `(acc, R, tLast)` from the hook
/// and tail-extends, `avg = (acc + R * (T_end - tLast)) / TRADING_S`. The hook freezes its own
/// accumulator on the first swap at or after `T_end`, so a post-bell dump cannot move an
/// average, and the submission window (attack-log finding 1) makes submit-and-finalize-atomically
/// impossible: a low score submitted first cannot exclude a better one submitted later.
/// @title RoundManagerDeployer
/// @notice The helper the {FamilyFactory} CREATEs its RoundManager through, exactly as it does
/// its {DevVesting}. Its only purpose is EIP-3860: the RoundManager's init code is a third of the
/// factory's deployment transaction, and the adaptive schedule plus the random end pushed that
/// transaction over the 49,152-byte limit. Deploying it from here moves those bytes into their
/// own transaction. No state and no owner; whoever calls it gets a RoundManager whose `factory` is
/// the CALLER, so it can only ever produce a contract wired to the caller.
contract RoundManagerDeployer {
    function deploy(
        IFamilyHook hook,
        IFeeVault feeVault,
        uint256 hFracWad,
        uint256 hMinFracWad,
        RoundManager.Bond memory bond,
        uint256 maxIndex,
        address steward,
        uint64 sunsetDelay,
        RoundManager.Continuation memory continuation,
        RoundManager.EndRandomness memory end
    ) external returns (RoundManager) {
        return new RoundManager(
            msg.sender, hook, feeVault, hFracWad, hMinFracWad, bond, maxIndex, steward, sunsetDelay, continuation, end
        );
    }
}

contract RoundManager {
    // -------------------------------------------------------------------------------------
    // deploy constants
    // -------------------------------------------------------------------------------------

    /// @notice ADAPTIVE SCHEDULE (MECHANISM_v3 sec.2). The whole timetable of round `n` is a
    /// pure function of `n` - nobody, steward included, can influence it:
    ///
    ///   D(n) = min(15 min * 2^floor((n-1)/2), 12 h)     {durationFor}
    ///   R(n) = clamp(D(n)/5, 3 min, 1 h)                {registrationFor}
    ///   late entry iff D(n) >= 1 h, for the first D(n)/3 of trading   {lateEntryUntil}
    ///
    /// | n     | D      | R      | late entry |
    /// | 1-2   | 15 min | 3 min  | no         |
    /// | 3-4   | 30 min | 6 min  | no         |
    /// | 5-6   | 1 h    | 12 min | 20 min     |
    /// | 7-8   | 2 h    | 24 min | 40 min     |
    /// | 9-10  | 4 h    | 48 min | 80 min     |
    /// | 11-12 | 8 h    | 1 h    | 2 h 40 min |
    /// | 13+   | 12 h   | 1 h    | 4 h        |
    uint64 public constant BASE_TRADING_S = 15 minutes;
    uint64 public constant MAX_TRADING_S = 12 hours;
    uint64 public constant MIN_REGISTRATION_S = 3 minutes;
    uint64 public constant MAX_REGISTRATION_S = 1 hours;
    /// @notice Late entry is offered only from the duration at which a five-minute registration
    /// would starve a good coin of the chance to enter at all.
    uint64 public constant LATE_ENTRY_FROM_S = 1 hours;
    /// @notice Submission window: 5 minutes after `T_end` is known.
    uint64 public constant SUBMIT_S = 300;
    /// @notice THE CLOSING WINDOW `W`, before the testnet divisor: a flat 15 minutes on every
    /// round. See {closingWindowFor}.
    uint64 public constant CLOSING_WINDOW_S = 15 minutes;
    /// @notice RANDOM END (MECHANISM_v3 sec.3): the true end falls uniformly in the last
    /// {RANDOM_END_S} seconds before the nominal end `T`. It is exactly the span the hook's
    /// score ring covers ({IFamilyHook} `SCORE_RING_S`), and it is never longer than the round
    /// itself - which only binds on a testnet where {DURATION_SCALE_DIV} shrinks the schedule.
    uint64 public constant RANDOM_END_S = 180;
    /// @notice Floor on the coarse score-ring spacing: the hook's own fast-ring slot.
    uint64 public constant SCORE_MIN_SLOT_S = 5;
    /// @notice Public delay between announcing a transfer of the steward role and being able to
    /// execute it. Identical to `FeeVault.ROLE_TRANSFER_DELAY` and `DevVesting.ROLE_TRANSFER_DELAY`.
    uint64 public constant ROLE_TRANSFER_DELAY = 7 days;
    /// @notice The smallest public delay a deployment may set between {announceSunset} and the
    /// moment it stops opening new rounds. A testnet run needs a short handover to exercise
    /// sunset -> adoption live; an hour is the floor below which the announcement stops being a
    /// public warning at all.
    uint64 public constant MIN_SUNSET_DELAY = 1 hours;
    /// @notice How many registries deep a continuation chain (v3 -> v2 -> v1 -> ...) may be
    /// walked before a delegated read gives up. Bounds the gas of every canonical read.
    uint256 public constant MAX_CONTINUATION_HOPS = 8;
    /// @notice Threshold decay bookkeeping.
    /// @dev Threshold decay on a failed round: x0.9, floored at `H_MIN`.
    uint256 internal constant DECAY_NUM = 9;
    uint256 internal constant DECAY_DEN = 10;

    enum Phase {
        Idle,
        Registration,
        Trading,
        /// @notice Past the nominal end `T`, waiting for the randomness that fixes `T_end`.
        EndPending,
        Submission,
        Finalizable,
        Finalized
    }

    /// @param nominalEnd `T`: the published end of trading. Nothing swapped after it counts.
    /// @param tradingEnd `T_end = T - (r mod randomEndWindowFor(n))`: the TRUE end, zero until the
    /// randomness lands (or the timeout fires).
    /// @param lateEntryEnd Last moment a late entrant may register, or 0 when the round's
    /// duration does not offer late entry.
    /// @param randomId The id {randomness} pinned at `T`. It carries no "unset" meaning of its
    /// own: whether {requestEnd} has run is `endRequested` (F-3).
    /// @param endRequested True once {requestEnd} has pinned this round's beacon. An explicit
    /// flag rather than `randomId != 0`, so that a source returning a zero id cannot silently
    /// disarm the once-per-round guard.
    struct Round {
        uint64 openedAt;
        uint64 registrationEnd;
        uint64 tradingStart;
        uint64 lateEntryEnd;
        uint64 nominalEnd;
        uint64 tradingEnd;
        uint64 submitEnd;
        bool finalized;
        bool hasWinner;
        bool hasBest;
        bool endRequested;
        bytes32 randomId;
        uint256 hUsed;
        /// @notice The bond every candidate of THIS round posts, fixed when the round opens:
        /// {bondFor} of the index the round is competing for (F6).
        uint256 bondWei;
        uint256 parentIndex;
        address parentToken;
        uint256 candidateCount;
        uint256 bestCandidateId;
        uint256 winnerCandidateId;
        int256 bestAvg;
        uint64 bestAttained;
        bytes32 bestPoolId;
    }

    /// @param tradingStart This candidate's OWN window start: the round's `tradingStart`, or the
    /// moment it registered if it came in through the late-entry window (MECHANISM_v3 sec.2).
    /// There is no time-based scoring penalty; a late entrant is simply averaged over its own,
    /// shorter window, which is at least two thirds of the round.
    struct Candidate {
        uint256 roundId;
        address token;
        address creator;
        /// @notice The bond this candidate actually posted (F6): refunded to the winner,
        /// forfeited by the losers, whatever the schedule says today.
        uint256 bond;
        bool submitted;
        uint64 tradingStart;
        int256 avg;
        uint64 tFirstAttained;
        PoolKey key;
    }

    // -------------------------------------------------------------------------------------
    // immutable wiring
    // -------------------------------------------------------------------------------------

    address public immutable factory;
    IFamilyHook public immutable hook;
    IFeeVault public immutable feeVault;
    /// @notice The one address that may {announceSunset}, and nothing else: it cannot pause a
    /// round, touch a pool, move a wei or name a second successor. `address(0)` means this
    /// version can NEVER be sunset — and stays that way, because a transfer can only be
    /// announced by the current steward. Transferable on a public {ROLE_TRANSFER_DELAY} delay
    /// ({announceStewardTransfer}); every sunset power follows the role, immediately and
    /// entirely, the moment the transfer executes.
    address public steward;
    /// @notice Public delay between {announceSunset} and the moment this version stops opening
    /// new rounds (README "Upgrade model"): a deploy constant, 7 days on mainnet and as little as
    /// {MIN_SUNSET_DELAY} on a testnet, where a seven-day wait would make the handover
    /// untestable.
    uint64 public immutable sunsetDelay;
    /// @notice The registry this deployment CONTINUES, or `address(0)` for a fresh trunk. Every
    /// canonical index at or below {priorIndex} is resolved by delegating to it.
    address public immutable priorRegistry;
    /// @notice Entry bond schedule (F6). The bond DOUBLES every {BOND_DOUBLING_EVERY} links and
    /// is capped at {BOND_MAX_WEI}, so extending the chain does not become free once a link is
    /// worth a few percent of its parent: see {bondFor}.
    uint256 public immutable BOND_BASE_WEI;
    uint256 public immutable BOND_DOUBLING_EVERY;
    uint256 public immutable BOND_MAX_WEI;
    /// @notice Hard cap on the canonical index this deployment will ever crown. A capped BETA
    /// deployment sets it so that the depth economics stay inside the range the simulations
    /// cover; it is a deploy constant, not a policy, and cannot be raised.
    /// @dev There is no "no cap": the ancestor sleeve is three Fenwick trees over
    /// {FenwickRangeAdd.MAX_INDEX} + 1 generations, so an index past that cannot be paid at all.
    /// A constructor argument of 0 therefore means the Fenwick cap, and anything above it is
    /// refused at construction rather than crowning a link whose sleeve would revert.
    uint256 public immutable MAX_INDEX;
    /// @notice Base threshold as a fraction of the parent supply (WAD), `h` in the brief.
    uint256 public immutable H_FRAC_WAD;
    /// @notice Floor the threshold decays to, as a fraction of the parent supply (WAD).
    uint256 public immutable H_MIN_FRAC_WAD;
    /// @notice The provable-randomness source that fixes the random end (MECHANISM_v3 sec.3).
    /// Immutable and permissionless: this contract only ever asks it to pin a future event and
    /// to verify somebody else's proof of it. `address(0)` disables the random end entirely and
    /// every round ends deterministically at `T`.
    IRandomnessSource public immutable randomness;
    /// @notice How long after the nominal end `T` anyone may finalize the round DETERMINISTICALLY
    /// at `T_end = T` because the beacon was never relayed. A deploy constant (30 min at the
    /// target), never zero: the liveness of a public beacon is a trust assumption, and this is
    /// the bound on what it can cost the round.
    uint64 public immutable END_TIMEOUT;
    /// @notice TESTNET ONLY. Divides every value of the adaptive schedule, so that a 12-hour
    /// round can be exercised end to end in 12 minutes. 1 on mainnet; the deploy script refuses
    /// anything else outside a testnet run. It scales D, R and the late-entry window, and never
    /// {RANDOM_END_S}, which is capped at the (scaled) duration instead.
    uint64 public immutable DURATION_SCALE_DIV;
    // -------------------------------------------------------------------------------------
    // state
    // -------------------------------------------------------------------------------------

    /// @notice Current threshold as a fraction of the head supply (WAD): {H_FRAC_WAD} after any
    /// win, decaying x0.9 per CONSECUTIVE failed round down to {H_MIN_FRAC_WAD}.
    uint256 public hWad;

    /// @notice Canonical history: `canonical(i)` is the token that holds index `i`, immutable
    /// once written. `canonical(0)` is genesis. The backing maps are internal because a
    /// CONTINUATION deployment owns only the indices above {priorIndex} and answers everything
    /// below by delegating to the registry it continues; the public readers below do that.
    mapping(uint256 => address) internal _canonical;
    mapping(uint256 => PoolKey) internal canonicalKey;
    mapping(address => uint256) internal _indexOf;
    mapping(address => bool) internal _isCanonical;
    mapping(address => address) internal _parentOf;
    mapping(address => address) internal _creatorOf;

    /// @notice Timestamp from which this version refuses to OPEN a new round, or 0 while no
    /// sunset has been announced. Set {sunsetDelay} in the future, and cleared only by the one
    /// permitted {cancelSunset} - which is impossible once the sunset has taken effect.
    uint64 public sunsetAt;
    /// @notice The announced next steward, or address(0) when nothing is pending.
    address public pendingSteward;
    /// @notice The timestamp {executeStewardTransfer} becomes callable at, or 0.
    uint64 public stewardTransferAt;
    /// @notice True once {cancelSunset} has been used. It is a ONE-SHOT escape hatch: a steward
    /// who announces a second sunset can no longer take it back.
    bool public sunsetCancelled;
    /// @notice The deployment the steward pointed successors at. Advisory: this contract never
    /// calls it, and nothing about this version's behaviour depends on what it does.
    address public successor;

    /// @notice Index of the current head, and the head token itself - but ONLY once this
    /// deployment has adopted a head. Read them through {headIndex} and {head}, which delegate to
    /// the prior registry until then (F1).
    uint256 internal _headIndex;
    address internal _head;

    /// @notice LAZY HEAD ADOPTION (F1). A continuation deployment adopts the prior trunk's head
    /// the moment it opens its FIRST round, not at construction: until then the prior version is
    /// still crowning links, and a head read at deploy time would fork the trunk at every win
    /// during the 7-day sunset delay. Adoption is allowed only when the prior version is
    /// sunset-effective, names THIS contract as its successor and is idle (its last round
    /// finalized), which is exactly the moment the prior trunk can no longer move.
    bool public adopted;
    /// @notice The prior registry's head index AT ADOPTION: the last index this deployment does
    /// not own. Written once, with {adopted}; read through {priorIndex}.
    uint256 internal _priorIndex;

    uint256 public roundCount;
    mapping(uint256 => Round) internal rounds;
    mapping(uint256 => uint256[]) internal roundCandidates;
    Candidate[] internal candidates;

    /// @notice The round that CROWNED canonical index `i`, so that the generation's siblings -
    /// winner and losers alike - can be found forever. Written once, at finalization.
    mapping(uint256 => uint256) internal _roundOfIndex;
    /// @notice Bond refunds that could not be pushed to a creator (pull fallback).
    mapping(address => uint256) public pendingRefund;

    uint256 private _locked = 1;

    // -------------------------------------------------------------------------------------
    // events
    // -------------------------------------------------------------------------------------

    event GenesisRegistered(address indexed token, address indexed creator, PoolId poolId);
    event RoundOpened(
        uint256 indexed roundId, uint256 parentIndex, address indexed parentToken, uint64 registrationEnd, uint256 h
    );
    event CandidateRegistered(
        uint256 indexed roundId, uint256 indexed candidateId, address indexed token, address creator, PoolId poolId
    );
    /// @notice Trading is implicit — it starts by the clock, not by a call — so the schedule is
    /// announced when the round opens. `nominalEnd` is `T`; the TRUE end is drawn later.
    event TradingStarted(uint256 indexed roundId, uint64 tradingStart, uint64 nominalEnd, uint64 lateEntryEnd);
    /// @notice The randomness that will fix `T_end` was pinned at `T`. From this moment the
    /// offset is committed to a value that does not exist yet.
    event EndRequested(uint256 indexed roundId, bytes32 randomId, address requester);
    /// @notice The beacon was relayed and verified: the round really ended at `tradingEnd`.
    event EndFulfilled(uint256 indexed roundId, uint256 word, uint64 tradingEnd, uint64 submitEnd);
    /// @notice DISCLOSED FALLBACK (MECHANISM_v3 sec.3): nobody relayed a verifiable beacon within
    /// {END_TIMEOUT} of `T`, so this round ended deterministically at `T` and had no random end.
    event RandomEndUnavailable(uint256 indexed roundId, uint64 tradingEnd, uint64 submitEnd);
    event ScoreSubmitted(
        uint256 indexed roundId, uint256 indexed candidateId, int256 avg, uint64 tFirstAttained, address submitter
    );
    event RoundFinalized(
        uint256 indexed roundId, bool hasWinner, uint256 winnerCandidateId, int256 bestAvg, uint256 hUsed, uint256 hNext
    );
    event HeadChanged(uint256 indexed index, address indexed token, address indexed parent);
    event BondRefunded(address indexed creator, uint256 amount, bool pushed);
    event BondsForfeited(uint256 indexed roundId, uint256 amount);
    /// @notice The one and only steward action: after `sunsetAt` this version opens no new round.
    event SunsetAnnounced(address indexed steward, address indexed successor, uint64 sunsetAt);
    /// @notice Emitted once at construction when this deployment continues an earlier registry.
    /// The head is NOT read here: see {ContinuationAdopted} (F1).
    event ContinuedFrom(address indexed priorRegistry);
    /// @notice Emitted once, when this deployment finally adopts the prior trunk's head - at the
    /// opening of its first round, after the prior version has stopped for good.
    event ContinuationAdopted(address indexed priorRegistry, uint256 priorIndex, address priorHead);
    event StewardTransferAnnounced(address indexed from, address indexed to, uint64 effectiveAt);
    event StewardTransferExecuted(address indexed from, address indexed to);
    event StewardTransferCancelled(address indexed from, address indexed cancelled);
    /// @notice The steward took an announced sunset back BEFORE it took effect. Allowed once.
    event SunsetCancelled(address indexed steward, address indexed successor);

    // -------------------------------------------------------------------------------------
    // errors
    // -------------------------------------------------------------------------------------

    error NotFactory();
    error GenesisAlreadyRegistered();
    error NoGenesis();
    error RegistrationClosed();
    error WrongBond();
    error UnknownCandidate();
    error OutsideSubmissionWindow();
    error SubmissionWindowOpen();
    error NoRound();
    error Reentrancy();
    error NothingToClaim();
    error NotSteward();
    /// @notice A steward transfer is already announced; cancel it before announcing another.
    error TransferPending();
    error NoTransferPending();
    error TransferNotReady();
    error BadSteward();
    error SunsetAlreadyAnnounced();
    /// @notice {cancelSunset} was called with nothing to cancel, after the sunset had already
    /// taken effect, or a second time.
    error SunsetNotCancellable();
    error SuccessorHasNoCode();
    /// @notice This version has been sunset: it finishes the round it has and opens no more.
    error Sunset(address successor);
    /// @notice The continuation chain is longer than {MAX_CONTINUATION_HOPS} registries.
    error ContinuationDepthLimit();
    /// @notice A continuation must start from a registry that already has a head.
    error BadContinuation();
    /// @notice F1: this continuation may not open a round yet. The prior version must be
    /// sunset-effective, must name THIS contract as its successor, and must be idle (its last
    /// round finalized) before the trunk can be adopted - otherwise both versions would crown
    /// links at the same index and the trunk would fork.
    error PriorNotHandedOver();
    /// @notice Audit 2: the immediate prior is itself a continuation that has NOT adopted, so its
    /// head is still its own prior's live head and a version before it can still crown links at
    /// that index. Adopting through it would fork the trunk. The prior must either be a root (no
    /// `priorRegistry`) or have adopted its own trunk first.
    error PriorNotAdopted();
    /// @notice Audit 2: this continuation cannot hand a trunk it has never adopted to a further
    /// successor - that is exactly the unadopted intermediate that forks the trunk.
    error NotAdopted();
    /// @notice The sunset delay is below {MIN_SUNSET_DELAY}.
    error BadSunsetDelay();
    /// @notice The next canonical index would exceed {MAX_INDEX}.
    error ChainDepthLimit();
    /// @notice The deploy-time depth cap is deeper than the ancestor sleeve can address.
    error BadMaxIndex();
    /// @notice {requestEnd} before the nominal end `T`, or twice.
    error EndNotDue();
    error EndAlreadyRequested();
    /// @notice {fulfilEnd} with no pinned randomness, or after the end was already settled.
    error EndNotRequested();
    error EndAlreadySettled();
    /// @notice {finalizeDeterministic} before `T + END_TIMEOUT`.
    error TimeoutNotReached();
    /// @notice The round's true end has not been settled yet: scores cannot be read at a time
    /// nobody knows.
    error EndNotSettled();
    /// @notice REN-01: a round-machine transition was attempted from inside a v4 `PoolManager`
    /// unlock, i.e. with somebody's flash accounting still open. The round machine is never
    /// reached from inside the protocol's own unlocks, so this can only be an external caller
    /// trying to interleave a transition with a swap it has not settled yet.
    error InsideUnlock();
    /// @notice A deployment with no randomness source cannot draw a random end.
    error NoRandomness();
    /// @notice A schedule value would be zero: {DURATION_SCALE_DIV} is larger than the shortest
    /// window of the schedule.
    error BadDurationScale();

    /// @notice REN-01 (defence in depth). Refuse any round-machine transition made from inside a
    /// v4 `PoolManager` unlock.
    ///
    /// @dev The state is v4-core's own transient lock flag, read with one `exttload` through the
    /// hook's PoolManager. None of the guarded entrypoints is ever reached from inside one of the
    /// protocol's own unlocks: the hook's `afterSwap` and the vault's `accrue` are the only code
    /// that runs there, and neither touches the round machine. What it excludes is an external
    /// contract opening its own unlock, swapping, and settling a round in the same frame.
    modifier notInsideUnlock() {
        if (V4UnlockGuard.isInsideUnlock(address(hook.poolManager()))) revert InsideUnlock();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @param priorRegistry The registry to CONTINUE, or `address(0)` for a fresh trunk.
    struct Continuation {
        address priorRegistry;
    }

    /// @param source The provable-randomness source, or `address(0)` for no random end at all.
    /// @param endTimeout Seconds after `T` before the deterministic fallback opens.
    /// @param durationScaleDiv Testnet schedule divisor; 1 on mainnet.
    struct EndRandomness {
        address source;
        uint64 endTimeout;
        uint64 durationScaleDiv;
    }

    /// @param base The bond for the first {doublingEvery} links.
    /// @param doublingEvery How many links double the bond (0 disables the schedule).
    /// @param max The bond ceiling; also the whole bond when `doublingEvery` is 0.
    struct Bond {
        uint256 base;
        uint256 doublingEvery;
        uint256 max;
    }

    constructor(
        address _factory,
        IFamilyHook _hook,
        IFeeVault _feeVault,
        uint256 hFracWad,
        uint256 hMinFracWad,
        Bond memory bond,
        uint256 maxIndex,
        address _steward,
        uint64 _sunsetDelay,
        Continuation memory continuation,
        EndRandomness memory end
    ) {
        if (_sunsetDelay < MIN_SUNSET_DELAY) revert BadSunsetDelay();
        // the shortest window of the schedule is the 3-minute registration floor; a divisor that
        // rounds it to zero would open rounds with no registration window at all
        if (end.durationScaleDiv == 0 || end.durationScaleDiv > MIN_REGISTRATION_S) revert BadDurationScale();
        randomness = IRandomnessSource(end.source);
        END_TIMEOUT = end.endTimeout;
        DURATION_SCALE_DIV = end.durationScaleDiv;
        sunsetDelay = _sunsetDelay;
        factory = _factory;
        BOND_BASE_WEI = bond.base;
        BOND_DOUBLING_EVERY = bond.doublingEvery;
        BOND_MAX_WEI = bond.max < bond.base ? bond.base : bond.max;
        // the depth cap can never exceed what the ancestor sleeve can address (review 2); 0
        // means "as deep as the sleeve goes", not "unlimited"
        if (maxIndex > FenwickRangeAdd.MAX_INDEX) revert BadMaxIndex();
        MAX_INDEX = maxIndex == 0 ? FenwickRangeAdd.MAX_INDEX : maxIndex;
        hook = _hook;
        feeVault = _feeVault;
        H_FRAC_WAD = hFracWad;
        H_MIN_FRAC_WAD = hMinFracWad;
        hWad = hFracWad;
        steward = _steward;

        // CONTINUATION: the head is NOT read here (F1). Nothing is ever copied - the history at
        // or below `priorIndex` stays where it was written and is read by delegation - and until
        // {openRoundIfIdle} adopts, EVERY read of this contract, head included, is answered by
        // the prior registry, which is still live and still crowning.
        priorRegistry = continuation.priorRegistry;
        if (continuation.priorRegistry != address(0)) {
            if (IPriorRegistry(continuation.priorRegistry).headToken() == address(0)) revert BadContinuation();
            emit ContinuedFrom(continuation.priorRegistry);
        }
    }

    // -------------------------------------------------------------------------------------
    // the adaptive schedule: pure functions of the round number (MECHANISM_v3 sec.2)
    // -------------------------------------------------------------------------------------

    /// @dev `min(15 min * 2^floor((n-1)/2), 12 h)`, BEFORE the testnet divisor. Round 0 does not
    /// exist; it is treated as round 1 so that every view is total.
    function _rawDuration(uint256 n) internal pure returns (uint64) {
        uint256 doublings = n <= 1 ? 0 : (n - 1) / 2;
        // 15 min << 6 is 16 h, already past the cap: everything from there is capped, and the
        // early return also keeps the shift below the width of the type
        if (doublings >= 6) return MAX_TRADING_S;
        uint64 d = uint64(uint256(BASE_TRADING_S) << doublings);
        return d > MAX_TRADING_S ? MAX_TRADING_S : d;
    }

    /// @notice Trading duration of round `n`, in seconds.
    function durationFor(uint256 n) public view returns (uint64) {
        return _rawDuration(n) / DURATION_SCALE_DIV;
    }

    /// @notice Registration window of round `n`: `clamp(D(n)/5, 3 min, 1 h)`. The clamp is
    /// applied to the UNSCALED duration, so a testnet run keeps the same shape.
    function registrationFor(uint256 n) public view returns (uint64) {
        uint64 r = _rawDuration(n) / 5;
        if (r < MIN_REGISTRATION_S) r = MIN_REGISTRATION_S;
        if (r > MAX_REGISTRATION_S) r = MAX_REGISTRATION_S;
        return r / DURATION_SCALE_DIV;
    }

    /// @notice How long after `tradingStart` a LATE ENTRANT may still register in round `n`, or
    /// 0 when the round is too short to offer late entry at all.
    /// @dev Late entry exists because a 3-minute registration on a 12-hour round would starve
    /// good coins of the chance to enter. It is bounded at a third of trading precisely so that
    /// every coin is measured over at least two thirds of the round, which caps what a short
    /// burst can be worth against sustained support at 1.5x per unit of parent.
    function lateEntryUntil(uint256 n) public view returns (uint64) {
        uint64 d = _rawDuration(n);
        if (d < LATE_ENTRY_FROM_S) return 0;
        return (d / 3) / DURATION_SCALE_DIV;
    }

    /// @notice The span the true end `T_end = T - (word mod W_r)` is drawn from in round `n`:
    /// `max(1, min(RANDOM_END_S, D(n) / 4))`.
    ///
    /// @dev On MAINNET this is a no-op. The shortest round is `BASE_TRADING_S` = 15 min, so
    /// `D(n) / 4 >= 225 s > RANDOM_END_S`, and the window is always {RANDOM_END_S} exactly.
    ///
    /// The quarter-duration clamp exists for a heavily SCALED testnet schedule, where
    /// {DURATION_SCALE_DIV} can make `D(n)` shorter than, or barely longer than, the 180-second
    /// random span. Drawing the end out of a window comparable to the whole round can put `T_end`
    /// at or before `tradingStart`, which leaves a round with no tradable span to score. Taking
    /// at most a quarter of the round keeps the last three quarters unconditionally inside the
    /// round. The `max(1, ...)` floor keeps the `mod` in {fulfilEnd} defined when a divisor
    /// rounds the quarter to zero.
    function randomEndWindowFor(uint256 n) public view returns (uint64) {
        uint64 w = durationFor(n) / 4;
        if (w > RANDOM_END_S) w = RANDOM_END_S;
        return w == 0 ? 1 : w;
    }

    /// @notice THE CLOSING WINDOW `W` (design decision): every candidate is scored on its average
    /// net parent absorption over `[T_end - W, T_end]`, and nothing else.
    ///
    ///   W = {CLOSING_WINDOW_S} = 15 min, for EVERY round, divided by {DURATION_SCALE_DIV}.
    ///
    /// @dev FLAT, not a fraction of the duration. It used to be `D(n)/4` above an hour (2 h -> 30
    /// min, 12 h -> 3 h); a 15-minute window on every round is simpler to publish and makes `n`
    /// change only how long a coin has to build support, never how that support is measured.
    ///
    /// The SAME window for every candidate, whenever it registered. A late entrant is not
    /// handicapped by a shorter window and not flattered by a longer one: it simply has less time
    /// to build the support level the closing window measures. It is a LEVEL, not a total, so
    /// what wins a round is the support a coin still has when the bell goes.
    ///
    /// Late entry closes at `D/3` and the closing window starts no earlier than `D - W - 180 s`,
    /// which is always later than `D/3` for every duration that offers late entry, so no
    /// candidate can ever be scored over a window that starts before its pool opened. A flat `W`
    /// widens that margin on every round longer than an hour rather than narrowing it.
    function closingWindowFor(uint256) public view returns (uint64) {
        return CLOSING_WINDOW_S / DURATION_SCALE_DIV;
    }

    /// @notice The coarse score-ring spacing round `n`'s candidate pools are registered with:
    /// the ring's 63 usable slots must reach back over the closing window PLUS the WHOLE
    /// settlement tail, because the far edge of the window is read AFTER the round has ended and
    /// swaps keep overwriting the ring while they are read.
    ///
    /// @dev The tail is `RANDOM_END_S + END_TIMEOUT + SUBMIT_S`, not `RANDOM_END_S + SUBMIT_S`.
    /// {fulfilEnd} has no deadline: a round can sit unsettled until `T + END_TIMEOUT`, where
    /// {finalizeDeterministic} opens a submission window of {SUBMIT_S} from THAT moment. So the
    /// last {submitScore} of a round can read the hook at `T + END_TIMEOUT + SUBMIT_S` and must
    /// still resolve `T_end - W`, which is up to `W + RANDOM_END_S` before `T`. Sizing the ring
    /// for the prompt-beacon tail only would leave the far edge of the window overwritten on
    /// exactly the rounds the beacon was late for. {END_TIMEOUT} is a deploy immutable, so the
    /// spacing follows the deployment's own fallback delay.
    function scoreSlotFor(uint256 n) public view returns (uint32) {
        uint64 span = closingWindowFor(n) + RANDOM_END_S + END_TIMEOUT + SUBMIT_S;
        uint64 s = (span + 62) / 63;
        return uint32(s < SCORE_MIN_SLOT_S ? SCORE_MIN_SLOT_S : s);
    }

    // -------------------------------------------------------------------------------------
    // entry bond (F6)
    // -------------------------------------------------------------------------------------

    /// @notice The bond a candidate for canonical index `targetIndex` must post:
    /// `min(BOND_BASE_WEI << (targetIndex / BOND_DOUBLING_EVERY), BOND_MAX_WEI)`.
    ///
    /// @dev A link is empirically worth 5-8% of its parent IN ETH, so a bond fixed in ETH becomes
    /// the only cost of extending the chain from about generation 3 (audit F6). Doubling it every
    /// few links keeps the spam guard meaningful with depth without pricing the early rounds out;
    /// the cap keeps it from becoming a permanent barrier.
    function bondFor(uint256 targetIndex) public view returns (uint256) {
        uint256 every = BOND_DOUBLING_EVERY;
        if (every == 0) return BOND_MAX_WEI;
        uint256 doublings = targetIndex / every;
        if (doublings >= 256) return BOND_MAX_WEI;
        uint256 scaled = BOND_BASE_WEI << doublings;
        // the shift can overflow for a small base and a deep chain: saturate at the cap
        if (scaled >> doublings != BOND_BASE_WEI || scaled > BOND_MAX_WEI) return BOND_MAX_WEI;
        return scaled;
    }

    /// @notice The bond a candidate registering RIGHT NOW must post: the open round's own bond,
    /// or the bond of the index the next round will compete for.
    function currentBond() external view returns (uint256) {
        uint256 roundId = roundCount;
        if (roundId != 0 && !rounds[roundId].finalized) return rounds[roundId].bondWei;
        return bondFor(headIndex() + 1);
    }

    // -------------------------------------------------------------------------------------
    // sunset: the whole privileged surface of this contract
    // -------------------------------------------------------------------------------------

    /// @notice Stop this version from opening any FURTHER round, {sunsetDelay} from now, and
    /// publish the successor deployment. Steward only, and only once; there is no cancel, no
    /// shorten and no second call.
    ///
    /// @dev Deliberately the narrowest switch that makes an upgrade possible. It does not touch
    /// a pool, a balance, a claim or the history: after `sunsetAt` the currently open round still
    /// trades, is still scored, is still finalized and can still crown a head; swaps, fees,
    /// creator and ancestor claims, bond refunds and every history read keep working forever.
    /// The only thing that changes is that {openRoundIfIdle} stops minting new rounds, so the
    /// trunk continues in `successor` instead of forking.
    function announceSunset(address _successor) external {
        if (steward == address(0) || msg.sender != steward) revert NotSteward();
        if (sunsetAt != 0) revert SunsetAlreadyAnnounced();
        if (_successor.code.length == 0) revert SuccessorHasNoCode();
        // audit 2: a continuation that has not adopted owns NOTHING - its head reads are still
        // answered by its own prior, which is still crowning links. If it could announce a
        // sunset, its successor would adopt a head that the version two steps back can still
        // move, and the trunk would fork. It must adopt first (open one round) or never sunset.
        if (priorRegistry != address(0) && !adopted) revert NotAdopted();
        uint64 at = uint64(block.timestamp) + sunsetDelay;
        sunsetAt = at;
        successor = _successor;
        emit SunsetAnnounced(msg.sender, _successor, at);
    }

    /// @notice Take back an announced sunset, BEFORE it takes effect. Steward only, and only
    /// once in the lifetime of the deployment.
    ///
    /// @dev The audit's F2 escape hatch. `announceSunset` names an address that this version's
    /// FeeVault will forward the ETH edge to and whose router its hook will trust; if the steward
    /// discovers that the named successor is broken (or hostile) during the 7-day delay, this is
    /// the only way back. It is deliberately impossible AFTER `sunsetAt`: by then an earlier
    /// version may already have resolved and cached the handover, and un-sunsetting would split
    /// the fee stream. One shot, so announce/cancel cannot be used as a repeatable switch.
    function cancelSunset() external {
        if (steward == address(0) || msg.sender != steward) revert NotSteward();
        if (sunsetAt == 0 || block.timestamp >= sunsetAt || sunsetCancelled) revert SunsetNotCancellable();
        address was = successor;
        sunsetAt = 0;
        successor = address(0);
        sunsetCancelled = true;
        emit SunsetCancelled(msg.sender, was);
    }

    // -------------------------------------------------------------------------------------
    // steward transfer: announce -> wait ROLE_TRANSFER_DELAY -> execute
    // -------------------------------------------------------------------------------------

    /// @notice Announce a transfer of the steward role to `to`, executable {ROLE_TRANSFER_DELAY}
    /// from now. Current steward only, one pending transfer at a time, and `to` may not be
    /// address(0) (use the sunset switch, not the role, to end a deployment).
    /// @dev The delay is the whole point: the only privileged address in the system cannot change
    /// hands silently. Anything the steward could do before the announcement it can still do
    /// during the delay, and nothing new becomes possible when it executes — the role's entire
    /// surface is still {announceSunset} / {cancelSunset}, which then answer to the new holder.
    function announceStewardTransfer(address to) external {
        if (steward == address(0) || msg.sender != steward) revert NotSteward();
        if (to == address(0)) revert BadSteward();
        if (stewardTransferAt != 0) revert TransferPending();
        uint64 at = uint64(block.timestamp) + ROLE_TRANSFER_DELAY;
        pendingSteward = to;
        stewardTransferAt = at;
        emit StewardTransferAnnounced(msg.sender, to, at);
    }

    /// @notice Execute an announced steward transfer once its delay has elapsed. Permissionless:
    /// the destination is fixed by the announcement, and the incoming steward must be able to
    /// take the role even if the outgoing key is gone.
    function executeStewardTransfer() external {
        if (stewardTransferAt == 0) revert NoTransferPending();
        if (block.timestamp < stewardTransferAt) revert TransferNotReady();
        address from = steward;
        address to = pendingSteward;
        steward = to;
        pendingSteward = address(0);
        stewardTransferAt = 0;
        emit StewardTransferExecuted(from, to);
    }

    /// @notice Take an announced steward transfer back before it takes effect. Current steward
    /// only; repeatable, because a wrong destination must always be fixable.
    function cancelStewardTransfer() external {
        if (steward == address(0) || msg.sender != steward) revert NotSteward();
        if (stewardTransferAt == 0) revert NoTransferPending();
        address cancelled = pendingSteward;
        pendingSteward = address(0);
        stewardTransferAt = 0;
        emit StewardTransferCancelled(msg.sender, cancelled);
    }

    /// @notice True once this version has stopped opening new rounds.
    function isSunset() public view returns (bool) {
        return sunsetAt != 0 && block.timestamp >= sunsetAt;
    }

    /// @notice Alias of {isSunset} under the name the cross-version HANDOVER reads: from this
    /// moment the 1% ETH edge charged on this version's genesis pool is forwarded to
    /// {successor}'s FeeVault, and this version's hook also trusts the successor's router for
    /// fee attribution. Declared separately (and in {IPriorRegistry}) so that an earlier or a
    /// later deployment can ask the question without knowing this contract's type.
    function isSunsetEffective() external view returns (bool) {
        return isSunset();
    }

    // -------------------------------------------------------------------------------------
    // continuation: delegated reads
    //
    // A continuation deployment owns indices `priorIndex + 1 ..` and nothing else. Every
    // canonical read below first resolves WHICH registry in the chain owns the entry (at most
    // {MAX_CONTINUATION_HOPS} registries deep, so the gas of a read is bounded), then asks it.
    // The resolved registry answers out of its OWN storage, because the entry it was asked for
    // is by construction above its own `priorIndex`.
    // -------------------------------------------------------------------------------------

    /// @notice The prior registry's head index: the last index this deployment does not own.
    /// Until this deployment has {adopted} a head it owns NOTHING, so the answer is the prior
    /// registry's LIVE head index and every read below delegates (F1).
    function priorIndex() public view returns (uint256) {
        address prior = priorRegistry;
        if (prior == address(0)) return 0;
        if (!adopted) return IPriorRegistry(prior).headIndex();
        return _priorIndex;
    }

    /// @notice Index of the current head, and the head token itself - the prior trunk's until
    /// this deployment adopts it.
    function headIndex() public view returns (uint256) {
        if (priorRegistry != address(0) && !adopted) return IPriorRegistry(priorRegistry).headIndex();
        return _headIndex;
    }

    function head() public view returns (address) {
        if (priorRegistry != address(0) && !adopted) return IPriorRegistry(priorRegistry).headToken();
        return _head;
    }

    /// @notice True when this version is not in the middle of a round: nothing it can still crown.
    /// Read by a SUCCESSOR before it adopts the trunk (F1).
    function isIdle() public view returns (bool) {
        uint256 roundId = roundCount;
        return roundId == 0 || rounds[roundId].finalized;
    }

    /// @notice The registry that owns canonical index `index`: this contract, or one of the
    /// registries it continues.
    function registryOf(uint256 index) public view returns (address registry) {
        if (priorRegistry == address(0) || index > priorIndex()) return address(this);
        address reg = priorRegistry;
        for (uint256 hops = 1;; ++hops) {
            if (hops > MAX_CONTINUATION_HOPS) revert ContinuationDepthLimit();
            address next = IPriorRegistry(reg).priorRegistry();
            if (next == address(0) || index > IPriorRegistry(reg).priorIndex()) return reg;
            reg = next;
        }
    }

    /// @notice The registry that wrote `token` into the canonical history (or registered it as a
    /// candidate). Falls back to this contract for a token nobody in the chain knows, so the
    /// readers below return their zero values rather than reverting.
    function registryOfToken(address token) public view returns (address registry) {
        if (priorRegistry == address(0) || ownsToken(token)) return address(this);
        address reg = priorRegistry;
        for (uint256 hops = 1;; ++hops) {
            if (hops > MAX_CONTINUATION_HOPS) revert ContinuationDepthLimit();
            if (IPriorRegistry(reg).ownsToken(token)) return reg;
            address next = IPriorRegistry(reg).priorRegistry();
            if (next == address(0)) return address(this);
            reg = next;
        }
    }

    /// @notice True when THIS deployment wrote `token` (canonical link or registered candidate).
    function ownsToken(address token) public view returns (bool) {
        return _isCanonical[token] || _creatorOf[token] != address(0);
    }

    /// @notice The token that holds canonical index `index`, across the whole continuation chain.
    function canonical(uint256 index) public view returns (address) {
        address reg = registryOf(index);
        return reg == address(this) ? _canonical[index] : IPriorRegistry(reg).canonical(index);
    }

    function indexOf(address token) public view returns (uint256) {
        address reg = registryOfToken(token);
        return reg == address(this) ? _indexOf[token] : IPriorRegistry(reg).indexOf(token);
    }

    function isCanonical(address token) public view returns (bool) {
        address reg = registryOfToken(token);
        return reg == address(this) ? _isCanonical[token] : IPriorRegistry(reg).isCanonical(token);
    }

    function parentOf(address token) public view returns (address) {
        address reg = registryOfToken(token);
        return reg == address(this) ? _parentOf[token] : IPriorRegistry(reg).parentOf(token);
    }

    function creatorOf(address token) public view returns (address) {
        address reg = registryOfToken(token);
        return reg == address(this) ? _creatorOf[token] : IPriorRegistry(reg).creatorOf(token);
    }

    /// @notice The current head token. Named for the continuation ABI; {head} is the same value.
    function headToken() public view returns (address) {
        return head();
    }

    /// @notice The one and only genesis link, wherever in the continuation chain it was created.
    function genesisToken() external view returns (address) {
        return canonical(0);
    }

    // -------------------------------------------------------------------------------------
    // canonical history
    // -------------------------------------------------------------------------------------

    /// @notice Record the one and only genesis link (factory only, once).
    function registerGenesis(address token, PoolKey calldata key, address creator) external onlyFactory {
        if (_head != address(0) || priorRegistry != address(0)) revert GenesisAlreadyRegistered();
        _canonical[0] = token;
        canonicalKey[0] = key;
        _indexOf[token] = 0;
        _isCanonical[token] = true;
        _parentOf[token] = address(0);
        _creatorOf[token] = creator;
        _head = token;
        _headIndex = 0;
        emit GenesisRegistered(token, creator, key.toId());
    }

    /// @notice The pool that quotes canonical link `index` against its parent. For a prior
    /// version's index this is that version's pool key - same PoolManager, a different hook
    /// address inside the key - which is exactly what a cross-version route needs.
    function poolKeyOf(uint256 index) public view returns (PoolKey memory) {
        address reg = registryOf(index);
        return reg == address(this) ? canonicalKey[index] : IPriorRegistry(reg).poolKeyOf(index);
    }

    function poolIdOf(uint256 index) external view returns (PoolId) {
        return poolKeyOf(index).toId();
    }

    // -------------------------------------------------------------------------------------
    // registration
    // -------------------------------------------------------------------------------------

    /// @notice Open a round if the chain is idle, or validate that the open one is still in its
    /// registration window. Factory only: candidates exist only as (token, pool, bond) triples.
    /// @dev The `tradingStart` returned is the OWN window start of a candidate registering in
    /// this call: the round's synchronized start, or `block.timestamp` for a late entrant, whose
    /// pool opens the moment it registers (its own 3-second snipe tax applies from that moment).
    function openRoundIfIdle()
        external
        onlyFactory
        returns (uint256 roundId, uint64 tradingStart, uint32 scoreSlotS, address parentToken, uint256 bondWei)
    {
        if (head() == address(0)) revert NoGenesis();
        roundId = roundCount;
        if (roundId != 0 && !rounds[roundId].finalized) {
            Round storage open = rounds[roundId];
            if (block.timestamp < open.registrationEnd) {
                return (roundId, open.tradingStart, scoreSlotFor(roundId), open.parentToken, open.bondWei);
            }
            // LATE ENTRY (MECHANISM_v3 sec.2): the same bond, the same closing window, and a pool
            // that opens right now instead of at the round's start.
            if (open.lateEntryEnd == 0 || block.timestamp >= open.lateEntryEnd) revert RegistrationClosed();
            return (roundId, uint64(block.timestamp), scoreSlotFor(roundId), open.parentToken, open.bondWei);
        }

        // the ONLY effect of a sunset: no new round is ever minted by this version. The branch
        // above - an already-open round - is deliberately in front of this check, so a round that
        // was open when the sunset landed still registers, trades, scores and finalizes.
        if (isSunset()) revert Sunset(successor);

        // F1: a continuation opens NO round at all until it may adopt the trunk, and it adopts it
        // here - reading the prior head at the only moment that head can no longer change.
        _adoptIfContinuation();

        uint256 nextIndex = _headIndex + 1;
        if (nextIndex > MAX_INDEX) revert ChainDepthLimit();

        roundId = ++roundCount;
        Round storage r = rounds[roundId];
        r.bondWei = bondFor(nextIndex);
        r.openedAt = uint64(block.timestamp);
        r.registrationEnd = uint64(block.timestamp) + registrationFor(roundId);
        r.tradingStart = r.registrationEnd;
        r.nominalEnd = r.tradingStart + durationFor(roundId);
        uint64 late = lateEntryUntil(roundId);
        if (late != 0) r.lateEntryEnd = r.tradingStart + late;
        r.parentIndex = _headIndex;
        r.parentToken = _head;
        r.hUsed = threshold();

        emit RoundOpened(roundId, _headIndex, _head, r.registrationEnd, r.hUsed);
        emit TradingStarted(roundId, r.tradingStart, r.nominalEnd, r.lateEntryEnd);
        return (roundId, r.tradingStart, scoreSlotFor(roundId), r.parentToken, r.bondWei);
    }

    /// @dev LAZY HEAD ADOPTION (F1). The prior version must have been sunset for real, must have
    /// named this contract (and nothing else) as its successor, and must have finished its last
    /// round. Only then is its head final, and only then may this version start numbering links
    /// above it. Before that, every read here delegates to the prior registry and this contract
    /// refuses to open a round at all.
    function _adoptIfContinuation() internal {
        address prior = priorRegistry;
        if (prior == address(0) || adopted) return;
        IPriorRegistry p = IPriorRegistry(prior);
        if (!p.isSunsetEffective() || p.successor() != address(this) || !p.isIdle()) revert PriorNotHandedOver();
        // audit 2: an idle, sunset prior is NOT enough - if the prior is itself an unadopted
        // continuation it reports idle with no rounds of its own while ITS prior is still live
        // and can still crown. Adoption is only final when the immediate prior owns the head it
        // is handing over: it is a root, or it adopted the trunk itself.
        if (p.priorRegistry() != address(0) && !p.adopted()) revert PriorNotAdopted();
        address priorHead = p.headToken();
        if (priorHead == address(0)) revert BadContinuation();
        uint256 index = p.headIndex();
        _priorIndex = index;
        _headIndex = index;
        _head = priorHead;
        adopted = true;
        emit ContinuationAdopted(prior, index, priorHead);
    }

    /// @notice Escrow a candidate's bond and add it to the round (factory only).
    function addCandidate(uint256 roundId, address token, PoolKey calldata key, address creator)
        external
        payable
        onlyFactory
        returns (uint256 candidateId)
    {
        Round storage r = rounds[roundId];
        if (r.openedAt == 0 || r.finalized) revert NoRound();
        uint64 start = r.tradingStart;
        if (block.timestamp >= r.registrationEnd) {
            if (r.lateEntryEnd == 0 || block.timestamp >= r.lateEntryEnd) revert RegistrationClosed();
            start = uint64(block.timestamp);
        }
        if (msg.value != r.bondWei) revert WrongBond();

        candidateId = candidates.length;
        candidates.push(
            Candidate({
                roundId: roundId,
                token: token,
                creator: creator,
                bond: msg.value,
                submitted: false,
                tradingStart: start,
                avg: 0,
                tFirstAttained: 0,
                key: key
            })
        );
        roundCandidates[roundId].push(candidateId);
        r.candidateCount++;
        _creatorOf[token] = creator;

        emit CandidateRegistered(roundId, candidateId, token, creator, key.toId());
    }

    // -------------------------------------------------------------------------------------
    // the random end (MECHANISM_v3 sec.3)
    // -------------------------------------------------------------------------------------

    /// @notice At the nominal end `T`, pin the randomness that will fix the TRUE end. Anyone may
    /// call it, once per round.
    ///
    /// @dev This is the whole trick. A contract cannot keep a secret, so the end cannot be a
    /// number this contract knows and hides; instead, at `T` it commits to an event that HAS NOT
    /// HAPPENED YET (the next drand round). Nobody - operator included - can know the offset
    /// before `T`, so a buy in the last {RANDOM_END_S} seconds is a gamble on landing before an
    /// end that does not exist yet.
    function requestEnd() external notInsideUnlock returns (bytes32 randomId) {
        uint256 roundId = roundCount;
        if (roundId == 0) revert NoRound();
        Round storage r = rounds[roundId];
        if (address(randomness) == address(0)) revert NoRandomness();
        if (block.timestamp < r.nominalEnd) revert EndNotDue();
        if (r.tradingEnd != 0) revert EndAlreadySettled();
        if (r.endRequested) revert EndAlreadyRequested();
        randomId = randomness.pin();
        r.endRequested = true;
        r.randomId = randomId;
        emit EndRequested(roundId, randomId, msg.sender);
    }

    /// @notice Relay the beacon for the pinned round. The SOURCE verifies the proof on chain; if
    /// it verifies, the round's true end is `T_end = T - (word mod RANDOM_END_S)` and the
    /// submission window opens now.
    function fulfilEnd(bytes calldata proof) external notInsideUnlock returns (uint64 tradingEnd) {
        uint256 roundId = roundCount;
        if (roundId == 0) revert NoRound();
        Round storage r = rounds[roundId];
        if (r.tradingEnd != 0) revert EndAlreadySettled();
        if (!r.endRequested) revert EndNotRequested();
        uint256 word = randomness.fulfil(r.randomId, proof);
        uint64 window = randomEndWindowFor(roundId);
        tradingEnd = r.nominalEnd - uint64(word % window);
        r.tradingEnd = tradingEnd;
        r.submitEnd = uint64(block.timestamp) + SUBMIT_S;
        emit EndFulfilled(roundId, word, tradingEnd, r.submitEnd);
    }

    /// @notice DISCLOSED FALLBACK. If nobody has relayed a verifiable beacon within
    /// {END_TIMEOUT} of `T`, anyone may settle the round deterministically at `T_end = T`. The
    /// randomness is simply absent for that round, and the event says so.
    function finalizeDeterministic() external notInsideUnlock {
        uint256 roundId = roundCount;
        if (roundId == 0) revert NoRound();
        Round storage r = rounds[roundId];
        if (r.tradingEnd != 0) revert EndAlreadySettled();
        if (r.nominalEnd == 0 || block.timestamp < r.nominalEnd + END_TIMEOUT) revert TimeoutNotReached();
        r.tradingEnd = r.nominalEnd;
        r.submitEnd = uint64(block.timestamp) + SUBMIT_S;
        emit RandomEndUnavailable(roundId, r.tradingEnd, r.submitEnd);
    }

    // -------------------------------------------------------------------------------------
    // submission
    // -------------------------------------------------------------------------------------

    /// @notice Snapshot a candidate's CLOSING-WINDOW average absorption - its average over
    /// `[T_end - W, T_end]` - and update the round's best. Permissionless, idempotent per
    /// candidate, and only inside `[T_end fulfilment, +SUBMIT_S)`.
    ///
    /// @dev The average is reconstructed out of the hook's checkpoint rings at both edges of the
    /// window, so nothing swapped after the (previously unknowable) `T_end` can move any
    /// candidate's score even though the accumulator itself keeps running forever.
    function submitScore(uint256 candidateId) external notInsideUnlock returns (int256 avg) {
        if (candidateId >= candidates.length) revert UnknownCandidate();
        Candidate storage c = candidates[candidateId];
        Round storage r = rounds[c.roundId];
        if (r.tradingEnd == 0) revert EndNotSettled();
        if (block.timestamp < r.tradingEnd || block.timestamp >= r.submitEnd) revert OutsideSubmissionWindow();
        if (c.submitted) return c.avg; // the score is a snapshot at T_end: re-submission is a no-op

        PoolId id = c.key.toId();
        uint64 tFirstAttained = c.tradingStart;
        uint64 w = closingWindowFor(c.roundId);
        uint64 windowStart = r.tradingEnd > w ? r.tradingEnd - w : 0;
        // a pool that opened after the closing window has already closed (only reachable on a
        // heavily scaled testnet schedule) scores zero rather than reverting and blocking a round
        if (r.tradingEnd > c.tradingStart) (avg, tFirstAttained) = hook.averageOver(id, windowStart, r.tradingEnd);

        c.submitted = true;
        c.avg = avg;
        c.tFirstAttained = tFirstAttained;

        if (!r.hasBest || _beats(avg, tFirstAttained, PoolId.unwrap(id), r.bestAvg, r.bestAttained, r.bestPoolId)) {
            r.hasBest = true;
            r.bestCandidateId = candidateId;
            r.bestAvg = avg;
            r.bestAttained = tFirstAttained;
            r.bestPoolId = PoolId.unwrap(id);
        }

        emit ScoreSubmitted(c.roundId, candidateId, avg, tFirstAttained, msg.sender);
    }

    /// @dev Tie rule: higher average, then earlier attainment, then lower pool id. "Earlier
    /// attainment" is `tFirstAttained`, which the hook defines as the LAST SCORE UPDATE BEFORE
    /// `T_end` - the moment the final average was first reached, not the first time the score
    /// ever moved (L4).
    function _beats(int256 avg, uint64 tAttained, bytes32 poolId, int256 bAvg, uint64 bAttained, bytes32 bPoolId)
        internal
        pure
        returns (bool)
    {
        if (avg != bAvg) return avg > bAvg;
        if (tAttained != bAttained) return tAttained < bAttained;
        return uint256(poolId) < uint256(bPoolId);
    }

    // -------------------------------------------------------------------------------------
    // finalization
    // -------------------------------------------------------------------------------------

    /// @notice Close the current round: crown the best candidate if it cleared the threshold,
    /// otherwise decay the threshold. Permissionless, deterministic, idempotent.
    function finalize() external nonReentrant notInsideUnlock {
        uint256 roundId = roundCount;
        if (roundId == 0) revert NoRound();
        Round storage r = rounds[roundId];
        if (r.finalized) return; // idempotent: a stale finalize can never overwrite anything
        if (r.tradingEnd == 0) revert EndNotSettled();
        if (block.timestamp < r.submitEnd) revert SubmissionWindowOpen();

        r.finalized = true;
        uint256 hUsed = r.hUsed;
        uint256 hNextWad = hWad;
        uint256 forfeited = r.candidateCount * r.bondWei;
        address refundTo;
        uint256 refundAmount;

        if (r.hasBest && r.bestAvg >= int256(hUsed)) {
            r.hasWinner = true;
            r.winnerCandidateId = r.bestCandidateId;
            Candidate storage w = candidates[r.bestCandidateId];

            uint256 newIndex = _headIndex + 1;
            address parent = _head;
            _canonical[newIndex] = w.token;
            canonicalKey[newIndex] = w.key;
            _indexOf[w.token] = newIndex;
            _isCanonical[w.token] = true;
            _parentOf[w.token] = parent;
            _head = w.token;
            _headIndex = newIndex;
            // the generation is now a real thing: this winner is the trunk link its purse - the
            // generation's share of every later fee - is locked under forever (MECHANISM_v3 sec.1)
            _roundOfIndex[newIndex] = roundId;

            // a win RESETS the threshold to the deploy constant: the x0.9 decay only compounds
            // across consecutive failed rounds
            hNextWad = H_FRAC_WAD;
            hWad = H_FRAC_WAD;

            forfeited -= w.bond;
            refundTo = w.creator;
            refundAmount = w.bond;
            emit HeadChanged(newIndex, w.token, parent);
        } else {
            uint256 decayed = (hWad * DECAY_NUM) / DECAY_DEN;
            hNextWad = decayed < H_MIN_FRAC_WAD ? H_MIN_FRAC_WAD : decayed;
            hWad = hNextWad;
        }

        emit RoundFinalized(roundId, r.hasWinner, r.winnerCandidateId, r.bestAvg, hUsed, thresholdFor(hNextWad));

        // effects are complete; the two value transfers below are the only external calls
        if (forfeited != 0) {
            emit BondsForfeited(roundId, forfeited);
            feeVault.depositGenesisBidEarmark{value: forfeited}();
        }
        if (refundTo != address(0)) {
            (bool ok,) = refundTo.call{value: refundAmount}("");
            if (!ok) pendingRefund[refundTo] += refundAmount;
            emit BondRefunded(refundTo, refundAmount, ok);
        }
    }

    /// @notice Pull fallback for a winner whose push refund reverted.
    function claimRefund(address to) external nonReentrant notInsideUnlock {
        uint256 amount = pendingRefund[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pendingRefund[msg.sender] = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "refund failed");
    }

    // -------------------------------------------------------------------------------------
    // the generation record (MECHANISM_v3 sec.1)
    // -------------------------------------------------------------------------------------

    /// @notice The round that crowned canonical index `i`, or 0 if this deployment did not crown
    /// it (genesis, or an index owned by a registry this one continues).
    ///
    /// @dev The generation's siblings - the winner and every loser of the same round - can be
    /// found from it forever. Losers stay tradable and keep their creator share; what they do
    /// NOT do any more is contest the purse. Generation `i`'s share of later fees is deployed as
    /// locked bid liquidity under `canonical(i)`, the trunk link that won the round, and nothing
    /// measured after the round can move it.
    function roundOfIndex(uint256 i) public view returns (uint256) {
        return _roundOfIndex[i];
    }

    // -------------------------------------------------------------------------------------
    // views
    // -------------------------------------------------------------------------------------

    /// @notice Current threshold `H` in parent tokens: an AVERAGE absorption over the trading
    /// window, directly comparable with `score / TRADING_S`.
    ///
    /// @dev L10 - ACCEPTED, DOCUMENTED BEHAVIOUR. `H` is a fraction of the head's LIVE total
    /// supply, and `FamilyToken.burn` is permissionless, so anyone holding head tokens can lower
    /// the bar for the next succession by burning them. This is deliberate and not economically
    /// free: burning `x` of the head costs the burner the full market value of `x` and lowers `H`
    /// by only `h * x` (h is 15 bps at deploy), i.e. the attacker pays ~667x the threshold relief
    /// they buy, while every remaining holder - including the candidate they are attacking - is
    /// made richer per token. Pinning `H` to the launch supply instead would break the
    /// self-similar property (the curve and the threshold must be quoted in the same numeraire)
    /// and would make a deflationary head permanently harder to succeed. See
    /// `test_burningHeadSupplyLowersThreshold`.
    function threshold() public view returns (uint256) {
        return thresholdFor(hWad);
    }

    function thresholdFor(uint256 fracWad) public view returns (uint256) {
        address h = head();
        if (h == address(0)) return 0;
        return (IERC20(h).totalSupply() * fracWad) / 1e18;
    }

    function phase(uint256 roundId) public view returns (Phase) {
        Round storage r = rounds[roundId];
        if (r.openedAt == 0) return Phase.Idle;
        if (r.finalized) return Phase.Finalized;
        if (block.timestamp < r.registrationEnd) return Phase.Registration;
        if (block.timestamp < r.nominalEnd) return Phase.Trading;
        // past `T`: the round is over, but nobody knows WHEN it ended until the beacon lands
        if (r.tradingEnd == 0) return Phase.EndPending;
        if (block.timestamp < r.submitEnd) return Phase.Submission;
        return Phase.Finalizable;
    }

    function currentPhase() external view returns (Phase) {
        return phase(roundCount);
    }

    function roundInfo(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    function candidateInfo(uint256 candidateId) external view returns (Candidate memory) {
        return candidates[candidateId];
    }

    function candidateCount() external view returns (uint256) {
        return candidates.length;
    }

    function candidateIds(uint256 roundId) external view returns (uint256[] memory) {
        return roundCandidates[roundId];
    }

    /// @notice A PAGE of `roundId`'s candidate ids: at most `limit` ids starting at `offset`
    /// (F10). The unpaginated view above stays for the common, tiny case; an indexer facing a
    /// spammed round must use this one, because an unbounded array return can exceed the gas
    /// limit of an `eth_call`.
    function candidateIds(uint256 roundId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page, uint256 total)
    {
        uint256[] storage ids = roundCandidates[roundId];
        total = ids.length;
        if (offset >= total) return (new uint256[](0), total);
        uint256 n = total - offset;
        if (n > limit) n = limit;
        page = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            page[i] = ids[offset + i];
        }
    }

    function candidateIdAt(uint256 roundId, uint256 i) external view returns (uint256) {
        return roundCandidates[roundId][i];
    }
}
