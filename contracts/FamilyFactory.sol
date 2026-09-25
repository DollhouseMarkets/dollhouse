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
        RoundSetup memory _roundSetup
    ) {
        // the edge currency must at least be a contract at construction time; its decimals and
        // supply are checked when it is adopted, which is the moment the chain starts
        if (_genesisToken == address(0) || _genesisToken.code.length == 0) revert BadGenesisToken();
        GENESIS_TOKEN = _genesisToken;
        DEPLOYER = msg.sender;
        if (FamilyToken(_tokenImplementation).factory() != address(this)) revert BadTokenImplementation();
        tokenImplementation = _tokenImplementation;
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

    /// @notice The deploy-constant standard curve every candidate is launched on.
    function curveSpec() public view returns (CurveSegment[] memory) {
        return _curveSpec;
    }

    /// @notice The starting FDV, in parent units, of a candidate launched against `parentSupply`.
    function startFdv(uint256 parentSupply) external view returns (uint256) {
        return StandardCurve.startFdv(_curveSpec, parentSupply);
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
    /// starting at `START_RATIO` of the head's supply, and its pool is gated by the hook until
    /// the round's synchronized `tradingStart`. The child token's address may sort either side
    /// of its parent, so both curve orientations are supported.
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
        (CurveRange[] memory ranges, uint160 initSqrtPriceX96) = StandardCurve.build(
            curveSpec(),
            IERC20(parent).totalSupply(),
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
}
