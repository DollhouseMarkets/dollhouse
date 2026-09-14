// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {FamilyToken, FAMILY_TOTAL_SUPPLY} from "./FamilyToken.sol";
import {DevVesting, DevVestingDeployer} from "./DevVesting.sol";
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
/// @notice Dollhouse: the only contract that may create a family pool. It deploys the token, pre-registers
/// the exact PoolKey and initial price with the hook, initializes the pool and has the Locker
/// place the standard curve — all in one transaction, so a launch can never be front-run into a
/// poisoned pool. There is no owner and no privileged caller: genesis goes to whoever calls
/// first, and it can only ever happen once; candidates go to whoever pays the bond during a
/// round's registration window.
///
/// @dev The factory deploys the Locker, the hook and the RoundManager itself, so that all four
/// addresses are mutually consistent without an initializer: the hook is CREATE2-deployed with a
/// salt mined off-chain (see `HookMiner`) against this factory's own predicted address, so the
/// hook address encodes its permission bits. The FeeVault, the BidDeployer and the FamilyRouter
/// are deployed AFTER the factory (they read its getters) and are passed in here as predicted
/// addresses.
contract FamilyFactory {
    /// @notice Basis-point denominator for {DEV_ALLOCATION_BPS}.
    uint256 public constant BPS = 10_000;
    /// @notice Tick spacing for every family pool.
    int24 public constant TICK_SPACING = 60;
    /// @notice Pool LP fee is zero: all fees are charged by the hook.
    uint24 public constant POOL_FEE = 0;

    IPoolManager public immutable poolManager;
    /// @notice The FeeVault, the BidDeployer and the canonical router. All three are deployed
    /// AFTER this factory (they read its getters), so their code cannot be checked here; {wire}
    /// does it once, lazily.
    address public immutable feeVault;
    /// @notice The keeper/bid half of the treasury: the only address {locker} accepts a bid
    /// from, and the address a LATER version hands this version's ancestor payouts to.
    address public immutable bidDeployer;
    address public immutable router;
    /// @notice The parent-supply stand-in the GENESIS curve is denominated in: genesis has no
    /// parent token, so the standard curve's parent-supply-relative FDV bands are scaled by this
    /// ETH amount instead. A deploy constant, immutable, and NOT caller-supplied (C2).
    uint256 public immutable GENESIS_UNIT;
    /// @dev The deploy-constant standard curve. Written once in the constructor; there is no
    /// setter, so it is immutable in everything but the storage layout (a dynamic array cannot
    /// be declared `immutable` in Solidity).
    CurveSegment[] private _curveSpec;
    Locker public immutable locker;
    FamilyHook public immutable hook;
    RoundManager public immutable roundManager;
    /// @notice The registry this deployment's RoundManager continues, or `address(0)` for a
    /// fresh trunk. A CONTINUATION stack has no genesis of its own: {createGenesis} is dead.
    address public immutable priorRegistry;
    /// @notice The helper that CREATEs the genesis {DevVesting} (see {DevVestingDeployer}).
    /// Deployed immediately BEFORE this factory, like {tokenImplementation}, so that its creation
    /// code stays out of this factory's own init code (EIP-3860).
    address public immutable devVestingDeployer;
    /// @notice The helper that CREATEs this version's {RoundManager}, for the same EIP-3860
    /// reason as {devVestingDeployer}.
    address public immutable roundManagerDeployer;
    /// @notice Share of the GENESIS supply (in basis points) minted to an immutable
    /// {DevVesting} contract instead of the curve: the disclosed developer allocation. Candidate
    /// tokens are unaffected - 100% of every candidate supply is locked liquidity.
    uint256 public immutable DEV_ALLOCATION_BPS;
    /// @notice Cliff of the developer allocation, in seconds after the genesis timestamp.
    uint64 public immutable VESTING_CLIFF_S;
    /// @notice Duration of the developer allocation's linear vesting, in seconds after the
    /// genesis timestamp.
    uint64 public immutable VESTING_DURATION_S;
    /// @notice The single FamilyToken implementation every family token is an EIP-1167 minimal
    /// proxy of. Deployed immediately BEFORE this factory, naming this factory as the only
    /// address that may {FamilyToken-initialize} a clone; the link is verified below. It is kept
    /// out of this constructor so that the factory's own init code stays well clear of the
    /// EIP-3860 limit.
    address public immutable tokenImplementation;

    /// @notice True once {wire} has verified that the FeeVault and the router have code.
    bool public wired;

    /// @dev The genesis token this factory created, or address(0). Read {genesisToken}, which
    /// also answers for a continuation stack (whose genesis lives in an earlier version).
    address internal _genesisToken;
    /// @notice Whoever created genesis. First caller wins; recorded for creator fee attribution.
    address public genesisCreator;
    /// @notice The {DevVesting} contract holding the genesis developer allocation, or
    /// address(0) when there is no allocation (or no genesis yet).
    address public devVesting;
    PoolId public genesisPoolId;

    event GenesisCreated(
        address indexed creator, address indexed token, PoolId indexed poolId, uint160 initSqrtPriceX96
    );
    event CandidateCreated(
        uint256 indexed roundId,
        uint256 indexed candidateId,
        address indexed token,
        PoolId poolId,
        uint160 initSqrtPriceX96,
        bool tokenIsCurrency0
    );

    /// @notice The genesis developer allocation and the immutable contract that holds it.
    event DevAllocationVested(address indexed vesting, uint256 amount, uint64 cliff, uint64 duration);

    error GenesisAlreadyCreated();
    /// @notice A continuation stack inherits the trunk's genesis; it can never create one (L7).
    error ContinuationHasGenesis();
    error WrongBond();
    error BadGenesisUnit();
    /// @notice The FeeVault, the BidDeployer or the router has no code: the stack was never
    /// completed (L7).
    error NotWired();
    /// @notice The REN-01 unlock guard does not read `false` against the deployed PoolManager
    /// outside an unlock: it is not bound to this manager's lock slot, and would fail open.
    error GuardNotBound();
    /// @notice The next canonical index would exceed the Fenwick sleeve's addressable range (L6).
    error ChainDepthLimit();
    /// @notice The supplied FamilyToken implementation does not name this factory (L7).
    error BadTokenImplementation();
    /// @notice The developer allocation is not a share of the supply, or its vesting schedule is
    /// impossible (duration below the cliff).
    error BadDevAllocation();

    /// @param deployer The {DevVestingDeployer} this factory CREATEs the vesting contract through.
    /// @param bps Share of the GENESIS supply vested to the developer, in basis points (300 = 3%).
    /// @param cliff Seconds after genesis before anything is releasable.
    /// @param duration Seconds after genesis at which the allocation is fully vested.
    struct DevAllocation {
        address deployer;
        uint256 bps;
        uint64 cliff;
        uint64 duration;
    }

    /// @notice How the RoundManager is built. `deployer` is the {RoundManagerDeployer} this
    /// factory CREATEs it through - kept out of this factory's own init code for EIP-3860,
    /// exactly like {DevVestingDeployer}. The rest is MECHANISM_v3's random end: the randomness
    /// source (or `address(0)` for none), the deterministic-fallback timeout, and the testnet
    /// schedule divisor.
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
        uint256 _genesisUnit,
        RoundManager.Bond memory _bond,
        uint256 _maxIndex,
        address _steward,
        uint64 _sunsetDelay,
        address _priorRegistry,
        CurveSegment[] memory _standardCurve,
        bytes32 _hookSalt,
        address _tokenImplementation,
        DevAllocation memory _devAllocation,
        RoundSetup memory _roundSetup
    ) {
        if (_genesisUnit == 0) revert BadGenesisUnit();
        if (_devAllocation.bps >= BPS || _devAllocation.duration < _devAllocation.cliff) revert BadDevAllocation();
        if (_devAllocation.bps != 0 && _devAllocation.duration == 0) revert BadDevAllocation();
        if (_devAllocation.bps != 0 && _devAllocation.deployer.code.length == 0) revert BadDevAllocation();
        devVestingDeployer = _devAllocation.deployer;
        DEV_ALLOCATION_BPS = _devAllocation.bps;
        VESTING_CLIFF_S = _devAllocation.cliff;
        VESTING_DURATION_S = _devAllocation.duration;
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
        GENESIS_UNIT = _genesisUnit;
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

    /// @notice One-time, permissionless, admin-free wiring check (L7): the FeeVault, the
    /// BidDeployer and the router are address PREDICTIONS at construction time, so their code
    /// can only be verified once they exist. Both launch entrypoints call this, so nothing can
    /// ever be launched into a half-deployed stack; after the first success it is a single warm
    /// SLOAD.
    ///
    /// @dev REVIEW 2: the REN-01 guard is bound to the deployed PoolManager here. `V4UnlockGuard`
    /// reads one transient slot of v4-core's `Lock` library through `exttload`; against a manager
    /// that does not implement `Exttload`, or whose lock slot differs, the read would either
    /// revert or answer `false` forever - and a guard that answers `false` forever is a guard
    /// that FAILS OPEN, silently. So the read is exercised once, at the moment the stack is
    /// wired: it must not revert, and outside an unlock (which this call is, by construction of
    /// the check below) it must answer `false`. The other half - that it answers `true` INSIDE
    /// an unlock - cannot be proved from here without opening one, and is proved at deploy time
    /// by `V4UnlockGuardProbe` (script/Deploy.s.sol) and on the live singleton by
    /// `test/fork/UnlockGuard.fork.t.sol`.
    function wire() public {
        if (wired) return;
        if (feeVault.code.length == 0 || router.code.length == 0) revert NotWired();
        if (bidDeployer.code.length == 0) revert NotWired();
        if (V4UnlockGuard.isInsideUnlock(address(poolManager))) revert GuardNotBound();
        wired = true;
    }

    /// @notice The deploy-constant standard curve every candidate is launched on.
    function curveSpec() public view returns (CurveSegment[] memory) {
        return _curveSpec;
    }

    /// @notice The starting FDV, in parent units, of a candidate launched against `parentSupply`.
    function startFdv(uint256 parentSupply) external view returns (uint256) {
        return StandardCurve.startFdv(_curveSpec, parentSupply);
    }

    /// @notice Create the one and only genesis link: a native-ETH-paired pool whose entire token
    /// supply is placed as permanently locked, single-sided curve liquidity.
    /// @dev C2: the curve and the initial price are NOT caller-supplied. They are derived here
    /// from the deploy-constant {curveSpec} and {GENESIS_UNIT} by exactly the same
    /// `StandardCurve.build` call {registerCandidate} makes, with GENESIS_UNIT standing in for
    /// the parent supply. Genesis is ETH-paired, so the token is always `currency1` and the pool
    /// opens at the top of the first range. Whoever calls first gets the creator attribution and
    /// nothing else: no caller can influence the price a single tick.
    function createGenesis(string calldata name, string calldata symbol, string calldata uri)
        external
        returns (address token, PoolKey memory key)
    {
        wire();
        // a continuation stack starts at the prior trunk's head: there is no second genesis,
        // ever, and the ETH edge stays the original genesis pool of the original version
        if (priorRegistry != address(0)) revert ContinuationHasGenesis();
        if (_genesisToken != address(0)) revert GenesisAlreadyCreated();

        token = Clones.clone(tokenImplementation);
        // the disclosed developer allocation: minted to an immutable, no-clawback vesting
        // contract deployed here, and therefore NOT on the curve. The rest of the supply is
        // locked liquidity exactly as before.
        uint256 devAmount = devAllocation();
        address vesting;
        if (devAmount != 0) {
            vesting = address(
                DevVestingDeployer(devVestingDeployer)
                    .deploy(
                        IERC20(token),
                        IFeeVault(feeVault).developer(),
                        uint64(block.timestamp),
                        VESTING_CLIFF_S,
                        VESTING_DURATION_S
                    )
            );
            devVesting = vesting;
        }
        FamilyToken(token).initialize(name, symbol, uri, address(locker), vesting, devAmount);

        // native ETH is address(0) and therefore always currency0
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        (CurveRange[] memory ranges, uint160 initSqrtPriceX96) = _genesisCurve();

        _genesisToken = token;
        genesisCreator = msg.sender;
        genesisPoolId = key.toId();

        // trading is open immediately for genesis; candidate pools get a synchronized start
        hook.registerPool(key, true, initSqrtPriceX96, 0, 0, true);
        poolManager.initialize(key, initSqrtPriceX96);
        locker.placeStandardCurve(key, ranges, false);
        roundManager.registerGenesis(token, key, msg.sender);

        if (devAmount != 0) emit DevAllocationVested(vesting, devAmount, VESTING_CLIFF_S, VESTING_DURATION_S);
        emit GenesisCreated(msg.sender, token, genesisPoolId, initSqrtPriceX96);
    }

    /// @notice The one and only genesis token of the trunk this factory is part of. For a
    /// continuation stack it is resolved through the registry chain (canonical index 0).
    function genesisToken() public view returns (address) {
        if (priorRegistry != address(0)) return roundManager.canonical(0);
        return _genesisToken;
    }

    /// @notice The genesis curve this factory will place, exposed so a deploy script or a UI can
    /// show it before genesis exists. Pure function of the deploy constants.
    function genesisCurve() external view returns (CurveRange[] memory ranges, uint160 initSqrtPriceX96) {
        return _genesisCurve();
    }

    /// @notice The genesis supply that actually goes on the curve: the total less the developer
    /// allocation. Candidates always sell their whole supply.
    function genesisTokensForSale() public view returns (uint256) {
        return FAMILY_TOTAL_SUPPLY - devAllocation();
    }

    /// @notice The genesis developer allocation, in tokens.
    function devAllocation() public view returns (uint256) {
        return (FAMILY_TOTAL_SUPPLY * DEV_ALLOCATION_BPS) / BPS;
    }

    /// @dev One copy of the genesis curve construction, shared by {createGenesis} and the
    /// {genesisCurve} preview so the factory's init code stays inside EIP-3860.
    function _genesisCurve() internal view returns (CurveRange[] memory ranges, uint160 initSqrtPriceX96) {
        return StandardCurve.build(
            curveSpec(), GENESIS_UNIT, FAMILY_TOTAL_SUPPLY, genesisTokensForSale(), TICK_SPACING, false
        );
    }

    /// @notice Register a succession candidate in the current round, opening the round if the
    /// chain is idle. The bond ({RoundManager.bondFor} of the index the round competes for) is
    /// escrowed in the RoundManager.
    ///
    /// The candidate is quoted in the CURRENT HEAD token, gets the identical {StandardCurve}
    /// starting at `START_RATIO` of the head's supply, and its pool is gated by the hook until
    /// the round's synchronized `tradingStart`. The child token's address may sort either side
    /// of its parent, so both curve orientations are supported.
    function registerCandidate(string calldata name, string calldata symbol, string calldata uri)
        external
        payable
        returns (address token, PoolKey memory key, uint256 candidateId)
    {
        wire();
        // L6: the ancestor sleeve is a Fenwick tree over a bounded index space. Refuse the
        // registration that could create an unaddressable generation rather than let the tree
        // revert later inside a swap and brick the whole chain.
        if (roundManager.headIndex() + 1 > FenwickRangeAdd.MAX_INDEX) revert ChainDepthLimit();
        // the round's own bond is fixed when it opens (F6: it doubles with depth), so the value
        // is checked against what the RoundManager actually wants, not a global constant
        (uint256 roundId, uint64 tradingStart, uint32 scoreSlotS, address parent, uint256 bondWei) =
            roundManager.openRoundIfIdle();
        if (msg.value != bondWei) revert WrongBond();

        token = Clones.clone(tokenImplementation);
        // candidates have no developer allocation: 100% of the supply is locked liquidity
        FamilyToken(token).initialize(name, symbol, uri, address(locker), address(0), 0);
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

        hook.registerPool(key, false, initSqrtPriceX96, tradingStart, scoreSlotS, !tokenIsCurrency0);
        poolManager.initialize(key, initSqrtPriceX96);
        locker.placeStandardCurve(key, ranges, tokenIsCurrency0);
        candidateId = roundManager.addCandidate{value: msg.value}(roundId, token, key, msg.sender);

        emit CandidateCreated(roundId, candidateId, token, key.toId(), initSqrtPriceX96, tokenIsCurrency0);
    }
}
