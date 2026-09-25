// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FamilyFactory} from "./FamilyFactory.sol";
import {FamilyHook} from "./FamilyHook.sol";
import {RoundManager} from "./RoundManager.sol";
import {IFeeVault} from "./interfaces/IFeeVault.sol";
import {IPriorRegistry} from "./interfaces/IPriorRegistry.sol";
import {IVersionFactory} from "./interfaces/IVersionFactory.sol";
import {FenwickRangeAdd} from "./libraries/FenwickRangeAdd.sol";
import {V4UnlockGuard} from "./libraries/V4UnlockGuard.sol";

/// @title FeeVault
/// @notice The protocol's fee ledger. There is no owner; the developer address is immutable,
/// creators claim their own token's share, and everything else is deployed permissionlessly as
/// locked buy-support by whoever pays the gas (for a 1% bounty).
///
/// EVERY LEDGER IS DENOMINATED IN {EDGE}, the externally launched token this
/// deployment adopted as canonical index 0. The vault never holds, receives or sends native ETH:
/// there is no `receive()`, no native send and no native branch anywhere below. "EDGE" in the
/// table below is that token, in its own 18-decimal units.
///
/// Ledgers (DESIGN_BRIEF_v2 sec.4, mirroring `sim.family.FeeAllocator`):
///   - `devBalance`               EDGE, {DEV_BPS} of every protocol fee.
///   - `creatorBalance[token]`    EDGE, {CREATOR_BPS} when the swap was attributed by the router.
///   - ancestor sleeve            EDGE, spread over ancestors `0..M` of the attributed terminal
///                                token with weights `w(r) = 2 - 5r + 4r^2`, `r = j/M`,
///                                normalised by `Z(M) = (M+1)(5M+4)/(6M)`, held in three Fenwick
///                                trees (range-add of `c0 + c1*j + c2*j^2`, point query per
///                                generation). `M = 0` is the genesis-only case.
///   - `reinforcementEdge[j]`     EDGE, the immediate-parent sleeve for generation `j`.
///   - `reinforcementBalance[p]`  PARENT-TOKEN units, the hop fees (and snipe tax) taken by the
///                                pool whose parent currency is `p` - already denominated in
///                                exactly the currency a bid under that pool needs, so it needs
///                                no conversion. `p == EDGE` is an edge (link one) pool.
///   - `edgeBidEarmark`           EDGE, forfeited candidate bonds.
///
/// @dev The EDGE sleeve and the hop fees are deliberately kept in SEPARATE mappings even though
/// the brief lumps them together: they are denominated in different currencies (the edge currency
/// vs the parent token), and a single number could not be spent safely. Both are consumed by the same
/// keeper call, `BidDeployer.deployAncestor`.
///
/// Rounding policy: every split is floor-divided and the LAST bucket takes the remainder, so
/// `dev + creator + ancestorSleeve + reinforce == fee` exactly. Inside the ancestor sleeve the
/// Fenwick coefficients are floored (WAD-scaled), so the point queries sum to slightly LESS
/// than the sleeve; that residue (a few wei per fee) stays in the vault forever and is never
/// claimable, which keeps the solvency invariant `ledgers <= holdings` true by construction.
contract FeeVault is IFeeVault, IUnlockCallback {
    using SafeERC20 for IERC20;
    using FenwickRangeAdd for FenwickRangeAdd.Tree;

    // -------------------------------------------------------------------------------------
    // constants
    // -------------------------------------------------------------------------------------

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// @notice Developer share of every protocol fee: 20%.
    uint256 public constant DEV_BPS = 2_000;
    /// @notice Public delay between announcing a transfer of the developer address and being able
    /// to execute it. Identical to `RoundManager.ROLE_TRANSFER_DELAY` and
    /// `DevVesting.ROLE_TRANSFER_DELAY`.
    uint64 public constant ROLE_TRANSFER_DELAY = 7 days;
    /// @notice Attribution sentinel for a succession CANDIDATE, which has no canonical index
    ///. `FamilyRouter.buyCandidate` sets this bit and ORs in the candidate id; the creator
    /// share is then credited to the CANDIDATE's token, claimable via `creatorOf`. Must match
    /// `FamilyRouter.CANDIDATE_ATTRIBUTION`.
    uint256 public constant CANDIDATE_ATTRIBUTION = 1 << 255;

    /// @notice How many successor FeeVaults a forwarded edge fee may pass through
    /// (v1 -> v2 -> v3 ...), matching `RoundManager.MAX_CONTINUATION_HOPS`.
    uint256 public constant MAX_FORWARD_HOPS = 8;

    /// @notice Gas ceiling for the WHOLE handover hop ({forwardProtocolFee} and everything the
    /// successor does inside it), and the gas this vault always KEEPS BACK for booking the fee
    /// itself. Without a cap, EIP-150's 63/64 rule lets a successor that burns every wei of
    /// gas leave too little behind for {_book} (a cold Fenwick range-add over the 4096-index
    /// sleeve is ~78 SSTOREs, well over 1M gas), so a gas-burning successor could revert every
    /// genesis-pool swap at ANY gas limit.
    ///
    /// @dev The SAFETY property is {BOOK_GAS_RESERVE}, not the ceiling: the hop is given
    /// `min(FORWARD_GAS, gasleft - BOOK_GAS_RESERVE)` and is skipped entirely when that is
    /// nothing, so whatever the successor does there is always enough gas left here to book the
    /// fee locally and let the swap finish. The ceiling only bounds what a hostile successor can
    /// waste; it is generous because an HONEST hop is expensive (a cold book in the successor,
    /// and possibly one further hop of its own).
    uint256 public constant FORWARD_GAS = 6_000_000;
    uint256 public constant BOOK_GAS_RESERVE = 1_500_000;
    /// @notice Gas budget for ONE leg of the successor-VAULT resolution, matching
    /// `FamilyHook.STATIC_GAS`. Every leg is an unauthenticated call into an address the steward
    /// named; without a cap, a successor whose `factory()` burns gas makes {flushForward} cost
    /// whatever the caller is willing to supply and always fail, which is a freeze of the queue.
    uint256 internal constant STATIC_GAS = 30_000;
    /// @notice THE DEAD-SUCCESSOR TIMELOCK, ON EVIDENCE. Queued fees are the
    /// successor's, and this version is not allowed to take them back merely because the hop is
    /// inconvenient. The clock runs on {deadEvidenceAt}, the first FULL-{FORWARD_GAS} delivery
    /// failure recorded for that attribution, NOT on when the queue filled - so a healthy
    /// successor that simply had nothing pushed to it for a month is never declarable dead by one
    /// flush. Booking locally needs BOTH: this long since that first failure, AND a second
    /// full-budget failure in the flush that books. Any successful delivery clears the evidence.
    uint64 public constant DEAD_SUCCESSOR_DELAY = 30 days;
    /// @notice Drawdown limit on a generation's ETH sleeve: a TOKEN BUCKET holding at most 10% of
    /// what is claimable right now and refilling continuously over {DRAW_WINDOW}. A
    /// TWAP drag can therefore never drain a whole generation in one block, and a keeper that
    /// wants the rest must come back later.
    ///
    /// @dev The previous implementation was a RESETTING window: 10% of the base could be spent at
    /// the very end of a window and another 10% of a fresh base one second later, so "10% per
    /// rolling 24 hours" was false by about a factor of two at a window boundary. A
    /// bucket has no boundary to sit on: whatever is spent has to be earned back at
    /// `10% * dt / 24 h`, so the drawdown over ANY 24 hours is at most 10% plus what the sleeve
    /// grew by in the meantime.
    uint256 public constant DAILY_DRAW_BPS = 1_000;
    uint64 public constant DRAW_WINDOW = 1 days;

    /// @notice Attribution sentinel carried by a FORWARDED fee that the charging hook did not
    /// attribute. It resolves to "unattributed" in {_resolveAttribution} by construction (it is
    /// neither a live candidate id nor an index at or below any head), so the booking vault needs
    /// no separate flag.
    uint256 public constant UNATTRIBUTED = type(uint256).max;

    /// @notice THE EDGE CURRENCY: `canonical(0)`, the externally launched token this deployment
    /// adopted. Every ledger, every claim, every keeper payout and every forwarded protocol fee is
    /// denominated in it. Immutable, read off the factory at construction; there is no setter and
    /// no other currency this vault can ever pay out.
    Currency public immutable EDGE;

    /// @notice Creator share of an attributed protocol fee (deploy constant).
    uint256 public immutable CREATOR_BPS;
    /// @notice Split of what is left after dev and creator, between the all-ancestor sleeve and
    /// the immediate-parent reinforcement sleeve. The two must sum to {BPS}.
    uint256 public immutable ANCESTOR_BPS;
    uint256 public immutable REINFORCE_BPS;

    // -------------------------------------------------------------------------------------
    // wiring
    // -------------------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    FamilyFactory public immutable factory;
    FamilyHook public immutable hook;
    RoundManager public immutable roundManager;
    /// @notice The one contract that may spend these ledgers into locked liquidity: this
    /// version's {BidDeployer}, deployed one nonce AFTER this vault and therefore named here as
    /// the address PREDICTION the factory was already given. Immutable, no setter. Everything
    /// the keeper paths need is behind a `msg.sender == bidDeployer` hook on this contract.
    address public immutable bidDeployer;
    /// @notice The one address that may claim the developer share. Transferable on a public
    /// {ROLE_TRANSFER_DELAY} delay ({announceDeveloperTransfer}), never to address(0).
    /// @dev The developer ledger is a single balance, not a per-holder one: whatever has accrued
    /// — before or after a transfer — is claimable by WHOEVER IS THE DEVELOPER AT CLAIM TIME.
    /// A transfer therefore hands over the unclaimed balance as well as the future stream; the
    /// outgoing holder should claim before announcing if that is not what they want. This is the
    /// opposite of {transferCreatorRecipient}, which sweeps the accrued balance to the old
    /// recipient, because the creator ledger is keyed per token and this one is not.
    address public developer;
    /// @notice The announced next developer, or address(0) when nothing is pending.
    address public pendingDeveloper;
    /// @notice The timestamp {executeDeveloperTransfer} becomes callable at, or 0.
    uint64 public developerTransferAt;
    /// @notice True when this stack CONTINUES an earlier version (README "Upgrade model"). The
    /// generations at or below `roundManager.priorIndex()` then live in pools owned by an
    /// earlier hook/Locker, so their TWAPs must be read from that version's hook and their bids
    /// must be placed by that version's BidDeployer. Immutable, so a non-continuation deploy pays
    /// exactly nothing for any of it.
    bool public immutable isContinuation;

    // -------------------------------------------------------------------------------------
    // ledgers
    // -------------------------------------------------------------------------------------

    uint256 public devBalance;
    mapping(address => uint256) public creatorBalance;
    /// @notice ETH accrued under a creator right BEFORE it was transferred away, per address. It
    /// is credited at the transfer and claimed with {claimCreatorAccrued}; nothing else ever
    /// writes it.
    mapping(address => uint256) public creatorAccrued;
    mapping(address => address) internal _creatorRecipient;
    mapping(address => bool) internal _creatorRecipientSet;

    FenwickRangeAdd.Tree internal ancestorTree;
    mapping(uint256 => uint256) public ancestorClaimed;
    mapping(uint256 => uint256) public reinforcementEdge;
    mapping(address => uint256) public reinforcementBalance;
    uint256 public edgeBidEarmark;

    /// @notice The SUCCESSOR version's FeeVault, resolved once (through
    /// `roundManager.successor().factory().feeVault()`) the first time a fee is forwarded, and
    /// cached forever after. There is no setter and no way to point it anywhere else: the
    /// successor is the one the steward named in the one-shot sunset, and it is immutable there.
    address public successorVault;

    /// @notice Total credited to some ledger, per currency; the solvency invariant is
    /// `ledgerTotal[c] <= holdings(c)` for every currency. Post-sunset fees waiting in
    /// {pendingForward} are counted here too: the vault holds them, it just does not own them.
    mapping(Currency => uint256) public ledgerTotal;

    /// @notice THE PENDING FORWARD QUEUE. Post-sunset ETH-edge fees that could not be
    /// handed to the successor inside the swap that charged them, keyed by the attribution the
    /// charging hook accepted. They are NEVER booked on this version's ledgers: whichever version
    /// is live when {flushForward} runs is the one that books them, so the gas of a swap can no
    /// longer decide which version receives a fee.
    mapping(uint256 => uint256) public pendingForward;
    /// @notice The sum of {pendingForward} over every attribution (solvency introspection).
    uint256 public pendingForwardTotal;
    /// @notice TWO-PHASE DEAD-SUCCESSOR EVIDENCE, per attribution. The
    /// timestamp of the FIRST delivery failure that had the whole {FORWARD_GAS} budget to work
    /// with. Zero means "no evidence": either nothing has ever failed on full budget, or a
    /// delivery has since succeeded and cleared it. It is per-attribution because delivery is
    /// per-attribution: one attribution the successor chokes on says nothing about another.
    mapping(uint256 => uint64) public deadEvidenceAt;

    /// @notice NEGATIVE RESOLUTION CACHE: true once a handover hop has failed. The successor
    /// is immutable once named, so a hop that failed once is not going to start working; retrying
    /// it on every single swap would burn {FORWARD_GAS} per swap forever. From here on the ETH
    /// edge is simply booked on THIS version's ledgers, loudly (see {ProtocolFeeForwardingFailed})
    /// and permanently.
    bool public forwardingFailed;

    /// @notice Per-generation drawdown BUCKET: `available` is what was left the last
    /// time the generation was drawn, at `updatedAt`; it refills continuously up to
    /// {DAILY_DRAW_BPS} of what is claimable now. An untouched generation (`initialised == false`)
    /// has a full bucket.
    /// @dev "untouched" is its own flag rather than `updatedAt == 0`. The field is written
    /// with `uint64(block.timestamp)`, so a zero-sentinel gives a legitimately recorded zero the
    /// meaning "never drawn, bucket full" and lets two draws in one block each take a full
    /// bucket. The flag is set once, on the first draw, and never cleared; it packs into the same
    /// slot as `updatedAt`, so the struct still costs two slots.
    struct Drawdown {
        uint64 updatedAt;
        bool initialised;
        uint256 available;
    }

    mapping(uint256 => Drawdown) internal drawdowns;

    uint256 private _locked = 1;

    // -------------------------------------------------------------------------------------
    // events
    // -------------------------------------------------------------------------------------

    event FeeSplit(
        Currency indexed currency,
        uint256 hopFee,
        uint256 protocolFee,
        uint256 terminalIndex,
        bool attributed,
        uint256 dev,
        uint256 creator,
        uint256 ancestorSleeve,
        uint256 reinforce
    );
    event Redeemed(Currency indexed currency, uint256 amount);
    event DevClaimed(address indexed to, uint256 amount);
    event DeveloperTransferAnnounced(address indexed from, address indexed to, uint64 effectiveAt);
    event DeveloperTransferExecuted(address indexed from, address indexed to);
    event DeveloperTransferCancelled(address indexed from, address indexed cancelled);
    event CreatorClaimed(address indexed token, address indexed to, uint256 amount);
    event CreatorRecipientChanged(address indexed token, address indexed from, address indexed to);
    /// @notice The balance `token` had accrued when its creator right was transferred away, kept
    /// claimable by the recipient who earned it.
    event CreatorAccrued(address indexed recipient, address indexed token, uint256 amount);
    event CreatorAccruedClaimed(address indexed recipient, address indexed to, uint256 amount);
    event EdgeBidEarmarked(uint256 amount);
    /// @notice The BidDeployer drew `amount` of `currency` out of a ledger, to be spent into a
    /// locked bid (or paid to the keeper as the bounty) in the same transaction.
    event LedgerDrawn(Currency indexed currency, uint256 amount);
    /// @notice SUNSET HANDOVER: the ETH-edge fee charged on this version's genesis pool was sent
    /// on to the live version's vault instead of being booked here.
    event ProtocolFeeForwarded(address indexed successorVault, uint256 amount, uint256 attribution);
    /// @notice ...and the other side of the same hop, emitted by the vault that received it.
    event ProtocolFeeReceived(address indexed priorVault, uint256 amount, uint256 attribution);
    /// @notice The handover hop reverted or ran out of its {FORWARD_GAS} budget inside a
    /// swap. The fee was QUEUED for {flushForward} instead; it is never booked here.
    event ProtocolFeeForwardingFailed(address indexed successor, uint256 amount);
    /// @notice A post-sunset fee that could not be forwarded inside the swap that
    /// charged it is queued under its attribution, to be pushed on by {flushForward} with a
    /// caller's gas. Nothing about WHERE the fee ends up depends on the gas of the swap any more.
    event ProtocolFeeQueued(uint256 indexed attribution, uint256 amount, uint256 pending);
    /// @notice The named successor never took delivery, the {DEAD_SUCCESSOR_DELAY}
    /// timelock has run out and a full-budget attempt has failed, so this version has booked the
    /// queued fee on its own ledgers rather than holding it forever. Loud on purpose: it is the
    /// one path on which the handover decision is reversed.
    event SuccessorDeclaredDead(address indexed successor, uint256 attribution, uint256 amount);
    /// @notice A FULL-{FORWARD_GAS} delivery attempt to the successor's vault
    /// failed. The first one for an attribution starts that attribution's {DEAD_SUCCESSOR_DELAY};
    /// the queue is left exactly as it was either way. `reason` is the successor's raw revert
    /// data, so an operator can tell a broken successor from an out-of-gas one.
    event SuccessorDeliveryFailed(uint256 indexed attribution, bytes reason);
    /// @notice The named successor did not resolve to a vault at all. Emitted
    /// from {flushForward} only - never from {accrue} - so the swap path stays silent and cheap
    /// while the permissionless flush path says plainly why nothing moved.
    event SuccessorUnresolved(address indexed successor);
    /// @notice A delivery succeeded for an attribution that had a dead-successor
    /// evidence timestamp standing against it, so the evidence is withdrawn.
    event SuccessorDeliveryEvidenceCleared(uint256 indexed attribution);

    // -------------------------------------------------------------------------------------
    // errors
    // -------------------------------------------------------------------------------------

    error NotHook();
    error NotRoundManager();
    error NotPoolManager();
    error NotCreator();
    error NotDeveloper();
    /// @notice A developer transfer is already announced; cancel it before announcing another.
    error TransferPending();
    error NoTransferPending();
    error TransferNotReady();
    error BadSplit();
    error NothingToClaim();
    error TransferFailed();
    error Reentrancy();
    error TooMuchRequested();
    error NoCode();
    /// @notice One of the keeper hooks was called by something other than {bidDeployer}.
    error NotBidDeployer();
    /// @notice {forwardProtocolFee} is an internal step exposed only so that a failed handover
    /// can be rolled back without reverting the swap it happens inside.
    error NotSelf();
    /// @notice {accrueForwarded} was called by something that is not a FeeVault of a version this
    /// one continues.
    error NotPriorVault();
    /// @notice A verified delivery of edge tokens did not arrive: the ledger would exceed what
    /// the vault actually holds. Solvency is an inequality, so this is refused at the door.
    error NotDelivered();
    /// @notice The successor named by the sunset does not resolve to a live FeeVault.
    error NoSuccessorVault();
    /// @notice {flushForward} was called for an attribution with nothing queued under it.
    error NothingToForward();
    /// @notice The hop failed on a budget smaller than {FORWARD_GAS}, which says nothing about
    /// the successor: a thin-gas call may never be the evidence that declares it dead.
    error FlushGasTooLow();
    /// @notice A creator right (or a claim) was pointed at `address(0)`, which would burn it.
    error BadRecipient();
    /// @notice More of a generation's ETH was requested than its {DAILY_DRAW_BPS} drawdown bucket
    /// currently holds.
    error DailyLimitExceeded(uint256 requested, uint256 allowed);

    /// @notice REN-01: a pull-payment claim was attempted from inside a v4 `PoolManager` unlock.
    error InsideUnlock();

    /// @notice REN-01 (defence in depth). Refuse a claim made from inside a v4 `PoolManager`
    /// unlock, i.e. with somebody's flash accounting still open.
    ///
    /// @dev The accrual path is deliberately NOT guarded: the hook calls {accrue} from inside the
    /// swap's own unlock on every single swap, and that is the one place this contract is meant
    /// to be reached from there. The claims are pull payments that redeem and send real ETH, and
    /// nothing in the protocol ever calls them from inside an unlock of its own.
    modifier notInsideUnlock() {
        if (V4UnlockGuard.isInsideUnlock(address(poolManager))) revert InsideUnlock();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        FamilyFactory _factory,
        address _developer,
        uint256 _creatorBps,
        uint256 _ancestorBps,
        uint256 _reinforceBps
    ) {
        // The split must fit in 100% and the developer address must be real; there is no
        // setter for either, so a bad deploy is unfixable and must be refused here.
        if (DEV_BPS + _creatorBps > BPS || _ancestorBps + _reinforceBps != BPS) revert BadSplit();
        if (_developer == address(0)) revert BadSplit();
        // The factory (and everything it deployed) exists by now, so its code is checkable.
        if (address(_factory).code.length == 0) revert NoCode();
        factory = _factory;
        poolManager = _factory.poolManager();
        hook = _factory.hook();
        roundManager = _factory.roundManager();
        if (address(_factory.locker()).code.length == 0 || address(hook).code.length == 0) revert NoCode();
        if (address(roundManager).code.length == 0) revert NoCode();
        // the BidDeployer does not exist yet (it reads this vault's getters), so its code cannot
        // be checked here: `FamilyFactory.wire` does it once, lazily, exactly as it does for the
        // vault and the router.
        bidDeployer = _factory.bidDeployer();
        if (bidDeployer == address(0)) revert NoCode();
        // The edge currency is fixed here, from the factory's own deploy constant. The
        // factory checked it is a contract; {FamilyFactory.adoptGenesis} checks its decimals and
        // its supply at the moment the chain starts.
        address edgeToken = _factory.genesisToken();
        if (edgeToken == address(0) || edgeToken.code.length == 0) revert NoCode();
        EDGE = Currency.wrap(edgeToken);
        developer = _developer;
        isContinuation = roundManager.priorRegistry() != address(0);
        CREATOR_BPS = _creatorBps;
        ANCESTOR_BPS = _ancestorBps;
        REINFORCE_BPS = _reinforceBps;
    }

    // No `receive()`. This vault holds ERC-20 value only; a plain native transfer to it
    // reverts, and no path in this contract can ever send one out.

    // -------------------------------------------------------------------------------------
    // accrual
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IFeeVault
    function accrue(
        Currency currency,
        address parentToken,
        uint256 hopFee,
        uint256 protocolFee,
        uint256 terminalIndex,
        bool attributed
    ) external nonReentrant {
        if (msg.sender != address(hook)) revert NotHook();

        // The ledger is credited in FULL before the post-sunset handover hands control to an
        // unknown successor, so foreign code can never run while `ledgerTotal` understates what
        // this vault is holding. The forwarded case gives the protocol share back inside
        // {forwardProtocolFee}, in the instruction BEFORE the claim leaves, so the ledger never
        // OVERSTATES either - `ledgerTotal[c] <= holdings(c)` holds at every point of the hop.
        ledgerTotal[currency] += hopFee + protocolFee;

        if (hopFee != 0) {
            // already denominated in the currency a bid under this pool needs. The HOP fee stays
            // here even after the handover: it reinforces THIS version's pool, and only this
            // version's Locker may ever place liquidity there.
            reinforcementBalance[parentToken] += hopFee;
        }

        bool forwarded;
        bool queued;
        uint256 dev;
        uint256 creator;
        uint256 sleeve;
        uint256 reinforce;
        if (protocolFee != 0) {
            // SUNSET HANDOVER (README "Upgrade model"): once this version is sunset the live trunk
            // is the successor's, but the ETH edge is still charged here - a continuation stack has
            // no ETH-paired pool of its own. So the protocol share follows the live version: the
            // claim is handed to the successor's vault, which books it with ITS constants and ITS
            // registry.
            //
            // It is NEVER booked here as a fallback. The old code booked locally whenever
            // the hop could not run, which made the GAS OF THE SWAP decide which version receives a
            // fee and made a long chain impossible to complete. A hop that does not fit in the
            // swap's gas (or reverts) queues the fee in {pendingForward} instead, where anyone can
            // push it on with {flushForward} and their own gas. The hop is still wrapped, so a
            // successor that reverts or burns its budget can never fail the swap.
            if (currency == EDGE && roundManager.isSunset()) {
                // A CANDIDATE id is DEPLOYMENT-LOCAL - it indexes this version's own
                // `candidates` array and means nothing in the successor's, where the same number
                // is some other coin. Forwarding it would credit the successor's candidate #n with
                // a fee earned by this version's candidate #n. Only a canonical index travels;
                // a candidate attribution crosses the handover as {UNATTRIBUTED}, so the share
                // goes to the flywheel rather than to the wrong creator.
                uint256 attribution = (attributed && terminalIndex & CANDIDATE_ATTRIBUTION == 0)
                    ? terminalIndex
                    : UNATTRIBUTED;
                uint256 budget = forwardingFailed ? 0 : _forwardBudget();
                if (budget != 0) {
                    try this.forwardProtocolFee{gas: budget}(currency, protocolFee, attribution, MAX_FORWARD_HOPS) {
                        forwarded = true;
                    } catch {
                        _forwardingFailed(budget, protocolFee);
                    }
                }
                if (!forwarded) {
                    _queueForward(attribution, protocolFee);
                    queued = true;
                }
            }
            if (!forwarded && !queued) {
                (attributed, dev, creator, sleeve, reinforce) = _book(protocolFee, terminalIndex, attributed);
            }
        }

        // the forwarded case already gave the protocol share back inside {forwardProtocolFee}
        emit FeeSplit(
            currency,
            hopFee,
            forwarded ? 0 : protocolFee,
            terminalIndex,
            attributed && !forwarded,
            dev,
            creator,
            sleeve,
            reinforce
        );
    }

    /// @inheritdoc IFeeVault
    function accrueForwarded(uint256 attribution, uint256 amount, uint256 hopsLeft) external {
        // the ONLY caller ever accepted is a FeeVault of a version this one continues, found by
        // walking the same registry chain every delegated read walks. There is no other way in:
        // the value arrived as an ERC-6909 claim that vault transferred in the same call.
        if (!_isPriorVault(msg.sender)) revert NotPriorVault();
        Currency edge = EDGE;
        emit ProtocolFeeReceived(msg.sender, amount, attribution);
        if (amount == 0) return;

        // v1 -> v2 -> v3: if THIS version has been sunset too, the fee belongs one hop further on -
        // but it does NOT recurse. The old code forwarded from inside this call, so a
        // chain of versions had to complete inside one swap's gas and died by about v5. The fee is
        // queued here instead and the next hop is a separate, permissionless {flushForward} paid
        // for by whoever calls it. `hopsLeft` is accepted for ABI compatibility and ignored: how
        // far a fee travels is now a matter of how many flushes are called, not of gas.
        hopsLeft;
        ledgerTotal[edge] += amount;
        if (roundManager.isSunset()) {
            _queueForward(attribution, amount);
            return;
        }

        (bool ok, uint256 dev, uint256 creator, uint256 sleeve, uint256 reinforce) =
            _book(amount, attribution, attribution != UNATTRIBUTED);
        emit FeeSplit(edge, 0, amount, attribution, ok, dev, creator, sleeve, reinforce);
    }

    /// @notice The other half of the handover, for value that arrives as a REAL TOKEN
    /// BALANCE rather than as an unredeemed PoolManager claim - i.e. from a prior vault's
    /// {flushForward}, which runs outside a swap and can therefore redeem before it pays. Books it
    /// with this version's constants, or queues it for this version's own flush if this version is
    /// sunset too.
    ///
    /// @dev Non-payable. The prior vault transfers `amount` of the edge currency to this
    /// address in the instruction before this call, and the delivery is VERIFIED here against the
    /// solvency inequality rather than taken on the caller's word.
    function receiveForward(uint256 attribution, uint256 amount) external {
        if (!_isPriorVault(msg.sender)) revert NotPriorVault();
        Currency edge = EDGE;
        emit ProtocolFeeReceived(msg.sender, amount, attribution);
        if (amount == 0) return;
        ledgerTotal[edge] += amount;
        if (ledgerTotal[edge] > holdings(edge)) revert NotDelivered();
        if (roundManager.isSunset()) {
            _queueForward(attribution, amount);
            return;
        }
        (bool ok, uint256 dev, uint256 creator, uint256 sleeve, uint256 reinforce) =
            _book(amount, attribution, attribution != UNATTRIBUTED);
        emit FeeSplit(edge, 0, amount, attribution, ok, dev, creator, sleeve, reinforce);
    }

    /// @notice PUSH THE QUEUE ON. Forward up to `max` of what is queued under
    /// `attribution` to the IMMEDIATE successor's vault, with the caller's gas. Permissionless and
    /// idempotent; one hop per call, so a six-version chain is six flushes and no recursion.
    /// @return amount The ETH actually forwarded.
    ///
    /// @dev THE DEAD-SUCCESSOR ESCAPE, ON TWO-PHASE EVIDENCE. Without this escape, the queue has
    /// exactly one exit, running through an address named at deploy time that nobody here
    /// controls: a successor that never answers would freeze every queued fee of this version
    /// permanently. The clock runs on evidence about the successor itself, NOT on when the queue
    /// filled - a perfectly healthy successor that simply had nothing pushed to it for thirty days
    /// is never declared dead by the first flush ever made, on one transient revert - and books
    /// nothing without all three of:
    ///   (i)   a delivery attempt that had the whole {FORWARD_GAS} budget AND A RESOLVED
    ///         SUCCESSOR VAULT to work with failed once, which RECORDS {deadEvidenceAt} for this
    ///         attribution and forwards nothing (a successor whose vault is not
    ///         deployed yet has refused nothing and is never evidence);
    ///   (ii)  {DEAD_SUCCESSOR_DELAY} has elapsed since THAT timestamp; and
    ///   (iii) a SECOND full-budget attempt, made by this call, failed as well.
    /// Any successful delivery in between clears the evidence and puts the successor back to
    /// healthy. A failed flush returns 0 and leaves the queue exactly as it was; the reason is in
    /// {SuccessorDeliveryFailed} and, when the successor did not resolve at all, in
    /// {SuccessorUnresolved}.
    ///
    /// @dev The queue entry and the ledger are debited BEFORE the external call
    /// and restored if it fails, so at no instant of the successor's execution does this vault
    /// count the same wei both in {pendingForward} and as ETH it has already sent.
    function flushForward(uint256 attribution, uint256 max) external nonReentrant returns (uint256 amount) {
        uint256 pending = pendingForward[attribution];
        amount = pending < max ? pending : max;
        if (amount == 0) revert NothingToForward();

        Currency edge = EDGE;
        // gas-capped and unchecked-for-revert now: a hostile successor fails cheaply rather than
        // eating whatever the caller supplied
        address v = _resolveSuccessorVault();
        uint256 budget = _forwardBudget();
        bool delivered;
        bytes memory failure;
        if (v == address(0)) emit SuccessorUnresolved(roundManager.successor());
        if (v != address(0) && budget != 0) {
            // the fee may still be an unredeemed claim on the PoolManager; outside a swap this
            // vault can unlock and turn it into the real tokens the successor is paid with
            if (IERC20(Currency.unwrap(edge)).balanceOf(address(this)) < amount) redeem(edge);
            // No transient double-count. The debit is the instruction before the call and is
            // rolled back below on failure, so `pendingForward + sent` never exceeds the total.
            _dequeue(attribution, pending, amount);
            ledgerTotal[edge] -= amount;
            try this.deliverForward(v, amount, attribution, budget) {
                delivered = true;
            } catch (bytes memory reason) {
                failure = reason;
                ledgerTotal[edge] += amount;
                _requeue(attribution, amount);
            }
        }

        if (delivered) {
            // a successful delivery is proof the successor is alive: any standing evidence goes
            if (deadEvidenceAt[attribution] != 0) {
                deadEvidenceAt[attribution] = 0;
                emit SuccessorDeliveryEvidenceCleared(attribution);
            }
            emit ProtocolFeeForwarded(v, amount, attribution);
            return amount;
        }

        // a hop that merely ran out of a caller's thin gas budget says NOTHING about the
        // successor and may never become evidence against it
        if (budget < FORWARD_GAS) revert FlushGasTooLow();
        // Neither does a successor that has not RESOLVED yet. The registry can
        // name a stack whose vault is still to be deployed at the address its factory already
        // publishes, and resolution is deliberately not cached negatively for exactly that
        // reason. No delivery was attempted here, so there is nothing to hold against the
        // successor: {SuccessorUnresolved} is said above and the queue keeps the balance.
        if (v == address(0)) return 0;
        emit SuccessorDeliveryFailed(attribution, failure);

        uint64 evidence = deadEvidenceAt[attribution];
        if (evidence == 0) {
            // phase one: start this attribution's clock and forward nothing. Deliberately NOT a
            // revert - the whole point is that the timestamp persists.
            deadEvidenceAt[attribution] = uint64(block.timestamp);
            return 0;
        }
        if (block.timestamp < uint256(evidence) + DEAD_SUCCESSOR_DELAY) return 0;
        // both failures were REAL delivery attempts on a resolved vault (F-A)
        if (v == address(0)) return 0;

        // phase two: the ETH never left, so `ledgerTotal` is untouched - the fee simply stops
        // being the successor's and becomes this version's, on this version's ledgers
        _dequeue(attribution, pending, amount);
        // the successor the registry NAMES, not the resolved vault: on this path the resolution is
        // exactly what failed, so `v` is usually `address(0)` and says nothing
        emit SuccessorDeclaredDead(roundManager.successor(), attribution, amount);
        (bool ok, uint256 dev, uint256 creator, uint256 sleeve, uint256 reinforce) =
            _book(amount, attribution, attribution != UNATTRIBUTED);
        emit FeeSplit(edge, 0, amount, attribution, ok, dev, creator, sleeve, reinforce);
        return amount;
    }

    /// @notice ONE FLUSHED DELIVERY: move the tokens and tell the successor to book them.
    /// Callable only by this contract, so {flushForward} can roll the transfer back by catching a
    /// revert instead of stranding the queue entry.
    /// @dev The transfer and the notification are one atomic step: if the successor reverts, the
    /// tokens come back with it.
    function deliverForward(address v, uint256 amount, uint256 attribution, uint256 budget) external {
        if (msg.sender != address(this)) revert NotSelf();
        IERC20(Currency.unwrap(EDGE)).safeTransfer(v, amount);
        IFeeVault(v).receiveForward{gas: budget}(attribution, amount);
    }

    /// @dev Take `amount` out of the queue.
    function _dequeue(uint256 attribution, uint256 pending, uint256 amount) internal {
        pendingForward[attribution] = pending - amount;
        pendingForwardTotal -= amount;
    }

    /// @dev Put back what a failed delivery attempt took out. Silent: nothing was queued
    /// that was not already queued, and {SuccessorDeliveryFailed} is the event for the failure.
    function _requeue(uint256 attribution, uint256 amount) internal {
        pendingForward[attribution] += amount;
        pendingForwardTotal += amount;
    }

    /// @dev Queue a post-sunset fee under `attribution`. The caller owns `ledgerTotal`.
    function _queueForward(uint256 attribution, uint256 amount) internal {
        uint256 pending = pendingForward[attribution] + amount;
        pendingForward[attribution] = pending;
        pendingForwardTotal += amount;
        emit ProtocolFeeQueued(attribution, amount, pending);
    }

    /// @dev The successor version's FeeVault, resolved once through
    /// `roundManager.successor().factory().feeVault()` and cached forever after, or `address(0)`
    /// when the successor does not answer the handover ABI.
    ///
    /// @dev Both legs into the successor are GAS-CAPPED RAW-WORD static calls, exactly
    /// as `FamilyHook._staticAddress` resolves the successor's router. They are unauthenticated
    /// calls into an address that is only known to have code, and a typed call to one that burns
    /// gas or returns a dirty word made this resolution as expensive, or as revert-prone, as the
    /// successor chose. A negative answer is NOT cached: it is cheap now, and the answer can
    /// legitimately change if the successor is deployed later at the predicted address.
    function _resolveSuccessorVault() internal returns (address v) {
        v = successorVault;
        if (v != address(0)) return v;
        address su = roundManager.successor();
        if (su == address(0)) return address(0);
        address f = _staticAddress(su, abi.encodeCall(IPriorRegistry.factory, ()));
        if (f == address(0)) return address(0);
        v = _staticAddress(f, abi.encodeCall(IVersionFactory.feeVault, ()));
        if (v == address(0) || v.code.length == 0) return address(0);
        successorVault = v;
    }

    /// @dev A GAS-CAPPED static call that may fail or answer nonsense: `address(0)` means "no
    /// answer". The word is read RAW and validated rather than `abi.decode`d, so a return value
    /// with dirty upper bits is a non-answer instead of a revert. Mirrors
    /// `FamilyHook._staticAddress`.
    function _staticAddress(address target, bytes memory data) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall{gas: STATIC_GAS}(data);
        if (!ok || ret.length != 32) return address(0);
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 32))
        }
        if (word >> 160 != 0) return address(0); // dirty upper bits: not an address
        return address(uint160(word));
    }

    /// @dev `min(FORWARD_GAS, gasleft - BOOK_GAS_RESERVE)`, or 0 when there is not even that:
    /// see {FORWARD_GAS}.
    function _forwardBudget() internal view returns (uint256 budget) {
        uint256 g = gasleft();
        if (g <= BOOK_GAS_RESERVE) return 0;
        budget = g - BOOK_GAS_RESERVE;
        if (budget > FORWARD_GAS) budget = FORWARD_GAS;
    }

    /// @dev Book the failed hop locally. The NEGATIVE CACHE is only armed when the hop had its
    /// full {FORWARD_GAS} to work with: a hop that merely ran out of a caller's thin gas budget
    /// says nothing about the successor, and must not disable an honest handover forever.
    function _forwardingFailed(uint256 budget, uint256 amount) internal {
        if (budget >= FORWARD_GAS) forwardingFailed = true;
        emit ProtocolFeeForwardingFailed(roundManager.successor(), amount);
    }

    /// @notice One handover hop: move the ERC-6909 claim to the successor's vault and tell it to
    /// book the fee. Callable only by this contract, so that {accrue} can roll the transfer back
    /// by catching a revert instead of failing the swap it is inside.
    ///
    /// @dev The ledger is DEBITED FIRST, in the instruction before the claim leaves. The claim is
    /// gone for the whole of the successor's call, so crediting it back afterwards would leave
    /// `ledgerTotal` overstating this vault's holdings for exactly the window in which foreign
    /// code runs, and an introspecting successor would read a vault that looks insolvent. A
    /// revert anywhere below rolls the debit back with the transfer, so the property that the
    /// ledger never UNDERSTATES what the vault holds is unchanged: it is only ever lowered
    /// together with the holding it accounts for.
    function forwardProtocolFee(Currency currency, uint256 amount, uint256 attribution, uint256 hopsLeft) external {
        if (msg.sender != address(this)) revert NotSelf();
        address v = _resolveSuccessorVault();
        if (v == address(0)) revert NoSuccessorVault();
        ledgerTotal[currency] -= amount;
        // the fee is still an unredeemed claim on the PoolManager at this point (the hook minted
        // it to this vault moments ago), so the cheapest hand-over is the claim itself - the
        // receiving vault counts claims in {holdings} exactly as it counts real balance
        poolManager.transfer(v, currency.toId(), amount);
        IFeeVault(v).accrueForwarded(attribution, amount, hopsLeft - 1);
        // This too is a successful delivery to that attribution, so it withdraws
        // any standing dead-successor evidence
        if (deadEvidenceAt[attribution] != 0) {
            deadEvidenceAt[attribution] = 0;
            emit SuccessorDeliveryEvidenceCleared(attribution);
        }
        emit ProtocolFeeForwarded(v, amount, attribution);
    }

    /// @dev Split `protocolFee` over this version's OWN ledgers, with this version's own
    /// constants. Shared by the locally charged path ({accrue}) and the handover path
    /// ({accrueForwarded}); the caller owns `ledgerTotal` and the event.
    function _book(uint256 protocolFee, uint256 terminalIndex, bool attributed)
        internal
        returns (bool ok, uint256 dev, uint256 creator, uint256 sleeve, uint256 reinforce)
    {
        address creditToken;
        address coCreditToken;
        uint256 M;
        (ok, creditToken, coCreditToken, M) = _resolveAttribution(terminalIndex);
        ok = ok && attributed;

        dev = (protocolFee * DEV_BPS) / BPS;
        creator = ok ? (protocolFee * CREATOR_BPS) / BPS : 0;
        uint256 remainder = protocolFee - dev - creator;
        sleeve = (remainder * ANCESTOR_BPS) / BPS;
        reinforce = remainder - sleeve;

        devBalance += dev;
        if (creator != 0) {
            // A CANDIDATE trade splits the creator share 50/50 with the creator of the HEAD the
            // candidate is challenging (the round's parent), whose token the round is quoted in
            // and whose liquidity the candidate trades against. A canonical link's own trades are
            // unchanged: 100% to that link's creator.
            uint256 coCredit = coCreditToken == address(0) ? 0 : creator / 2;
            creatorBalance[creditToken] += creator - coCredit;
            if (coCredit != 0) creatorBalance[coCreditToken] += coCredit;
        }
        reinforcementEdge[M] += reinforce;
        ancestorTree.addSleeve(sleeve, M);
    }

    /// @dev True when `v` is the FeeVault of a version THIS one continues, walking the same
    /// registry chain `RoundManager.registryOf` walks, with the same hop bound.
    function _isPriorVault(address v) internal view returns (bool) {
        if (!isContinuation || v == address(0)) return false;
        address reg = roundManager.priorRegistry();
        for (uint256 hops = 1; hops <= MAX_FORWARD_HOPS; ++hops) {
            if (IPriorRegistry(reg).feeVault() == v) return true;
            reg = IPriorRegistry(reg).priorRegistry();
            if (reg == address(0)) return false;
        }
        return false;
    }

    /// @dev Resolve a router-supplied attribution index into the token whose creator is paid and
    /// the ancestor-sleeve depth `M`. Two shapes:
    ///   - a canonical index `i <= headIndex`  -> credit `canonical(i)`, `M = i - 1` (0 for
    ///     genesis), i.e. the sleeve is spread over the terminal token's ancestors.
    ///   - {CANDIDATE_ATTRIBUTION} | candidateId -> credit the candidate's own token, and the
    ///     HEAD token as the co-creditee of half the creator share, with the sleeve spread over
    ///     the whole canonical chain (`M = headIndex`), because a candidate hangs off the current
    /// head.
    /// Anything else is unattributed and flows entirely to the flywheel: an index nobody has
    /// minted yet can never be trusted, whatever the router said.
    function _resolveAttribution(uint256 terminalIndex)
        internal
        view
        returns (bool ok, address creditToken, address coCreditToken, uint256 M)
    {
        if (terminalIndex & CANDIDATE_ATTRIBUTION != 0) {
            uint256 candidateId = terminalIndex & ~CANDIDATE_ATTRIBUTION;
            if (candidateId >= roundManager.candidateCount()) return (false, address(0), address(0), 0);
            RoundManager.Candidate memory c = roundManager.candidateInfo(candidateId);
            uint256 parentIndex = roundManager.roundInfo(c.roundId).parentIndex;
            // DURING the round the creator share is split 50/50 with the creator of the
            // head the candidate is challenging - the candidate trades against that head's token
            // and its liquidity. AFTER the round there is no contest left to share: a trade in a
            // losing candidate's pool is that coin's own trade, so its creator takes the whole
            // creator share.
            bool trading = roundManager.phase(c.roundId) == RoundManager.Phase.Trading;
            return (true, c.token, trading ? roundManager.canonical(parentIndex) : address(0), parentIndex);
        }
        if (terminalIndex > roundManager.headIndex()) return (false, address(0), address(0), 0);
        return (true, roundManager.canonical(terminalIndex), address(0), terminalIndex == 0 ? 0 : terminalIndex - 1);
    }

    /// @inheritdoc IFeeVault
    function depositEdgeBidEarmark(uint256 amount) external {
        if (msg.sender != address(roundManager)) revert NotRoundManager();
        edgeBidEarmark += amount;
        ledgerTotal[EDGE] += amount;
        // the RoundManager transfers the forfeited bonds in the instruction before this call; the
        // delivery is verified, not assumed
        if (ledgerTotal[EDGE] > holdings(EDGE)) revert NotDelivered();
        emit EdgeBidEarmarked(amount);
    }

    // -------------------------------------------------------------------------------------
    // views
    // -------------------------------------------------------------------------------------

    /// @notice Edge currency still owed to generation `j` out of the ancestor sleeve.
    function claimableAncestor(uint256 j) public view returns (uint256) {
        int256 q = ancestorTree.query(j);
        uint256 gross = q <= 0 ? 0 : uint256(q) / WAD;
        uint256 claimed = ancestorClaimed[j];
        return gross > claimed ? gross - claimed : 0;
    }

    /// @notice Raw Fenwick point query for generation `j`, WAD-scaled (test/introspection).
    function ancestorPointQueryWad(uint256 j) external view returns (int256) {
        return ancestorTree.query(j);
    }

    /// @notice Everything the vault holds in `currency`: real balance plus unredeemed claims.
    function holdings(Currency currency) public view virtual returns (uint256) {
        uint256 real = IERC20(Currency.unwrap(currency)).balanceOf(address(this));
        return real + poolManager.balanceOf(address(this), currency.toId());
    }

    /// @notice The address that may claim `token`'s creator share (defaults to its creator).
    function creatorRecipient(address token) public view returns (address) {
        if (_creatorRecipientSet[token]) return _creatorRecipient[token];
        return roundManager.creatorOf(token);
    }

    // -------------------------------------------------------------------------------------
    // claims
    // -------------------------------------------------------------------------------------

    /// @notice Convert this vault's ERC-6909 claims on `currency` into a real balance.
    /// Permissionless: it moves nothing that is not already the vault's.
    function redeem(Currency currency) public {
        uint256 claims = poolManager.balanceOf(address(this), currency.toId());
        if (claims == 0) return;
        poolManager.unlock(abi.encode(currency, claims));
        emit Redeemed(currency, claims);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, address(this), amount);
        return "";
    }

    // -------------------------------------------------------------------------------------
    // developer transfer: announce -> wait ROLE_TRANSFER_DELAY -> execute
    // -------------------------------------------------------------------------------------

    /// @notice Announce a transfer of the developer address to `to`, executable
    /// {ROLE_TRANSFER_DELAY} from now. Current developer only, one pending transfer at a time.
    /// @dev What is ALREADY accrued in {devBalance} goes with the role: see {developer}.
    function announceDeveloperTransfer(address to) external {
        if (msg.sender != developer) revert NotDeveloper();
        if (to == address(0)) revert BadRecipient();
        if (developerTransferAt != 0) revert TransferPending();
        uint64 at = uint64(block.timestamp) + ROLE_TRANSFER_DELAY;
        pendingDeveloper = to;
        developerTransferAt = at;
        emit DeveloperTransferAnnounced(msg.sender, to, at);
    }

    /// @notice Execute an announced developer transfer once its delay has elapsed.
    /// Permissionless: the destination is fixed by the announcement, so the incoming holder can
    /// take the role even if the outgoing key is gone.
    function executeDeveloperTransfer() external {
        if (developerTransferAt == 0) revert NoTransferPending();
        if (block.timestamp < developerTransferAt) revert TransferNotReady();
        address from = developer;
        address to = pendingDeveloper;
        developer = to;
        pendingDeveloper = address(0);
        developerTransferAt = 0;
        emit DeveloperTransferExecuted(from, to);
    }

    /// @notice Take an announced developer transfer back before it takes effect. Current
    /// developer only; repeatable.
    function cancelDeveloperTransfer() external {
        if (msg.sender != developer) revert NotDeveloper();
        if (developerTransferAt == 0) revert NoTransferPending();
        address cancelled = pendingDeveloper;
        pendingDeveloper = address(0);
        developerTransferAt = 0;
        emit DeveloperTransferCancelled(msg.sender, cancelled);
    }

    function claimDev(address to) external nonReentrant notInsideUnlock returns (uint256 amount) {
        if (msg.sender != developer) revert NotDeveloper();
        amount = devBalance;
        if (amount == 0) revert NothingToClaim();
        devBalance = 0;
        ledgerTotal[EDGE] -= amount;
        redeem(EDGE);
        _sendToken(to, amount);
        emit DevClaimed(to, amount);
    }

    function claimCreator(address token, address to) external nonReentrant notInsideUnlock returns (uint256 amount) {
        if (msg.sender != creatorRecipient(token)) revert NotCreator();
        amount = creatorBalance[token];
        if (amount == 0) revert NothingToClaim();
        creatorBalance[token] = 0;
        ledgerTotal[EDGE] -= amount;
        redeem(EDGE);
        _sendToken(to, amount);
        emit CreatorClaimed(token, to, amount);
    }

    /// @notice Move the right to claim `token`'s FUTURE creator share. What has already accrued
    /// does not move with it: it is credited to the CURRENT recipient's own ledger here and stays
    /// claimable by them through {claimCreatorAccrued}.
    ///
    /// @dev AUDIT (spec discrepancy): the old implementation moved the right only, which - since
    /// `claimCreator` pays whoever holds the right AT CLAIM TIME - silently handed the unclaimed
    /// balance to the new recipient too. Selling or delegating the fee stream therefore gave away
    /// earnings that were already booked, with nothing in the call to say so. It also accepted
    /// `address(0)`, which burned the stream permanently; that is now refused.
    function transferCreatorRecipient(address token, address to) external {
        address current = creatorRecipient(token);
        if (msg.sender != current) revert NotCreator();
        if (to == address(0)) revert BadRecipient();
        uint256 accrued = creatorBalance[token];
        if (accrued != 0) {
            creatorBalance[token] = 0;
            creatorAccrued[current] += accrued;
            emit CreatorAccrued(current, token, accrued);
        }
        _creatorRecipient[token] = to;
        _creatorRecipientSet[token] = true;
        emit CreatorRecipientChanged(token, current, to);
    }

    /// @notice Claim what was accrued to `msg.sender` under a creator right they have since
    /// transferred away (see {transferCreatorRecipient}).
    function claimCreatorAccrued(address to) external nonReentrant notInsideUnlock returns (uint256 amount) {
        if (to == address(0)) revert BadRecipient();
        amount = creatorAccrued[msg.sender];
        if (amount == 0) revert NothingToClaim();
        creatorAccrued[msg.sender] = 0;
        ledgerTotal[EDGE] -= amount;
        redeem(EDGE);
        _sendToken(to, amount);
        emit CreatorAccruedClaimed(msg.sender, to, amount);
    }

    // -------------------------------------------------------------------------------------
    // keeper hooks: BidDeployer only
    //
    // The keeper machinery itself (the TWAP band guard, the size cap, the bid geometry and the
    // cross-version forwarding) lives in {BidDeployer}, which is immutable, ownerless and named
    // by this vault at construction. All it can do here is spend what a generation is ALREADY
    // owed, and every wei it draws is handed straight back out in the same call - either into a
    // permanently locked Locker position or to the keeper as the bounty.
    //
    // `_deployerCredit` is the leash on {payKeeper}: ETH can only be paid out of this vault on
    // the keeper path against a claim that {consumeAncestorClaim} has already deducted from a
    // ledger, so the BidDeployer can never move more than a generation's own money.
    // -------------------------------------------------------------------------------------

    /// @notice Edge currency currently deployable for generation `j` (sleeve + immediate-parent sleeve).
    function claimableEdge(uint256 j) public view returns (uint256) {
        return claimableAncestor(j) + reinforcementEdge[j];
    }

    /// @notice The drawdown bucket of generation `j`: when it was last drawn, what it
    /// holds right now, and the cap it refills to.
    function drawBucket(uint256 j) external view returns (uint64 updatedAt, uint256 available, uint256 cap) {
        return (drawdowns[j].updatedAt, _bucket(j), _dailyAllowance(claimableEdge(j)));
    }

    /// @notice ETH generation `j` can actually be drawn for RIGHT NOW: its claimable sleeve,
    /// capped by what its drawdown bucket holds. Keepers must size against this, not against
    /// {claimableEdge}.
    function drawableEdge(uint256 j) public view returns (uint256) {
        uint256 claimable = claimableEdge(j);
        uint256 available = _bucket(j);
        return available < claimable ? available : claimable;
    }

    /// @dev `available = min(cap, available + cap * dt / DRAW_WINDOW)` with
    /// `cap = DAILY_DRAW_BPS of what is claimable now`. A generation that has never
    /// been drawn starts full, so the first keeper call is not delayed by a day.
    function _bucket(uint256 j) internal view returns (uint256 available) {
        uint256 cap = _dailyAllowance(claimableEdge(j));
        Drawdown storage d = drawdowns[j];
        if (!d.initialised) return cap;
        // the clock is read in the SAME uint64 domain the field is stored in, so the two can
        // never disagree by a truncation; a clock that has wrapped below `updatedAt` refills
        // nothing rather than refilling everything
        uint64 nowT = uint64(block.timestamp);
        uint256 elapsed = nowT > d.updatedAt ? uint256(nowT - d.updatedAt) : 0;
        available = d.available;
        if (elapsed != 0) {
            available += elapsed >= DRAW_WINDOW ? cap : FullMath.mulDiv(cap, elapsed, DRAW_WINDOW);
        }
        if (available > cap) available = cap;
    }

    /// @dev {DAILY_DRAW_BPS} of `base`, except that a dust sleeve (where the 10% floor-divides to
    /// zero) is allowed in full: a few wei must not be made permanently unspendable.
    function _dailyAllowance(uint256 base) internal pure returns (uint256 allowance) {
        allowance = (base * DAILY_DRAW_BPS) / BPS;
        if (allowance == 0) allowance = base;
    }

    /// @notice ETH already consumed from a generation's ledgers and not yet paid out. Zero
    /// outside a BidDeployer call, always.
    uint256 public deployerCredit;

    modifier onlyBidDeployer() {
        if (msg.sender != bidDeployer) revert NotBidDeployer();
        _;
    }

    /// @notice Consume `edgeAmount` of generation `j`'s ETH (the Fenwick sleeve first, then the
    /// immediate-parent reinforcement) and credit it to the BidDeployer, which must then move it
    /// with {payKeeper} in the same call.
    function consumeAncestorClaim(uint256 j, uint256 edgeAmount) external onlyBidDeployer returns (uint256) {
        if (edgeAmount > claimableEdge(j)) revert TooMuchRequested();

        // Rate-limit the sleeve with a token bucket. A price manipulation that
        // survives the TWAP guards can still only take {DAILY_DRAW_BPS} of what generation `j` is
        // owed per 24 h - continuously, so there is no window boundary to burst across - and the
        // attacker has to hold the manipulation for days rather than for one block.
        uint256 available = _bucket(j);
        if (edgeAmount > available) revert DailyLimitExceeded(edgeAmount, available);
        Drawdown storage d = drawdowns[j];
        d.updatedAt = uint64(block.timestamp);
        d.initialised = true;
        d.available = available - edgeAmount;

        _consumeEdge(j, edgeAmount);
        deployerCredit += edgeAmount;
        emit LedgerDrawn(EDGE, edgeAmount);
        return edgeAmount;
    }

    /// @notice Draw up to `amount` of the PARENT-denominated hop pot of `parentToken` and send
    /// it to the BidDeployer. Partial by construction: the ledger is decremented, never
    /// zeroed, and a pot larger than the size cap can never brick the generation.
    function consumeReinforcement(address parentToken, uint256 amount)
        external
        onlyBidDeployer
        returns (uint256 drawn)
    {
        Currency currency = Currency.wrap(parentToken);
        drawn = _draw(reinforcementBalance[parentToken], amount);
        if (drawn == 0) return 0;
        reinforcementBalance[parentToken] -= drawn;
        ledgerTotal[currency] -= drawn;
        redeem(currency);
        emit LedgerDrawn(currency, drawn);
        IERC20(parentToken).safeTransfer(bidDeployer, drawn);
    }

    /// @notice Draw up to `amount` of the forfeited-bond earmark and send it to the BidDeployer.
    function consumeEdgeEarmark(uint256 amount) external onlyBidDeployer returns (uint256 drawn) {
        drawn = _draw(edgeBidEarmark, amount);
        if (drawn == 0) return 0;
        edgeBidEarmark -= drawn;
        ledgerTotal[EDGE] -= drawn;
        redeem(EDGE);
        emit LedgerDrawn(EDGE, drawn);
        _sendToken(bidDeployer, drawn);
    }

    /// @notice Pay out ETH the BidDeployer has already consumed from a generation's ledgers:
    /// the keeper's bounty-inclusive payout, or the genesis sleeve on its way into the bid.
    function payKeeper(address to, uint256 edgeAmount) external onlyBidDeployer {
        if (edgeAmount == 0) return;
        if (edgeAmount > deployerCredit) revert TooMuchRequested();
        deployerCredit -= edgeAmount;
        redeem(EDGE);
        _sendToken(to, edgeAmount);
    }

    /// @dev `min(pot, room)`: the partial-draw primitive every draw here is built on.
    function _draw(uint256 pot, uint256 room) internal pure returns (uint256) {
        return pot < room ? pot : room;
    }

    /// @dev Consume `amount` of generation `j`'s ETH: the Fenwick sleeve first, then the
    /// immediate-parent reinforcement.
    function _consumeEdge(uint256 j, uint256 amount) internal {
        if (amount == 0) return;
        uint256 fromSleeve = claimableAncestor(j);
        if (fromSleeve > amount) fromSleeve = amount;
        ancestorClaimed[j] += fromSleeve;
        uint256 fromReinforce = amount - fromSleeve;
        if (fromReinforce != 0) reinforcementEdge[j] -= fromReinforce;
        ledgerTotal[EDGE] -= amount;
    }

    /// @dev `address(0)` is refused on EVERY payout path. Plenty of ERC-20s accept a
    /// transfer to the zero address, and each of the claim paths above debits its ledger BEFORE
    /// the send, so a mistyped destination burns the claim permanently with nothing to show for
    /// it. The payout is an edge-currency token transfer, never a native send.
    function _sendToken(address to, uint256 amount) internal {
        if (to == address(0)) revert BadRecipient();
        IERC20(Currency.unwrap(EDGE)).safeTransfer(to, amount);
    }
}
