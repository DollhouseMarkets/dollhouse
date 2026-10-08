// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {FamilyToken, FAMILY_TOTAL_SUPPLY} from "./FamilyToken.sol";
import {FamilyHook} from "./FamilyHook.sol";
import {Locker} from "./Locker.sol";
import {RoundManager, RoundManagerDeployer} from "./RoundManager.sol";
import {IFeeVault} from "./interfaces/IFeeVault.sol";
import {IFamilyHook} from "./interfaces/IFamilyHook.sol";
import {IVenueOracle} from "./interfaces/IVenueOracle.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StandardCurve} from "./libraries/StandardCurve.sol";
import {FenwickRangeAdd} from "./libraries/FenwickRangeAdd.sol";
import {V4UnlockGuard} from "./libraries/V4UnlockGuard.sol";
import {CurveRange} from "./types/CurveRange.sol";
import {CurveSegment} from "./types/CurveSegment.sol";

/// @title FamilyFactory
/// @notice Dollhouse: the only contract that may create a family pool. It deploys the token,
/// pre-registers the exact PoolKey and initial price with the hook, initializes the pool and has
/// the Locker place the standard curve - all in one transaction, so a launch can never be
/// front-run into a poisoned pool. There is no owner and no privileged caller: candidates go to
/// whoever pays the bond during a round's registration window.
///
/// @dev THE GENESIS IS EXTERNAL. Canonical index 0 is no longer a token this factory
/// mints on a curve of its own: it is {GENESIS_TOKEN}, an ERC-20 launched and graduated outside
/// this protocol, ADOPTED once by {adoptGenesis}. Index 0 therefore has NO pool key in this
/// deployment - the market that quotes it lives outside - and every consumer of `poolKeyOf`
/// guards on `hooks == address(0)`. The chain this protocol owns starts at link ONE, whose pools
/// are quoted in {GENESIS_TOKEN}, which is also the currency every fee, bond and payout of the
/// protocol is denominated in. Nothing here touches native ETH.
///
/// @dev The factory deploys the Locker, the hook and the RoundManager itself, so that all four
/// addresses are mutually consistent without an initializer: the hook is CREATE2-deployed with a
/// salt mined off-chain (see `HookMiner`) against this factory's own predicted address, so the
/// hook address encodes its permission bits. The FeeVault, the BidDeployer and the FamilyRouter
/// are deployed AFTER the factory (they read its getters) and are passed in here as predicted
/// addresses.
contract FamilyFactory {
    using SafeERC20 for IERC20;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Tick spacing for every family pool.
    int24 public constant TICK_SPACING = 60;
    /// @notice Pool LP fee is zero: all fees are charged by the hook.
    uint24 public constant POOL_FEE = 0;
    /// @notice The decimals the adopted genesis token must have. Every curve, bond and fee number
    /// in this protocol is an 18-decimal quantity; a token with any other scale would silently
    /// misprice all of them.
    uint8 public constant GENESIS_DECIMALS = 18;

    IPoolManager public immutable poolManager;
    /// @notice The FeeVault, the BidDeployer and the canonical router. All three are deployed
    /// AFTER this factory (they read its getters), so their code cannot be checked here; {wire}
    /// does it once, lazily.
    address public immutable feeVault;
    /// @notice The keeper/bid half of the treasury: the only address {locker} accepts a bid
    /// from, and the address a LATER version hands this version's ancestor payouts to.
    address public immutable bidDeployer;
    address public immutable router;
    /// @notice THE EDGE CURRENCY. The externally launched token this deployment adopts as
    /// canonical index 0 and prices the whole chain in. A deploy constant: the FeeVault reads it
    /// off this factory and holds it as its own immutable, so it can never be changed or
    /// re-pointed after the stack exists.
    address public immutable GENESIS_TOKEN;
    /// @dev The deploy-constant standard curve. Written once in the constructor; there is no
    /// setter, so it is immutable in everything but the storage layout (a dynamic array cannot
    /// be declared `immutable` in Solidity).
    CurveSegment[] private _curveSpec;
    Locker public immutable locker;
    FamilyHook public immutable hook;
    RoundManager public immutable roundManager;
    /// @notice The registry this deployment's RoundManager continues, or `address(0)` for a
    /// fresh trunk. A CONTINUATION stack has no genesis of its own: {adoptGenesis} is dead.
    address public immutable priorRegistry;
    /// @notice The helper that CREATEs this version's {RoundManager}, kept out of this factory's
    /// own init code for EIP-3860 exactly like {tokenImplementation}.
    address public immutable roundManagerDeployer;
    /// @notice The single FamilyToken implementation every family token is an EIP-1167 minimal
    /// proxy of. Deployed immediately BEFORE this factory, naming this factory as the only
    /// address that may {FamilyToken-initialize} a clone; the link is verified below. It is kept
    /// out of this constructor so that the factory's own init code stays well clear of the
    /// EIP-3860 limit.
    address public immutable tokenImplementation;

    /// @notice Base URL every family token's on-chain metadata document
    /// ({FamilyToken.tokenURI} / {FamilyToken.metadataURI}) is served from: the full document URL
    /// is this string plus the token's own lowercase hex address. Set once here, at construction;
    /// there is no setter. Not `immutable` - Solidity immutables cannot hold a dynamically-sized
    /// type - but written exactly once and read by every clone through a view call rather than
    /// copied into each clone's storage at `initialize` (see {FamilyToken.metadataURI} for why
    /// that keeps per-launch gas lower).
    string public metadataBase;

    /// @notice The account that deployed this factory, and the creator recorded against
    /// canonical index 0 when {wire} adopts the genesis token. Fixed at construction
    /// so that adoption has nothing left for a caller to win by front-running it.
    address public immutable DEPLOYER;

    /// @notice True once {wire} has verified that the FeeVault and the router have code, and -
    /// on a fresh trunk - has adopted the genesis token as canonical index 0.
    bool public wired;

    /// @notice True once {wire} has written canonical index 0. Read {genesisToken} for the token
    /// itself, which also answers for a continuation stack (whose genesis was adopted by an
    /// earlier version).
    bool public genesisAdopted;
    /// @notice The creator recorded against the genesis token: always {DEPLOYER}. Recorded for
    /// creator fee attribution and for nothing else.
    address public genesisCreator;

    /// @notice The parent-unit amount every candidate of a round had its launch curve built
    /// against (the `parentSupply` argument of {StandardCurve.build}), keyed by round id. Written
    /// by the round's FIRST registration and reused by every sibling after it, so all candidates
    /// of one round open at the same price whatever happens to the parent in between.
    mapping(uint256 => uint256) public roundCurveBasis;
    /// @notice The curve basis a launched token's pool was built against. Read by the
    /// BidDeployer and the web to rebuild a pool's launch curve exactly, instead of re-deriving
    /// it from the parent's live supply, which drifts: {FamilyToken.burn} is permissionless.
    mapping(address => uint256) public curveBasisOf;

    // -------------------------------------------------------------------------------------
    // the ETH-anchored start (private/V2_ORACLE_SPEC.md)
    // -------------------------------------------------------------------------------------

    /// @notice The {IVenueOracle} the start rule reads $DOLL's averaged ETH price from, or
    /// `address(0)` until {bindVenueOracle} has run: every round then opens on
    /// {START_FALLBACK_DOLL}, flagged. Written once, never changed after.
    address public venueOracle;
    /// @notice The PoolId of the ETH/$DOLL venue the start rule may be bound to (native ETH as
    /// currency0, {GENESIS_TOKEN} as currency1, the venue's fee, spacing and hooks), fixed at
    /// deploy from the same key the ETH zap uses. Zero: no venue, {bindVenueOracle} is dead and
    /// every start is the constant fallback.
    bytes32 public immutable EXPECTED_VENUE_ID;
    /// @notice The runtime code hash of the one {VenueOracle} {bindVenueOracle} accepts: that
    /// contract's code with its immutables (this PoolManager, {EXPECTED_VENUE_ID} and the two
    /// pokers) filled in, computed by the deploy script. The getters alone could be answered by
    /// any contract; the code hash cannot, so a permissionless bind cannot be won with a
    /// look-alike that reports any price it likes.
    bytes32 public immutable EXPECTED_ORACLE_CODEHASH;
    /// @notice E0: the ETH market cap every candidate aims to open at, in wei.
    uint256 public immutable START_FDV_WEI;
    /// @notice Upper clamp: a candidate never opens above this share (bps) of its parent's cap.
    uint256 public immutable START_MAX_PARENT_BPS;
    /// @notice Lower clamp (WAD): a candidate never opens below this share of its parent's cap.
    /// At the curve's `spec[0].fdvRatioLowerWad` it is exactly the old parent-relative rule.
    uint256 public immutable START_MIN_PARENT_WAD;
    /// @notice The $DOLL amount a start aims at when the oracle is absent, unusable or failing.
    uint256 public immutable START_FALLBACK_DOLL;
    /// @notice Gas forwarded to each oracle read; a read that runs out falls back, never reverts.
    uint256 public immutable ORACLE_GAS;
    /// @notice A chain link whose averages cover less than this opens the coin at the lower clamp.
    uint32 public immutable START_LINK_MIN_COVER_S;
    /// @notice The most chain links one start walks live; deeper parents rescale an anchor.
    uint256 public immutable START_WALK_MAX;

    /// @dev The two hook averages a link is priced with (the keeper path's own windows).
    uint32 internal constant LINK_FAST_WINDOW_S = 1800;
    uint32 internal constant LINK_SLOW_WINDOW_S = 7 days;

    /// @dev {StartPriced} flag bits (also {roundStartFlags}). LOW BYTE, the factory's own:
    ///   1   VENUE_FALLBACK    the constant {START_FALLBACK_DOLL} was used (no usable venue price)
    ///   2   LINK_YOUNG        a chain link's averages were too short: opened at the lower clamp
    ///   4   CLAMP_LO          raised to the lower clamp
    ///   8   CLAMP_HI          capped at the upper clamp
    ///   16  WALK_CAPPED       the walk started from an anchor ({START_WALK_MAX})
    ///   32  LIMITER           the oracle's step limiter is clamping (streak > 0)
    ///   64  ANCHOR_MISSING    no anchor deep enough: opened at the lower clamp
    ///   128 VENUE_STALE_USED  the oracle was stale (no poke for over 30 min, under 24 h) and its
    ///                         averages up to the last sample were used
    /// HIGH BYTE (bits 8-15): the oracle's {IVenueOracle.startPrice} status (1 noData, 2 stale,
    /// 4 fastShort, 8 slowShort), or 16 when there was no read: unbound, reverted, out of gas or
    /// malformed.
    /// FAST-ONLY (no bit of its own; the low byte is full): high byte == 8 with VENUE_FALLBACK
    /// clear means the oracle priced from its last ten clean minutes, max(fast, slow so far),
    /// before 24 h of slow history existed. High byte 8 with VENUE_FALLBACK set means fast-only
    /// was refused (the constructor seed or a clamped sample lies in the last ten minutes) and
    /// the constant was used.
    uint16 internal constant VENUE_FALLBACK = 1;
    uint16 internal constant LINK_YOUNG = 2;
    uint16 internal constant CLAMP_LO = 4;
    uint16 internal constant CLAMP_HI = 8;
    uint16 internal constant WALK_CAPPED = 16;
    uint16 internal constant LIMITER = 32;
    uint16 internal constant ANCHOR_MISSING = 64;
    uint16 internal constant VENUE_STALE_USED = 128;
    uint8 internal constant ORACLE_FAILED = 16;
    /// @dev The oracle's stale-only status, the one status whose price is still used.
    uint256 internal constant ORACLE_STALE = 2;
    /// @dev The oracle's slow-short-only status: priced (fast-only) when it carries a price.
    uint256 internal constant ORACLE_SLOW_SHORT = 8;
    /// @dev Gas an oracle read needs on top of {ORACLE_GAS} for the call itself (a cold account)
    /// and the 1/64 the EVM withholds, so the callee always receives the full {ORACLE_GAS}.
    uint256 internal constant ORACLE_CALL_OVERHEAD = 5000;

    /// @notice The {StartPriced} flags of round `roundId`'s start, for readers without logs.
    mapping(uint256 => uint16) public roundStartFlags;
    /// @notice Walk-cap anchors: `anchorUnits[i]` units of canonical index `i` were worth
    /// `anchorDoll[i]` $DOLL on the walk that recorded them. A parent deeper than
    /// {START_WALK_MAX} starts from the newest anchor, rescaled to today's $DOLL target, and walks
    /// only the links below it, so registration gas is bounded at any depth.
    mapping(uint256 => uint256) public anchorUnits;
    mapping(uint256 => uint256) public anchorDoll;
    /// @notice The deepest index holding an anchor (0: none).
    uint256 public anchorTop;

    /// @notice How the ETH-anchored start is configured. See the immutables of the same names.
    struct StartSetup {
        bytes32 expectedVenueId;
        bytes32 oracleCodehash;
        uint256 fdvWei;
        uint256 maxParentBps;
        uint256 minParentWad;
        uint256 fallbackDoll;
        uint256 oracleGas;
        uint32 linkMinCoverS;
        uint256 walkMax;
    }

    /// @dev One start computation, before it is cached.
    struct StartQuote {
        uint160 sqrtP;
        uint256 doll;
        uint256 cap;
        uint256 basis;
        uint16 flags;
        uint256 anchorIndex;
        uint256 anchorUnits;
    }

    /// @notice Canonical index 0 was adopted from an externally launched token.
    event GenesisAdopted(address indexed adopter, address indexed token, uint256 totalSupply);
    event CandidateCreated(
        uint256 indexed roundId,
        uint256 indexed candidateId,
        address indexed token,
        PoolId poolId,
        uint160 initSqrtPriceX96,
        bool tokenIsCurrency0
    );
    /// @notice `token`'s launch curve was built against `basis` parent units (see {curveBasisOf}).
    event CurveBasis(uint256 indexed roundId, address indexed token, uint256 basis);
    /// @notice Round `roundId`'s start, priced once: venue sqrt price `sqrtP` (0 on the
    /// fallback), $DOLL target `dollTarget`, start cap `startCap` in `parent` units after the
    /// clamps, curve basis `basis`, and `flags` (low byte: 1 venue fallback, 2 young link,
    /// 4 lower clamp, 8 upper clamp, 16 walk capped, 32 oracle limiter active, 64 anchor
    /// missing, 128 stale oracle averages used; high byte: the oracle's status, 16 = no read:
    /// unbound or failed). The layout is spelled out at {VENUE_FALLBACK}.
    event StartPriced(
        uint256 indexed roundId,
        address indexed parent,
        uint160 sqrtP,
        uint256 dollTarget,
        uint256 startCap,
        uint256 basis,
        uint16 flags
    );
    /// @notice A walk-cap anchor was written: `anchorUnits` units of canonical index `index` were
    /// worth `anchorDoll` $DOLL (see {anchorUnits}). Deeper starts rescale from it.
    event AnchorWritten(uint256 indexed index, uint256 anchorUnits, uint256 anchorDoll);
    /// @notice The start rule now reads `oracle` (see {bindVenueOracle}). Emitted once, ever.
    event VenueOracleBound(address indexed oracle);

    /// @notice Canonical index 0 has already been adopted; it can only ever happen once.
    error GenesisAlreadyAdopted();
    /// @notice The adopted token is not an 18-decimal ERC-20 with a non-zero supply.
    error BadGenesisToken();
    error WrongBond();
    /// @notice The round's bond is larger than the `maxBond` the registrant agreed to.
    error BondTooHigh(uint256 bondAmount, uint256 maxBond);
    /// @notice The FeeVault, the BidDeployer or the router has no code: the stack was never
    /// completed.
    error NotWired();
    /// @notice The REN-01 unlock guard does not read `false` against the deployed PoolManager
    /// outside an unlock: it is not bound to this manager's lock slot, and would fail open.
    error GuardNotBound();
    /// @notice The next canonical index would exceed the Fenwick sleeve's addressable range.
    error ChainDepthLimit();
    /// @notice The supplied FamilyToken implementation does not name this factory.
    error BadTokenImplementation();
    /// @notice A candidate cannot be registered before canonical index 0 exists.
    error GenesisNotAdopted();
    /// @notice The {StartSetup} is inconsistent (clamps inverted or zero, no walk, a venue id
    /// without an oracle code hash or the reverse).
    error BadStartSetup();
    /// @notice {bindVenueOracle} has already run; the binding is permanent.
    error OracleAlreadyBound();
    /// @notice The oracle offered to {bindVenueOracle} is not the expected {VenueOracle} on the
    /// expected venue and PoolManager (or this deployment has no venue).
    error BadVenueOracle();
    /// @notice Too little gas is left to give an oracle read its full {ORACLE_GAS}: the call
    /// reverts rather than let a starved read fall back silently.
    error OracleGasShort();
    /// @notice {quoteStart} was asked about a token that is not on the canonical chain.
    error NotCanonical();

    /// @notice How the RoundManager is built. `deployer` is the {RoundManagerDeployer} this
    /// factory CREATEs it through - kept out of this factory's own init code for EIP-3860. The
    /// rest is the randomness wiring: the randomness source (or `address(0)` for none), the
    /// deterministic-fallback timeout, and the testnet schedule divisor.
    struct RoundSetup {
        address deployer;
        address randomness;
        uint64 endTimeout;
        uint64 durationScaleDiv;
    }

    constructor(
        IPoolManager _poolManager,
        address _feeVault,
        address _bidDeployer,
        address _router,
        uint256 _hopFeePpm,
        uint256 _hFracWad,
        uint256 _hMinFracWad,
        address _genesisToken,
        RoundManager.Bond memory _bond,
        uint256 _maxIndex,
        address _steward,
        uint64 _sunsetDelay,
        address _priorRegistry,
        CurveSegment[] memory _standardCurve,
        bytes32 _hookSalt,
        address _tokenImplementation,
        string memory _metadataBase,
        RoundSetup memory _roundSetup,
        StartSetup memory _startSetup
    ) {
        // the clamps must bracket a non-empty band, and the walk must take at least one link
        if (
            (_startSetup.expectedVenueId == bytes32(0)) != (_startSetup.oracleCodehash == bytes32(0))
                || _startSetup.fdvWei == 0 || _startSetup.fdvWei > type(uint96).max || _startSetup.maxParentBps == 0
                || _startSetup.maxParentBps > BPS || _startSetup.minParentWad == 0
                || _startSetup.minParentWad * BPS > _startSetup.maxParentBps * 1e18 || _startSetup.walkMax == 0
        ) revert BadStartSetup();
        EXPECTED_VENUE_ID = _startSetup.expectedVenueId;
        EXPECTED_ORACLE_CODEHASH = _startSetup.oracleCodehash;
        START_FDV_WEI = _startSetup.fdvWei;
        START_MAX_PARENT_BPS = _startSetup.maxParentBps;
        START_MIN_PARENT_WAD = _startSetup.minParentWad;
        START_FALLBACK_DOLL = _startSetup.fallbackDoll;
        ORACLE_GAS = _startSetup.oracleGas;
        START_LINK_MIN_COVER_S = _startSetup.linkMinCoverS;
        START_WALK_MAX = _startSetup.walkMax;
        // the edge currency must at least be a contract at construction time; its decimals and
        // supply are checked when it is adopted, which is the moment the chain starts
        if (_genesisToken == address(0) || _genesisToken.code.length == 0) revert BadGenesisToken();
        GENESIS_TOKEN = _genesisToken;
        DEPLOYER = msg.sender;
        if (FamilyToken(_tokenImplementation).factory() != address(this)) revert BadTokenImplementation();
        tokenImplementation = _tokenImplementation;
        metadataBase = _metadataBase;
        StandardCurve.validate(_standardCurve);
        for (uint256 i = 0; i < _standardCurve.length; i++) {
            _curveSpec.push(_standardCurve[i]);
        }
        poolManager = _poolManager;
        feeVault = _feeVault;
        bidDeployer = _bidDeployer;
        router = _router;
        locker = new Locker(_poolManager, address(this), _bidDeployer);
        hook = new FamilyHook{salt: _hookSalt}(
            _poolManager, address(this), address(locker), _feeVault, _router, _hopFeePpm
        );
        // the venue lock trusts the implementation's immutables: they must be exactly this stack
        {
            FamilyToken impl = FamilyToken(_tokenImplementation);
            if (
                impl.HOOK() != address(hook) || impl.LOCKER() != address(locker) || impl.FEE_VAULT() != _feeVault
                    || impl.POOL_MANAGER() != address(_poolManager)
            ) revert BadTokenImplementation();
        }
        priorRegistry = _priorRegistry;
        roundManagerDeployer = _roundSetup.deployer;
        roundManager = RoundManagerDeployer(_roundSetup.deployer)
            .deploy(
                IFamilyHook(address(hook)),
                IFeeVault(_feeVault),
                _hFracWad,
                _hMinFracWad,
                _bond,
                _maxIndex,
                _steward,
                _sunsetDelay,
                RoundManager.Continuation({priorRegistry: _priorRegistry}),
                RoundManager.EndRandomness({
                    source: _roundSetup.randomness,
                    endTimeout: _roundSetup.endTimeout,
                    durationScaleDiv: _roundSetup.durationScaleDiv
                })
            );
        if (roundManager.factory() != address(this)) revert NotWired();
    }

    /// @notice One-time, permissionless, admin-free wiring check: the FeeVault, the
    /// BidDeployer and the router are address PREDICTIONS at construction time, so their code
    /// can only be verified once they exist. Both launch entrypoints call this, so nothing can
    /// ever be launched into a half-deployed stack; after the first success it is a single warm
    /// SLOAD.
    ///
    /// @dev The REN-01 guard is bound to the deployed PoolManager here. `V4UnlockGuard`
    /// reads one transient slot of v4-core's `Lock` library through `exttload`; against a manager
    /// that does not implement `Exttload`, or whose lock slot differs, the read would either
    /// revert or answer `false` forever - and a guard that answers `false` forever is a guard
    /// that FAILS OPEN, silently. So the read is exercised once, at the moment the stack is
    /// wired: it must not revert, and outside an unlock (which this call is, by construction of
    /// the check below) it must answer `false`. The other half - that it answers `true` INSIDE
    /// an unlock - cannot be proved from here without opening one, and is proved at deploy time
    /// by `V4UnlockGuardProbe` (script/Deploy.s.sol) and on the live singleton by
    /// `test/fork/UnlockGuard.fork.t.sol`.
    /// @dev THE GENESIS IS ADOPTED HERE, not by a separate permissionless call. The
    /// old `adoptGenesis` entry point was front-runnable: everything about the adoption is fixed
    /// by the deploy constants except the creator attribution of index 0, and whoever sent the
    /// transaction first kept that forever. Adoption now happens once, inside this same one-time
    /// step, with the creator fixed at construction as {DEPLOYER}. Whoever calls {wire} - the
    /// deploy script, or the first registrant on a stack whose deployment stopped short - the
    /// outcome is identical, so there is nothing left to race for.
    function wire() public {
        if (wired) return;
        if (feeVault.code.length == 0 || router.code.length == 0) revert NotWired();
        if (bidDeployer.code.length == 0) revert NotWired();
        if (V4UnlockGuard.isInsideUnlock(address(poolManager))) revert GuardNotBound();
        wired = true;
        // a continuation stack starts at the prior trunk's head: there is no second genesis, ever
        if (priorRegistry != address(0)) return;
        _adoptGenesis();
    }

    /// @dev Write {GENESIS_TOKEN} into the registry as canonical index 0 and the first head. The
    /// token must be an 18-decimal, already-issued ERC-20; both are read through the metadata
    /// interface, so a token that does not answer either one is refused rather than adopted
    /// blind. Index 0 is recorded with NO pool key: its market lives outside this protocol (the
    /// launch venue the token graduated on) and this stack never swaps there, so `poolKeyOf(0)`
    /// answers a zero key and every consumer guards on `hooks == address(0)`. The chain this
    /// protocol owns, prices and charges fees on starts at link ONE.
    function _adoptGenesis() internal {
        if (genesisAdopted) revert GenesisAlreadyAdopted();
        address token = GENESIS_TOKEN;
        if (IERC20Metadata(token).decimals() != GENESIS_DECIMALS) revert BadGenesisToken();
        uint256 supply = IERC20(token).totalSupply();
        if (supply == 0) revert BadGenesisToken();

        genesisAdopted = true;
        genesisCreator = DEPLOYER;
        roundManager.adoptGenesis(token, DEPLOYER);

        emit GenesisAdopted(DEPLOYER, token, supply);
    }

    /// @notice ONE-SHOT, OWNERLESS BIND of the venue oracle the start rule reads. The stack may
    /// deploy before $DOLL's venue exists (its bonding curve has not graduated), so the oracle
    /// cannot be a constructor argument; it is bound here, by anyone, exactly once. Only the
    /// oracle fixed at deploy passes: its runtime code must hash to {EXPECTED_ORACLE_CODEHASH}
    /// (the {VenueOracle} code with this PoolManager, the expected venue and the two pokers
    /// baked in), and it must report {EXPECTED_VENUE_ID} and this {poolManager}. That it has code
    /// at all proves its constructor's venue checks passed (initialised, in-range liquidity).
    /// Until bound, every start is the constant fallback, flagged. A fresh bind keeps the fallback
    /// until the oracle has ten clean minutes (fast-only, status 8: no seed or clamped sample in
    /// the 10 min window); it needs 24 h of slow history for status 0.
    function bindVenueOracle(address oracle) external {
        if (venueOracle != address(0)) revert OracleAlreadyBound();
        bytes32 expected = EXPECTED_VENUE_ID;
        if (
            expected == bytes32(0) || oracle.codehash != EXPECTED_ORACLE_CODEHASH
                || PoolId.unwrap(IVenueOracle(oracle).venueId()) != expected
                || address(IVenueOracle(oracle).poolManager()) != address(poolManager)
        ) revert BadVenueOracle();
        venueOracle = oracle;
        emit VenueOracleBound(oracle);
    }

    /// @notice The deploy-constant standard curve every candidate is launched on.
    function curveSpec() public view returns (CurveSegment[] memory) {
        return _curveSpec;
    }

    /// @notice The starting FDV, in parent units, of a candidate launched against a curve basis of
    /// `parentSupply`. A pure function of the argument: it does NOT say what a given token opened
    /// at - a candidate's basis is fixed per round (see {roundCurveBasis}) and the parent's live
    /// supply can drift away from it. Prefer {startFdvOf} for a launched token.
    function startFdv(uint256 parentSupply) external view returns (uint256) {
        return StandardCurve.startFdv(_curveSpec, parentSupply);
    }

    /// @notice The starting FDV, in parent units, `token`'s pool was launched at, from its stored
    /// {curveBasisOf}. Zero for an address this factory never launched.
    function startFdvOf(address token) external view returns (uint256) {
        return StandardCurve.startFdv(_curveSpec, curveBasisOf[token]);
    }

    /// @notice The one and only genesis token of the trunk this factory is part of. For a
    /// continuation stack it is resolved through the registry chain (canonical index 0).
    function genesisToken() public view returns (address) {
        if (priorRegistry != address(0)) return roundManager.canonical(0);
        return GENESIS_TOKEN;
    }

    /// @notice Register a succession candidate in the current round, opening the round if the
    /// chain is idle. The bond ({RoundManager.bondFor} of the index the round competes for) is
    /// escrowed in the RoundManager, IN {GENESIS_TOKEN}: the caller must have approved this
    /// factory for it first.
    ///
    /// The candidate is quoted in the CURRENT HEAD token, gets the identical {StandardCurve}
    /// starting at `START_RATIO` of the head's supply, and its pool trades from the moment it is
    /// created (its own 3-second snipe tax runs from that moment); the round clock still starts at
    /// the round's `tradingStart`, which is what every candidate is scored from. The child
    /// token's address may sort either side of its parent, so both curve orientations are
    /// supported.
    ///
    /// @dev No longer `payable`. The bond is an ERC-20 transfer of the edge currency,
    /// pulled from `msg.sender` here and forwarded to the RoundManager in the same call, so the
    /// escrow, the refund and the forfeit are all token moves and this stack never holds ETH.
    ///
    /// @param maxBond THE MOST THE CALLER WILL PAY, in the edge currency. The bond
    /// DOUBLES with the index the round competes for, so a blanket ERC-20 allowance left standing
    /// across a rollover would silently be charged the next round's larger bond. The caller
    /// states the figure it was shown and the pull reverts rather than exceed it. Pass
    /// `type(uint256).max` to accept whatever {RoundManager.bondFor} says.
    function registerCandidate(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        uint256 maxBond
    ) external returns (address token, PoolKey memory key, uint256 candidateId) {
        wire();
        // canonical index 0 answers for a continuation stack by delegation, so this one read
        // covers both shapes: nothing can be registered before the chain has a root
        address edge = roundManager.canonical(0);
        if (edge == address(0)) revert GenesisNotAdopted();
        // The ancestor sleeve is a Fenwick tree over a bounded index space. Refuse the
        // registration that could create an unaddressable generation rather than let the tree
        // revert later inside a swap and brick the whole chain.
        if (roundManager.headIndex() + 1 > FenwickRangeAdd.MAX_INDEX) revert ChainDepthLimit();
        // the round's own bond is fixed when it opens (it doubles with depth), so the amount
        // is pulled against what the RoundManager actually wants, not a global constant
        (uint256 roundId, uint64 tradingStart, uint64 nominalEnd, uint32 scoreSlotS, address parent, uint256 bondAmount)
        = roundManager.openRoundIfIdle();
        // The bond the caller agreed to, checked before any state is written and long
        // before the pull. An allowance left standing across a rollover is charged the bond the
        // registrant was quoted or nothing at all.
        if (bondAmount > maxBond) revert BondTooHigh(bondAmount, maxBond);

        token = Clones.clone(tokenImplementation);
        // 100% of every family supply is locked liquidity: there is no allocation of any kind
        FamilyToken(token).initialize(name, symbol, uri, address(locker));
        bool tokenIsCurrency0 = token < parent;

        key = PoolKey({
            currency0: Currency.wrap(tokenIsCurrency0 ? token : parent),
            currency1: Currency.wrap(tokenIsCurrency0 ? parent : token),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // a candidate sells its WHOLE supply: `saleSupply == tokenSupply`, no allocation
        uint256 basis = _curveBasis(roundId, parent);
        curveBasisOf[token] = basis;
        emit CurveBasis(roundId, token, basis);
        (CurveRange[] memory ranges, uint160 initSqrtPriceX96) = StandardCurve.build(
            curveSpec(),
            basis,
            FAMILY_TOTAL_SUPPLY,
            FAMILY_TOTAL_SUPPLY,
            TICK_SPACING,
            tokenIsCurrency0
        );

        // THE EDGE PREDICATE, COMPUTED HERE. A pool whose PARENT is canonical index 0
        // is an edge pool and carries the protocol fee for the rest of its life; every other pool
        // never does. It is decided once, at registration, off the registry - not re-derived per
        // swap from a currency comparison that a later head could make ambiguous.
        bool isEdge = parent == edge;
        hook.registerPool(key, isEdge, initSqrtPriceX96, tradingStart, nominalEnd, scoreSlotS, !tokenIsCurrency0);
        poolManager.initialize(key, initSqrtPriceX96);
        locker.placeStandardCurve(key, ranges, tokenIsCurrency0);

        // the bond, in the edge currency: pulled from the registrant and handed straight to the
        // RoundManager, which escrows it until the round finalizes
        if (bondAmount != 0) {
            IERC20(GENESIS_TOKEN).safeTransferFrom(msg.sender, address(roundManager), bondAmount);
        }
        candidateId = roundManager.addCandidate(roundId, token, key, msg.sender, bondAmount);

        emit CandidateCreated(roundId, candidateId, token, key.toId(), initSqrtPriceX96, tokenIsCurrency0);
    }

    /// @notice The start round `parent`'s next candidates would open at if the round were
    /// priced right now: the start cap `startCap` in `parent` units after the clamps, the curve
    /// basis `basis` and the {StartPriced} `flags`. A view of the rule {registerCandidate}
    /// applies once per round; the cached figure for an open round is {roundCurveBasis}.
    function quoteStart(address parent) external view returns (uint256 startCap, uint256 basis, uint16 flags) {
        if (!roundManager.isCanonical(parent)) revert NotCanonical();
        StartQuote memory q = _quoteStart(roundManager.indexOf(parent), parent);
        return (q.cap, q.basis, q.flags);
    }

    /// @dev The curve basis of round `roundId`, whose candidates are quoted in `parent`: computed
    /// by the round's first registration ({_quoteStart}), cached in {roundCurveBasis}, and
    /// returned unchanged to every sibling after it, so all of them open at one price whatever
    /// the venue, the chain or the parent's supply does in between.
    function _curveBasis(uint256 roundId, address parent) internal returns (uint256 basis) {
        basis = roundCurveBasis[roundId];
        if (basis != 0) return basis;
        StartQuote memory q = _quoteStart(roundManager.roundInfo(roundId).parentIndex, parent);
        if (q.anchorIndex != 0 && q.anchorUnits != 0) {
            anchorUnits[q.anchorIndex] = q.anchorUnits;
            anchorDoll[q.anchorIndex] = q.doll;
            if (q.anchorIndex > anchorTop) anchorTop = q.anchorIndex;
            emit AnchorWritten(q.anchorIndex, q.anchorUnits, q.doll);
        }
        basis = q.basis;
        roundCurveBasis[roundId] = basis;
        roundStartFlags[roundId] = q.flags;
        emit StartPriced(roundId, parent, q.sqrtP, q.doll, q.cap, basis, q.flags);
    }

    /// @dev THE START RULE. `D` = E0 in $DOLL at the venue's averaged price (or the constant
    /// fallback), walked down the chain into parent units (`p` = the parent's canonical index),
    /// clamped to [Y, X] of the parent's supply, and turned into the curve basis whose first
    /// range starts exactly at that cap. Never zero: the lower clamp is at least one unit.
    function _quoteStart(uint256 p, address parent) internal view returns (StartQuote memory q) {
        uint256 status;
        uint256 streak;
        (q.sqrtP, status, streak) = _venueStart();
        q.flags = uint16(status << 8);
        if (streak != 0) q.flags |= LIMITER;
        // stale only, with a price: the oracle's averages up to its last sample (under 24 h old)
        bool staleUsed = status == ORACLE_STALE && q.sqrtP != 0;
        if (staleUsed) q.flags |= VENUE_STALE_USED;
        // slow-short only, with a price: the oracle's last ten clean minutes, max with slow so far
        bool fastOnly = status == ORACLE_SLOW_SHORT && q.sqrtP != 0;
        if (status != 0 && !staleUsed && !fastOnly) {
            q.flags |= VENUE_FALLBACK;
            q.sqrtP = 0;
            q.doll = START_FALLBACK_DOLL;
        } else {
            q.doll =
                FullMath.mulDiv(FullMath.mulDiv(START_FDV_WEI, q.sqrtP, FixedPoint96.Q96), q.sqrtP, FixedPoint96.Q96);
        }

        uint256 a = q.doll;
        if (a != 0 && p != 0) {
            uint16 walkFlags;
            (a, walkFlags, q.anchorIndex, q.anchorUnits) = _walkToParent(p, a);
            q.flags |= walkFlags;
        }

        uint256 supply = IERC20(parent).totalSupply();
        uint256 lo = FullMath.mulDiv(supply, START_MIN_PARENT_WAD, 1e18);
        uint256 hi = FullMath.mulDiv(supply, START_MAX_PARENT_BPS, BPS);
        if (a < lo) {
            a = lo;
            q.flags |= CLAMP_LO;
        } else if (a > hi) {
            a = hi;
            q.flags |= CLAMP_HI;
        }
        if (a == 0) a = 1;
        q.cap = a;
        q.basis = FullMath.mulDiv(a, 1e18, _curveSpec[0].fdvRatioLowerWad);
        if (q.basis == 0) q.basis = 1;
    }

    /// @dev The venue's start price and status, read with {ORACLE_GAS} per call and decoded by
    /// hand, so a reverting, gas-burning, code-less or malformed oracle is a status of
    /// {ORACLE_FAILED} and never a revert; so is an unbound one. `streak` is the oracle's current
    /// clamped streak, read through {IVenueOracle.latest} in the same guarded section: if either
    /// read fails, both do. A caller that leaves too little gas for a full read gets a revert
    /// ({OracleGasShort}), never a silent fallback.
    function _venueStart() internal view returns (uint160 sqrtP, uint256 status, uint256 streak) {
        address o = venueOracle;
        if (o == address(0)) return (0, ORACLE_FAILED, 0);
        (bool ok, uint256 w0, uint256 w1,) = _oracleCall(o, IVenueOracle.startPrice.selector, 64);
        if (!ok || w0 > type(uint160).max || w1 > type(uint8).max || (w1 == 0 && w0 == 0)) {
            return (0, ORACLE_FAILED, 0);
        }
        (bool ok2,,, uint256 s) = _oracleCall(o, IVenueOracle.latest.selector, 96);
        if (!ok2 || s > type(uint32).max) return (0, ORACLE_FAILED, 0);
        return (uint160(w0), w1, s);
    }

    /// @dev A gas-capped staticcall copying at most three return words (no return-data bomb);
    /// `ok` is false on a revert or when fewer than `minLen` bytes came back.
    function _oracleCall(address o, bytes4 selector, uint256 minLen)
        internal
        view
        returns (bool ok, uint256 w0, uint256 w1, uint256 w2)
    {
        uint256 g = ORACLE_GAS;
        // the EVM forwards at most 63/64 of what is left: below this the callee could get less
        // than `g`, run out, and turn a caller's gas limit into a chosen fallback
        if (gasleft() < g + g / 63 + ORACLE_CALL_OVERHEAD) revert OracleGasShort();
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(g, o, ptr, 4, ptr, 0x60)
            if lt(returndatasize(), minLen) { ok := 0 }
            w0 := mload(ptr)
            w1 := mload(add(ptr, 0x20))
            w2 := mload(add(ptr, 0x40))
        }
    }

    /// @dev `doll` $DOLL in units of canonical index `p`, walked link by link with
    /// {_startLinkPrice}. At most {START_WALK_MAX} links are walked: a deeper parent starts from
    /// the newest anchor (rescaled to `doll`); if that anchor is too shallow, the walk covers the
    /// next {START_WALK_MAX} links only to record a deeper anchor and the coin opens at the lower
    /// clamp ({ANCHOR_MISSING}). A young link returns 0 (the lower clamp, {LINK_YOUNG}); an
    /// amount that would overflow returns the maximum (the upper clamp).
    function _walkToParent(uint256 p, uint256 doll)
        internal
        view
        returns (uint256 amount, uint16 flags, uint256 anchorIndex, uint256 anchorAmount)
    {
        uint256 k = START_WALK_MAX;
        uint256 from;
        uint256 stop = p;
        // the index the NEXT round's walk will start from: it keeps that walk within the cap
        uint256 target = p + 1 > k ? p + 1 - k : 0;
        amount = doll;
        if (p > k) {
            flags = WALK_CAPPED;
            from = anchorTop;
            if (from != 0) amount = _scale(anchorUnits[from], doll, anchorDoll[from]);
            if (from + k < p) {
                flags |= ANCHOR_MISSING;
                stop = from + k;
                target = stop;
            }
        }
        address prev = roundManager.canonical(from);
        for (uint256 i = from + 1; i <= stop; ++i) {
            (uint160 price, bool parentIsCurrency0, address child) = _startLinkPrice(i, prev);
            if (price == 0) return (0, flags | LINK_YOUNG, anchorIndex, anchorAmount);
            amount = parentIsCurrency0
                ? _scale(_scale(amount, price, FixedPoint96.Q96), price, FixedPoint96.Q96)
                : _scale(_scale(amount, FixedPoint96.Q96, price), FixedPoint96.Q96, price);
            if (amount == type(uint256).max) return (amount, flags, anchorIndex, anchorAmount);
            if (i == target) (anchorIndex, anchorAmount) = (i, amount);
            prev = child;
        }
        if (flags & ANCHOR_MISSING != 0) amount = 0;
    }

    /// @dev Link `k`'s price for a start: the more conservative of its hook's fast (1800 s) and
    /// slow (7 d) averages - the one valuing the link LOWEST, which opens the coin dearer - with
    /// no spot read. Zero when either average covers less than {START_LINK_MIN_COVER_S}.
    /// `parent` is canonical `k - 1`; `child` (canonical `k`) is returned for the next step.
    function _startLinkPrice(uint256 k, address parent)
        internal
        view
        returns (uint160 price, bool parentIsCurrency0, address child)
    {
        PoolKey memory key = roundManager.poolKeyOf(k);
        parentIsCurrency0 = Currency.unwrap(key.currency0) == parent;
        child = Currency.unwrap(parentIsCurrency0 ? key.currency1 : key.currency0);
        if (address(key.hooks) == address(0)) return (0, parentIsCurrency0, child);
        FamilyHook h = FamilyHook(address(key.hooks));
        PoolId id = key.toId();
        (uint160 fast, uint32 fastCovered) = h.consult(id, LINK_FAST_WINDOW_S);
        (uint160 slow, uint32 slowCovered) = h.consultSlow(id, LINK_SLOW_WINDOW_S);
        uint32 minCover = START_LINK_MIN_COVER_S;
        if (fastCovered < minCover || slowCovered < minCover || fast == 0 || slow == 0) {
            return (0, parentIsCurrency0, child);
        }
        price = parentIsCurrency0 ? (fast > slow ? fast : slow) : (fast < slow ? fast : slow);
    }

    /// @dev `x * num / den`, saturating at the maximum instead of reverting on overflow.
    function _scale(uint256 x, uint256 num, uint256 den) internal pure returns (uint256) {
        if (x == type(uint256).max) return x;
        if (num > den && x > FullMath.mulDiv(type(uint256).max, den, num)) return type(uint256).max;
        return FullMath.mulDiv(x, num, den);
    }
}
