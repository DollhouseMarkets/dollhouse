// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary, equals} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IFamilyHook} from "./interfaces/IFamilyHook.sol";
import {IFeeVault} from "./interfaces/IFeeVault.sol";
import {IPriorRegistry} from "./interfaces/IPriorRegistry.sol";
import {IVersionFactory} from "./interfaces/IVersionFactory.sol";

/// @title FamilyHook
/// @notice The single hook behind every pool in the family. It is the protocol's only rule
/// engine: pools may only be created by the factory at the registered price, liquidity may only
/// be added by the Locker and may never be removed, donations are refused, and every swap pays
/// the parent-side hop fee plus (on the ETH-paired genesis pool) the 1% protocol fee.
///
/// @dev v4-periphery no longer ships a `BaseHook` (removed in the pinned commit), so `IHooks` is
/// implemented directly. Unused entrypoints revert with {HookNotImplemented}; they are also
/// unreachable because the corresponding permission bits are not encoded in this address.
///
/// Fee mechanics. The fee must land on the PARENT side of the swap (native ETH for genesis), but
/// v4 lets a hook take a delta on the specified currency only in `beforeSwap` and on the
/// unspecified currency only in `afterSwap`. Both paths are therefore implemented:
///   - parent is the SPECIFIED currency (exact-in buy paying parent, exact-out sell for parent):
///     charged in `beforeSwap` as a positive specified delta, so the fee is skimmed off the
///     amount that reaches the pool (exact-in) or added on top of it (exact-out).
///   - parent is the UNSPECIFIED currency (exact-in sell for parent, exact-out buy paying
///     parent): charged in `afterSwap` as a positive unspecified delta.
/// In both cases the trader pays `hopFeePpm` (plus the protocol fee and any snipe tax) as a
/// fraction of the TOTAL parent they part with (or, on a sell, of the gross parent the pool pays
/// out) - never of the pool's side alone: see the rate convention in {_collect}. The fee is
/// credited to the fee vault as an ERC-6909 claim on the PoolManager.
///
/// SCORE CONVENTION (L1/C1). `R` is the NET PARENT THAT STAYS IN THE POOL, which is exactly the
/// pool's own parent-side delta with the trader's sign flipped:
///
///     R += -parentDelta       where parentDelta is the SWAPPER's parent delta in `afterSwap`
///
/// v4 applies a `beforeSwap` return delta BEFORE the pool swap, so a parent-side fee skimmed in
/// `beforeSwap` is already excluded from `parentDelta`; a parent-side fee charged in `afterSwap`
/// is applied after `delta` is computed and so is likewise not in it. The score therefore never
/// needs a fee adjustment in either direction, and a heavily taxed buy inside the snipe window
/// scores the (small, positive) amount the pool actually absorbed - never a negative number.
contract FamilyHook is IHooks, IFamilyHook {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    using CurrencyLibrary for Currency;

    /// @notice Permission bits this hook's address must encode.
    uint160 public constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice Every fee rate in this hook is in PARTS PER MILLION (ppm), not basis points:
    /// the deploy-target hop fee is 7.5 bps, which integer bps cannot express (L8).
    uint256 internal constant PPM_DENOM = 1_000_000;
    /// @notice Largest hop fee this hook will accept: 100 bps.
    uint256 public constant MAX_HOP_FEE_PPM = 10_000;

    /// @notice Protocol fee on the ETH side of every genesis-pool swap: 1% (10,000 ppm).
    uint256 public constant PROTOCOL_FEE_PPM = 10_000;
    /// @dev Namespace for the transient per-currency snapshot of {IProtocolFees-protocolFeesAccrued}
    /// taken in `beforeSwap` (audit 9).
    bytes32 internal constant PRE_PROTOCOL_FEES_SLOT = keccak256("family.hook.preProtocolFees");
    /// @dev Transient slot for this transaction's answer to "is the sunset effective yet?":
    /// 0 = not asked, 1 = no, 2 = yes. The answer is a pure function of `block.timestamp` and
    /// the RoundManager's one-shot sunset switch, so it cannot change WITHIN a transaction; a
    /// multi-hop route from a third-party caller would otherwise re-pay the gas-capped
    /// {STATIC_GAS} probe once per leg, forever, because a pending sunset is deliberately not
    /// cacheable in storage (the steward may still cancel it).
    bytes32 internal constant SUNSET_PROBE_SLOT = keccak256("family.hook.sunsetProbe");

    /// @notice Snipe tax window: the first 3 seconds of a candidate's trading.
    uint64 public constant SNIPE_S = 3;
    /// @notice Snipe tax at `tradingStart` (99%) decaying linearly to {SNIPE_END_PPM} at
    /// `tradingStart + SNIPE_S`, then zero. Charged on the parent side, like every other fee.
    uint256 public constant SNIPE_START_PPM = 990_000;
    uint256 public constant SNIPE_END_PPM = 10_000;

    /// @notice An exact-output swap paying parent cannot be priced when the parent-side rates
    /// sum to 100% or more: the gross-up `poolCost / (1 - rate)` diverges. Only reachable with a
    /// hop fee at the {MAX_HOP_FEE_PPM} ceiling during the first instant of the snipe window.
    error SnipeExactOutputTooLarge();

    /// @notice Gas budget for ONE leg of the successor-router resolution (F2). Every leg is an
    /// unauthenticated staticcall into an address the steward named; without a cap, a successor
    /// whose `factory()` burns gas would make every swap of every pool of this version revert
    /// under the 63/64 rule, forever and with no way back.
    uint256 internal constant STATIC_GAS = 30_000;

    /// @notice Number of FAST TWAP observations kept per pool, and the minimum spacing between
    /// them.
    /// @dev 32 x 120 s covers 3840 s, so the keeper's 1800 s window is fully coverable with room
    /// to spare (M2); {consult} reports how much of the window it actually covered.
    uint256 public constant OBS_CARDINALITY = 32;
    uint64 public constant OBS_MIN_SPACING = 120;

    /// @notice Number of SLOW TWAP observations kept per pool, and the minimum spacing between
    /// them: 64 x 3 h covers 8 days, so a 7-day average is fully coverable (F4).
    /// @dev The slow ring shares the SAME cumulative accumulator as the fast one - it is only
    /// sampled more rarely - so it costs one extra SSTORE every three hours per pool and gives
    /// the keeper path a price a 30-minute pump cannot move. {consultSlow} reports its coverage
    /// exactly as {consult} does.
    uint256 public constant SLOW_OBS_CARDINALITY = 64;
    uint64 public constant SLOW_OBS_MIN_SPACING = 3 hours;

    /// @notice THE SCORE RING (MECHANISM_v3 sec.3): {SCORE_SLOTS} checkpoints, one per
    /// {SCORE_SLOT_S}-second slot, covering the {SCORE_RING_S} seconds a random end can fall in.
    /// @dev A slot is written at most once - by the FIRST swap in it - and holds the state as of
    /// the moment BEFORE that swap. So the ring answers "what was the accumulator at `t`?" for
    /// every `t` in the last three minutes, exactly, without an entry per swap: `R` is constant
    /// between swaps, so a slot with no swap in it needs no entry at all. Writing the PRE-swap
    /// state (rather than the post-swap one) is the conservative choice at slot resolution: a
    /// second swap inside the same 5-second slot as `T_end` is never counted toward the score,
    /// where the other convention would count a swap up to 5 seconds AFTER the true end.
    uint256 public constant SCORE_SLOTS = 36;
    uint64 public constant SCORE_SLOT_S = 5;
    uint64 public constant SCORE_RING_S = 36 * 5;

    /// @notice THE COARSE SCORE RING: {SCORE_COARSE_SLOTS} checkpoints at the PER-POOL spacing
    /// `scoreSlotS`, which the launching round sizes so that the ring reaches back past its
    /// closing window `W` plus the settlement tail. It is what resolves the FAR edge of a round's
    /// score, and the pool's trailing average forever after.
    uint256 public constant SCORE_COARSE_SLOTS = 64;
    /// @notice The coarse spacing a pool registered with no schedule of its own (genesis) gets:
    /// 63 x 180 s reaches back 3.1 hours, comfortably past the closing window plus the whole
    /// settlement tail a round can take (`RoundManager.scoreSlotFor`).
    uint32 public constant DEFAULT_SCORE_SLOT_S = 180;

    IPoolManager public immutable poolManager;
    address public immutable factory;
    address public immutable locker;
    address public immutable feeVault;
    address public immutable router;
    /// @notice Per-hop pool fee in PARTS PER MILLION, charged on the parent side of every family
    /// swap (7,500 ppm would be 75 bps; the deploy target is 750 ppm = 7.5 bps).
    uint256 public immutable hopFeePpm;

    /// @notice This version's RoundManager, resolved lazily from the factory (the factory deploys
    /// the hook BEFORE the RoundManager, so it cannot be immutable wiring). Write-once, no setter.
    address public roundManager;
    /// @notice The SUCCESSOR version's router, resolved lazily once this version's RoundManager is
    /// sunset-effective, and cached forever after: the successor and its router are both immutable
    /// once set, so the resolved value can never change. Write-once, no setter.
    ///
    /// @dev The sunset HANDOVER (README "Upgrade model"): after the sunset takes effect the live
    /// trunk is the successor's, and its router is the one that routes traders through THIS
    /// version's pools - including the genesis pool, which no continuation stack has one of. From
    /// then on this hook trusts that router's `hookData` for attribution exactly as it trusts its
    /// own, so the 1% ETH edge can still be credited to the terminal token's creator. It is not a
    /// new privilege: the successor is the one the steward already named in the one-shot sunset.
    address public successorRouter;
    /// @notice NEGATIVE RESOLUTION CACHE (F2): set once the handover has taken effect and the
    /// successor did NOT resolve to a router. The successor is immutable, so the answer can never
    /// change; without this flag every swap carrying hookData from a non-canonical caller would
    /// re-pay the whole {STATIC_GAS} resolution chain forever. Attribution then simply stays with
    /// this version's own router.
    bool public successorUnresolvable;

    mapping(PoolId => RegisteredPool) public registeredPools;
    /// @notice Per-pool ring of cumulative-price snapshots, and how many have ever been written.
    mapping(PoolId => mapping(uint256 => Observation)) internal observations;
    mapping(PoolId => uint256) internal obsCount;
    /// @notice The same, sampled at {SLOW_OBS_MIN_SPACING} for the long-horizon average (F4).
    mapping(PoolId => mapping(uint256 => Observation)) internal slowObservations;
    mapping(PoolId => uint256) internal slowObsCount;
    /// @notice The 3-minute score ring the random end is reconstructed from, and the coarse ring
    /// that reaches back over the round's whole closing window.
    mapping(PoolId => mapping(uint256 => ScoreCheckpoint)) internal scoreRing;
    mapping(PoolId => mapping(uint256 => ScoreCheckpoint)) internal coarseRing;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address _factory,
        address _locker,
        address _feeVault,
        address _router,
        uint256 _hopFeePpm
    ) {
        // the address must encode exactly the permissions above (CREATE2-mined, see HookMiner)
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != HOOK_FLAGS) revert InvalidHookAddress();
        // L9: a hop fee above 100 bps is refused outright, so no deploy can misprice the chain
        if (_hopFeePpm > MAX_HOP_FEE_PPM) revert HopFeeTooHigh();
        poolManager = _poolManager;
        factory = _factory;
        locker = _locker;
        feeVault = _feeVault;
        router = _router;
        hopFeePpm = _hopFeePpm;
    }

    // -------------------------------------------------------------------------------------
    // registry
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IFamilyHook
    function registerPool(
        PoolKey calldata key,
        bool isGenesis,
        uint160 initSqrtPriceX96,
        uint64 tradingStart,
        uint32 scoreSlotS,
        bool parentIsCurrency0
    ) external {
        if (msg.sender != factory) revert NotFactory();
        // F-1: the genesis pool has NO snipe window, and the whole mutual exclusion between the
        // 1% protocol fee and the 99% opening snipe tax rests on it. The factory already only
        // ever passes zero here; the hook guarantees it too, so a future caller cannot register a
        // genesis pool that would carry both rates and revert every parent-paying exact-output
        // swap in its first seconds.
        if (isGenesis && tradingStart != 0) revert GenesisHasNoSnipeWindow();
        PoolId id = key.toId();
        RegisteredPool storage p = registeredPools[id];
        if (p.registered) revert PoolAlreadyRegistered();
        p.registered = true;
        p.isGenesis = isGenesis;
        p.parentIsCurrency0 = parentIsCurrency0;
        p.initSqrtPriceX96 = initSqrtPriceX96;
        p.tradingStart = tradingStart;
        p.scoreSlotS = scoreSlotS < SCORE_SLOT_S ? DEFAULT_SCORE_SLOT_S : scoreSlotS;
        // scored pools accumulate from their OWN start, not from their first swap
        p.tLast = tradingStart;
        emit PoolRegistered(id, isGenesis, initSqrtPriceX96, tradingStart);
    }

    /// @inheritdoc IFamilyHook
    function poolInfo(PoolId id) external view returns (RegisteredPool memory) {
        return registeredPools[id];
    }

    /// @inheritdoc IFamilyHook
    function scoreState(PoolId id) external view returns (int256 acc, int128 R, uint64 tLast) {
        RegisteredPool storage p = registeredPools[id];
        return (p.acc, p.R, p.tLast);
    }

    // -------------------------------------------------------------------------------------
    // hook entrypoints
    // -------------------------------------------------------------------------------------

    /// @notice Only factory-registered keys, and only at the exact registered price.
    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        RegisteredPool storage p = registeredPools[key.toId()];
        if (!p.registered) revert PoolNotRegistered();
        if (sqrtPriceX96 != p.initSqrtPriceX96) revert WrongInitialPrice();
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Only the Locker may ever add liquidity to a family pool.
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (!registeredPools[key.toId()].registered) revert PoolNotRegistered();
        if (sender != locker) revert OnlyLocker();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Liquidity is permanently locked: removal is impossible for everyone, forever.
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert LiquidityIsLocked();
    }

    /// @notice Donations are refused (they would credit value to positions outside the curve).
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert DonationDisabled();
    }

    /// @notice Gates trading start and charges the parent-side fee when the parent currency is
    /// the swap's specified currency.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        RegisteredPool storage p = registeredPools[id];
        if (!p.registered) revert PoolNotRegistered();
        if (p.tradingStart != 0 && block.timestamp < p.tradingStart) revert TradingNotStarted();

        // the oracle accumulates the price that stood BEFORE this swap, for the whole interval
        // since the previous observation: a single swap can never rewrite elapsed time at its
        // own manipulated price
        (uint160 sqrtPriceBefore,, uint24 poolProtocolFee,) = poolManager.getSlot0(id);
        _observe(id, p, sqrtPriceBefore);

        Currency parent = _parentCurrency(key, p);
        // AUDIT 9: if Uniswap's own protocol fee is ever switched on for this pool by the v4
        // fee controller, part of the parent a trader pays in is taken by the PoolManager and
        // never becomes pool liquidity - but the swapper delta `afterSwap` reads still counts it,
        // so it would inflate the absorption score a candidate is judged on. Snapshot what the
        // PoolManager has accrued in the parent currency BEFORE the swap, in transient storage
        // (one `tstore`, cleared automatically at the end of the transaction), and subtract the
        // increase in `afterSwap`.
        //
        // The snapshot is only taken when this pool actually HAS a protocol fee set (both
        // directions are packed into the `protocolFee` word `getSlot0` already returned). With
        // no fee set the PoolManager cannot take any, so the pair of `protocolFeesAccrued`
        // reads - one here and one in {_protocolFeeTaken} - is pure cost on every swap of every
        // pool; leaving the transient slot unwritten makes {_protocolFeeTaken} return exactly
        // the same zero.
        if (poolProtocolFee != 0) _setPreProtocolFees(parent, poolManager.protocolFeesAccrued(parent));
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency specified = specifiedIsCurrency0 ? key.currency0 : key.currency1;
        if (!equals(specified, parent)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool exactOutput = params.amountSpecified > 0;
        uint256 parentAmount = exactOutput ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);
        // parent is the SPECIFIED currency. On an exact-INPUT buy `parentAmount` is already the
        // trader's gross parent and the rates apply to it directly. On an exact-OUTPUT sell it is
        // the parent the trader RECEIVES, i.e. the pool's payout net of the fee, so it is grossed
        // up exactly like the exact-output buy in {afterSwap} (F9): the pool pays
        // `parentAmount / (1 - rate)` and the fee is `rate` of that gross, not `rate/(1 + rate)`.
        uint256 total = _collect(id, p, parent, parentAmount, exactOutput, sender, hookData);
        // exact-in: the fee is skimmed OFF the input by this return delta, so the pool only ever
        // sees the NET parent. v4 applies the beforeSwap delta before the pool swap, so the
        // parent delta `afterSwap` reads is already net of it — no second adjustment is needed.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(total.toInt128(), 0), 0);
    }

    /// @notice Charges the parent-side fee when the parent currency is the unspecified currency,
    /// then updates the score and price accumulators.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        RegisteredPool storage p = registeredPools[id];
        if (!p.registered) revert PoolNotRegistered();

        Currency parent = _parentCurrency(key, p);
        bool parentIsCurrency0 = p.parentIsCurrency0;
        // the swapper's parent-side delta; negative means the trader paid parent into the pool
        int128 parentDelta = parentIsCurrency0 ? delta.amount0() : delta.amount1();

        int128 feeDelta;
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        if (specifiedIsCurrency0 != parentIsCurrency0) {
            // parent is the unspecified currency: charge here. The pool-side amount is exactly
            // `delta`, so no score adjustment is needed in this branch.
            uint256 parentAmount = uint256(uint128(parentDelta < 0 ? -parentDelta : parentDelta));
            // `parentDelta < 0` is the exact-OUTPUT buy: `delta` is the pool's cost and the fee
            // is charged ON TOP of it, so it is grossed up to stay a fraction of the total paid.
            // `parentDelta > 0` is the exact-input sell: the trader receives that parent and the
            // fee is a fraction of it directly.
            feeDelta = _collect(id, p, parent, parentAmount, parentDelta < 0, sender, hookData).toInt128();
        }

        // Score convention: the NET parent that stays in the pool, i.e. exactly the pool's own
        // parent delta with the trader's sign flipped. `delta` is the swapper delta AFTER v4 has
        // applied the beforeSwap return delta, so a parent-side hop fee skimmed in `beforeSwap`
        // is already excluded here; subtracting it again would double-count it (and could make
        // `R` negative on a heavily taxed snipe-window buy).
        //
        // AUDIT 9: what Uniswap's OWN protocol fee took out of this swap never reached the pool
        // either, so it is removed from the scored input. It is zero unless the v4 fee controller
        // has switched a protocol fee on for this pool.
        int256 scored = -int256(parentDelta) - int256(_protocolFeeTaken(parent));
        _updateScore(id, p, scored);

        return (IHooks.afterSwap.selector, feeDelta);
    }

    // -------------------------------------------------------------------------------------
    // fee accounting
    // -------------------------------------------------------------------------------------

    /// @dev Computes and credits the hop fee (plus the protocol fee on the genesis pool) on
    /// `parentAmount` of `parent`. The fee is minted to the fee vault as an ERC-6909 claim on
    /// the PoolManager rather than transferred with `take`, because for input-side fees the
    /// PoolManager does not yet hold the trader's funds (they are settled at the end of the
    /// unlock) and `take` would revert. The vault redeems claims with `burn` + `take`.
    function _collect(
        PoolId id,
        RegisteredPool storage p,
        Currency parent,
        uint256 parentAmount,
        bool onPoolAmount,
        address sender,
        bytes calldata hookData
    ) internal returns (uint256 total) {
        uint256 snipePpm = _snipeTaxPpm(p.tradingStart);
        uint256 protocolPpm = p.isGenesis ? PROTOCOL_FEE_PPM : 0;

        // RATE CONVENTION. Every ppm rate here is a fraction of the TRADER'S TOTAL parent-side
        // amount, in both swap modes. When `parentAmount` is already that total (exact-input
        // paying parent, or the parent the trader receives) the rates apply directly. When it is
        // the POOL's side of an exact-output swap that PAYS parent, the fees are added on top of
        // the pool cost, so the basis must be grossed up first:
        //
        //     basis = poolCost / (1 - rate)          fee = poolCost * rate / (1 - rate)
        //
        // Charging `poolCost * rate` instead would make the fee only `rate / (1 + rate)` of what
        // the trader actually pays - at the 99% snipe start that is 49.7%, not 99%.
        uint256 basis = parentAmount;
        if (onPoolAmount) {
            uint256 totalPpm = hopFeePpm + protocolPpm + snipePpm;
            if (totalPpm != 0) {
                // 99% snipe + 1% protocol + up to 100 bps hop can reach 100%, where the gross-up
                // has no finite answer: such a swap is refused rather than silently underpriced.
                if (totalPpm >= PPM_DENOM) revert SnipeExactOutputTooLarge();
                basis = (parentAmount * PPM_DENOM) / (PPM_DENOM - totalPpm);
            }
        }

        uint256 hopFee = (basis * hopFeePpm) / PPM_DENOM;
        uint256 protocolFee = (basis * protocolPpm) / PPM_DENOM;
        uint256 snipeFee = snipePpm == 0 ? 0 : (basis * snipePpm) / PPM_DENOM;
        if (snipeFee != 0) emit SnipeTaxed(id, sender, snipePpm, snipeFee);

        total = hopFee + protocolFee + snipeFee;
        if (total == 0) return 0;
        poolManager.mint(feeVault, parent.toId(), total);

        (uint256 terminalIndex, bool attributed) = _attribution(sender, hookData);
        emit FeeAccrued(id, parent, hopFee, protocolFee, sender, attributed ? terminalIndex : 0);
        // the snipe tax is protocol-owned reinforcement for this pool's parent, like the hop fee
        IFeeVault(feeVault)
            .accrue(
                parent,
                p.isGenesis ? address(0) : Currency.unwrap(parent),
                hopFee + snipeFee,
                protocolFee,
                terminalIndex,
                attributed
            );
    }

    /// @notice Linear snipe tax over the first {SNIPE_S} seconds of a candidate pool's trading:
    /// {SNIPE_START_PPM} at `tradingStart`, {SNIPE_END_PPM} at the end of the window, then zero.
    /// Genesis (`tradingStart == 0`) is never sniped.
    function _snipeTaxPpm(uint64 tradingStart) internal view returns (uint256) {
        if (tradingStart == 0 || block.timestamp < tradingStart) return 0;
        uint256 dt = block.timestamp - tradingStart;
        if (dt >= SNIPE_S) return 0;
        return SNIPE_END_PPM + ((SNIPE_START_PPM - SNIPE_END_PPM) * (SNIPE_S - dt)) / SNIPE_S;
    }

    /// @dev hookData is only trusted when the caller is this version's canonical router, or -
    /// after the sunset has taken effect - the successor version's router; otherwise the fee is
    /// unattributed and flows to the flywheel. The VALUE is interpreted by whichever FeeVault
    /// finally books the fee, which after the handover is the successor's, resolving it against
    /// its own registry (a v1-era index still resolves there, by delegation).
    function _attribution(address sender, bytes calldata hookData)
        internal
        returns (uint256 terminalIndex, bool attributed)
    {
        if (hookData.length < 32) return (0, false);
        if (sender != router && sender != _successorRouter()) return (0, false);
        return (abi.decode(hookData, (uint256)), true);
    }

    /// @dev The successor version's router, or `address(0)` while this version is not yet
    /// sunset-effective (or the successor does not answer the handover ABI). Every leg of the
    /// resolution is a CHECKED static call: a successor that is not a RoundManager - the sunset
    /// switch only requires code at the address - must leave swaps working, unattributed.
    function _successorRouter() internal returns (address) {
        address cached = successorRouter;
        if (cached != address(0)) return cached;
        if (successorUnresolvable) return address(0);

        address rm = roundManager;
        if (rm == address(0)) {
            rm = _staticAddress(factory, abi.encodeCall(IVersionFactory.roundManager, ()));
            if (rm == address(0)) return address(0);
            roundManager = rm;
        }
        // before the handover takes effect there is nothing to resolve and nothing to cache: the
        // question is simply not answerable yet, and the steward may still cancel the sunset.
        if (!_sunsetEffective(rm)) return address(0);
        address resolved = _resolveSuccessorRouter(rm);
        if (resolved == address(0)) {
            // the sunset IS effective and the successor did not answer: cache the negative
            successorUnresolvable = true;
            emit SuccessorRouterUnresolvable();
            return address(0);
        }
        successorRouter = resolved;
        emit SuccessorRouterResolved(resolved);
        return resolved;
    }

    /// @dev {IPriorRegistry.isSunsetEffective} on `rm`, asked at most ONCE per transaction.
    function _sunsetEffective(address rm) internal returns (bool) {
        bytes32 slot = SUNSET_PROBE_SLOT;
        uint256 cached;
        assembly ("memory-safe") {
            cached := tload(slot)
        }
        if (cached != 0) return cached == 2;
        bool answer = _staticBool(rm, abi.encodeCall(IPriorRegistry.isSunsetEffective, ()));
        assembly ("memory-safe") {
            tstore(slot, add(1, answer))
        }
        return answer;
    }

    /// @dev The three remaining legs of the resolution, each gas-capped and checked.
    function _resolveSuccessorRouter(address rm) internal view returns (address) {
        address successor = _staticAddress(rm, abi.encodeCall(IPriorRegistry.successor, ()));
        if (successor == address(0)) return address(0);
        address successorFactory = _staticAddress(successor, abi.encodeCall(IPriorRegistry.factory, ()));
        if (successorFactory == address(0)) return address(0);
        return _staticAddress(successorFactory, abi.encodeCall(IVersionFactory.router, ()));
    }

    /// @dev A GAS-CAPPED static call that may fail or answer nonsense: `address(0)` means "no
    /// answer". The cap (F2) is what makes a hostile or broken successor a non-event for traders.
    ///
    /// AUDIT 7A: the word is read RAW and validated, never `abi.decode`d. A successor that
    /// returns a well-formed 32-byte word with dirty upper bits (`0xdead...` in the top 96) makes
    /// `abi.decode(ret, (address))` REVERT - inside a swap, which turned every attributed
    /// third-party route into a failing transaction. A dirty word is simply "no answer" here, and
    /// the caller caches that negative exactly as it caches a timeout.
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

    /// @dev As {_staticAddress}: a bool word that is anything other than 0 or 1 is nonsense, and
    /// `abi.decode(ret, (bool))` would revert on it (audit 7A). Anything non-zero and clean is
    /// true; anything else is "no answer", which is `false` for every caller here.
    function _staticBool(address target, bytes memory data) internal view returns (bool) {
        (bool ok, bytes memory ret) = target.staticcall{gas: STATIC_GAS}(data);
        if (!ok || ret.length != 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 32))
        }
        return word == 1;
    }

    /// @dev Transient slot holding what the PoolManager had accrued in `currency` before the
    /// swap in flight (audit 9). Transient storage, so it costs 100 gas and cannot leak across
    /// transactions; keyed by currency so that a multi-hop route through several pools of the
    /// same parent still reads its own leg's snapshot.
    function _preProtocolFeesSlot(Currency currency) internal pure returns (bytes32 slot) {
        return keccak256(abi.encode(PRE_PROTOCOL_FEES_SLOT, currency));
    }

    function _setPreProtocolFees(Currency currency, uint256 value) internal {
        bytes32 slot = _preProtocolFeesSlot(currency);
        assembly ("memory-safe") {
            tstore(slot, add(value, 1)) // +1 so that "never written" is distinguishable from zero
        }
    }

    /// @dev How much of the parent side of the swap in flight Uniswap's own protocol fee took
    /// (audit 9). Zero when no snapshot was taken (the parent was not the fee currency on this
    /// leg) or when no protocol fee is switched on.
    function _protocolFeeTaken(Currency currency) internal view returns (uint256 taken) {
        bytes32 slot = _preProtocolFeesSlot(currency);
        uint256 stored;
        assembly ("memory-safe") {
            stored := tload(slot)
        }
        if (stored == 0) return 0;
        uint256 nowAccrued = poolManager.protocolFeesAccrued(currency);
        uint256 before = stored - 1;
        return nowAccrued > before ? nowAccrued - before : 0;
    }

    /// @dev The parent currency of a family pool is its non-token side, as recorded by the
    /// factory at registration: native ETH (always `currency0`) for genesis, and the parent
    /// TOKEN — which may sort either side of the child — for a candidate pool.
    function _parentCurrency(PoolKey calldata key, RegisteredPool storage p) internal view returns (Currency) {
        return p.parentIsCurrency0 ? key.currency0 : key.currency1;
    }

    // -------------------------------------------------------------------------------------
    // score / oracle accumulators
    // -------------------------------------------------------------------------------------

    /// @notice Time-weighted net parent absorption: `acc += R * dt; R += netParentIn`. It RUNS
    /// FOREVER (MECHANISM_v3 sec.1): there is no freeze at `T_end` any more, because the same
    /// accumulator is the public measure of a coin's support for the rest of the chain's life.
    /// What a post-bell dump can no longer move is the ROUND's score,
    /// and that is now enforced by reconstruction rather than by sealing: the round is evaluated
    /// at `T_end` out of the checkpoint ring written below, and `T_end` is not knowable until the
    /// randomness lands.
    function _updateScore(PoolId id, RegisteredPool storage p, int256 netParentIn) internal {
        uint64 nowTs = uint64(block.timestamp);
        _checkpoint(scoreRing[id], SCORE_SLOTS, SCORE_SLOT_S, p, nowTs);
        _checkpoint(coarseRing[id], SCORE_COARSE_SLOTS, p.scoreSlotS, p, nowTs);
        if (p.tLast != 0) p.acc += int256(p.R) * int256(uint256(nowTs - p.tLast));
        p.tLast = nowTs;
        p.R += netParentIn.toInt128();
        emit ScoreUpdated(id, p.acc, p.R, nowTs);
    }

    /// @dev Write the PRE-swap accumulator state into this swap's slot of `ring`, if that slot
    /// has not been written yet. `tSwap` tags the slot, so the second and later swaps of a slot
    /// cost one warm SLOAD and nothing else.
    function _checkpoint(
        mapping(uint256 => ScoreCheckpoint) storage ring,
        uint256 cardinality,
        uint64 slotS,
        RegisteredPool storage p,
        uint64 nowTs
    ) internal {
        uint64 slot = nowTs / slotS;
        ScoreCheckpoint storage cp = ring[slot % cardinality];
        if (cp.tSwap / slotS == slot) return;
        cp.tSwap = nowTs;
        cp.tState = p.tLast;
        cp.R = p.R;
        cp.acc = p.acc;
    }

    /// @inheritdoc IFamilyHook
    function averageOver(PoolId id, uint64 tStart, uint64 tEnd) external view returns (int256 avg, uint64 tLastBefore) {
        RegisteredPool storage p = registeredPools[id];
        if (!p.registered) revert PoolNotRegistered();
        // THE CLOSING WINDOW is the same for every candidate of a round; the only thing that can
        // shorten it is a pool that did not exist for all of it, and late entry is bounded so
        // that a late entrant's pool always opens BEFORE the closing window starts
        uint64 start = tStart < p.tradingStart ? p.tradingStart : tStart;
        if (tEnd <= start) revert BadScoreWindow();
        int256 accEnd;
        (accEnd, tLastBefore) = _accumulatorAt(id, p, tEnd);
        (int256 accStart,) = _accumulatorAt(id, p, start);
        avg = (accEnd - accStart) / int256(uint256(tEnd - start));
    }

    /// @dev `acc(t)`, and the last score update at or before it. Two cases, and only two: either
    /// nothing has been swapped since `t` (the live state is already the answer), or a ring holds
    /// the checkpoint whose interval `[tState, tSwap)` brackets `t`, which is the one with the
    /// SMALLEST `tSwap` strictly after it. The fast ring is tried first because it resolves the
    /// `T_end` edge to five seconds; the coarse ring reaches the far edge of the window.
    function _accumulatorAt(PoolId id, RegisteredPool storage p, uint64 t)
        internal
        view
        returns (int256 accAt, uint64 tLastBefore)
    {
        if (p.tLast <= t) return (p.acc + int256(p.R) * int256(uint256(t - p.tLast)), p.tLast);
        (bool found, ScoreCheckpoint memory cp) = _bracket(scoreRing[id], SCORE_SLOTS, t);
        if (!found) (found, cp) = _bracket(coarseRing[id], SCORE_COARSE_SLOTS, t);
        if (!found) revert CheckpointUnavailable();
        return (cp.acc + int256(cp.R) * int256(uint256(t - cp.tState)), cp.tState);
    }

    /// @dev The checkpoint of `ring` whose validity interval `[tState, tSwap)` contains `t`.
    function _bracket(mapping(uint256 => ScoreCheckpoint) storage ring, uint256 cardinality, uint64 t)
        internal
        view
        returns (bool found, ScoreCheckpoint memory best)
    {
        uint64 bestSwap = type(uint64).max;
        for (uint256 i = 0; i < cardinality; i++) {
            ScoreCheckpoint memory cp = ring[i];
            if (cp.tSwap > t && cp.tSwap < bestSwap && cp.tState <= t) {
                best = cp;
                bestSwap = cp.tSwap;
            }
        }
        found = bestSwap != type(uint64).max;
    }

    /// @dev The OLDEST checkpoint still in `ring`: the fallback reference for a trailing average
    /// over a window longer than the pool's recorded history.
    function _oldest(mapping(uint256 => ScoreCheckpoint) storage ring, uint256 cardinality)
        internal
        view
        returns (bool found, ScoreCheckpoint memory best)
    {
        uint64 bestState = type(uint64).max;
        for (uint256 i = 0; i < cardinality; i++) {
            ScoreCheckpoint memory cp = ring[i];
            if (cp.tSwap != 0 && cp.tState < bestState) {
                best = cp;
                bestState = cp.tState;
            }
        }
        found = bestState != type(uint64).max;
    }

    /// @inheritdoc IFamilyHook
    function trailingAverage(PoolId id, uint32 window) external view returns (int256 avg, uint32 coveredSeconds) {
        RegisteredPool storage p = registeredPools[id];
        if (!p.registered) revert PoolNotRegistered();
        uint64 nowTs = uint64(block.timestamp);
        int256 accNow = p.acc + int256(p.R) * int256(uint256(nowTs - p.tLast));

        uint64 from = nowTs > window ? nowTs - window : 0;
        if (from < p.tradingStart) from = p.tradingStart;
        int256 accFrom;
        if (p.tLast <= from) {
            accFrom = p.acc + int256(p.R) * int256(uint256(from - p.tLast));
        } else {
            (bool found, ScoreCheckpoint memory cp) = _bracket(coarseRing[id], SCORE_COARSE_SLOTS, from);
            if (!found) (found, cp) = _oldest(coarseRing[id], SCORE_COARSE_SLOTS);
            if (!found) return (0, 0);
            // a pool whose recorded history is shorter than the window is averaged over what it
            // has, and the caller is told how much that was - exactly as {consult} does
            if (cp.tState > from) from = cp.tState;
            accFrom = cp.acc + int256(cp.R) * int256(uint256(from - cp.tState));
        }
        if (nowTs <= from) return (0, 0);
        coveredSeconds = uint32(nowTs - from);
        avg = (accNow - accFrom) / int256(uint256(coveredSeconds));
    }

    /// @inheritdoc IFamilyHook
    function scoreCheckpoint(PoolId id, uint256 index) external view returns (ScoreCheckpoint memory) {
        return scoreRing[id][index % SCORE_SLOTS];
    }

    /// @inheritdoc IFamilyHook
    function coarseCheckpoint(PoolId id, uint256 index) external view returns (ScoreCheckpoint memory) {
        return coarseRing[id][index % SCORE_COARSE_SLOTS];
    }

    /// @notice Cumulative price observation used by the keeper TWAPs: `cumSqrtP += sqrtP * dt`,
    /// snapshotted into TWO rings off the one accumulator - the fast ring ({OBS_CARDINALITY}
    /// entries, {OBS_MIN_SPACING} apart) and the slow ring ({SLOW_OBS_CARDINALITY} entries,
    /// {SLOW_OBS_MIN_SPACING} apart) - so that {consult} and {consultSlow} can each difference
    /// two points in time.
    ///
    /// @dev TIMESTAMP MONOTONICITY. Both rings, the score accumulator and the fee windows assume
    /// `block.timestamp` never goes BACKWARDS between blocks (it may repeat). This holds on
    /// Ethereum L1 and on the Arbitrum Orbit stack this is deployed to (the sequencer clamps the
    /// L2 timestamp to be non-decreasing). On a chain where it can move backwards the `nowTs -
    /// timestamp` subtractions below would underflow and revert inside a swap.
    function _observe(PoolId id, RegisteredPool storage p, uint160 sqrtPriceX96) internal {
        uint64 nowTs = uint64(block.timestamp);
        uint192 cum = p.cumSqrtP;
        uint64 tObs = p.tObs;
        // `cumSqrtP` wraps by design (it is only ever differenced), so the product is truncated
        // to 192 bits and added unchecked: see the range note on {IFamilyHook.RegisteredPool}.
        if (tObs != 0) {
            unchecked {
                cum += uint192(uint256(sqrtPriceX96) * uint256(nowTs - tObs));
            }
        }
        // `cum` and `tObs` share one slot: this is a single SSTORE
        p.cumSqrtP = cum;
        p.tObs = nowTs;

        obsCount[id] = _writeObs(observations[id], obsCount[id], nowTs, cum, OBS_CARDINALITY, OBS_MIN_SPACING);
        slowObsCount[id] =
            _writeObs(slowObservations[id], slowObsCount[id], nowTs, cum, SLOW_OBS_CARDINALITY, SLOW_OBS_MIN_SPACING);
    }

    /// @dev Append `cum` to `ring` if the newest entry is at least `minSpacing` old; returns the
    /// new observation count.
    function _writeObs(
        mapping(uint256 => Observation) storage ring,
        uint256 count,
        uint64 nowTs,
        uint192 cum,
        uint256 cardinality,
        uint64 minSpacing
    ) internal returns (uint256) {
        if (count == 0) {
            ring[0] = Observation({timestamp: nowTs, cumSqrtP: cum});
            return 1;
        }
        if (nowTs - ring[(count - 1) % cardinality].timestamp < minSpacing) return count;
        ring[count % cardinality] = Observation({timestamp: nowTs, cumSqrtP: cum});
        return count + 1;
    }

    /// @inheritdoc IFamilyHook
    function consult(PoolId id, uint32 window) external view returns (uint160 twapSqrtPriceX96, uint32 coveredSeconds) {
        return _consult(observations[id], obsCount[id], OBS_CARDINALITY, id, window);
    }

    /// @inheritdoc IFamilyHook
    function consultSlow(PoolId id, uint32 window)
        external
        view
        returns (uint160 twapSqrtPriceX96, uint32 coveredSeconds)
    {
        return _consult(slowObservations[id], slowObsCount[id], SLOW_OBS_CARDINALITY, id, window);
    }

    /// @notice Two-point cumulative-price TWAP: `(cum(now) - cum(t_ref)) / (now - t_ref)`, where
    /// `t_ref` is the newest entry of `ring` at least `window` seconds old, or the oldest entry
    /// the ring still holds if the pool has no history that far back.
    /// @dev The second return value is how many seconds of history the average actually covers,
    /// so a caller can refuse to act on a TWAP that is really a spot price (M2). A pool with no
    /// observations at all reports its spot price with ZERO coverage; it is up to the caller
    /// (see `BidDeployer._twap`) to treat that as unusable rather than as a pass.
    function _consult(
        mapping(uint256 => Observation) storage ring,
        uint256 count,
        uint256 cardinality,
        PoolId id,
        uint32 window
    ) internal view returns (uint160 twapSqrtPriceX96, uint32 coveredSeconds) {
        RegisteredPool storage p = registeredPools[id];
        if (!p.registered) revert PoolNotRegistered();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);

        if (count == 0) return (sqrtPriceX96, 0);

        uint64 nowTs = uint64(block.timestamp);
        uint192 cumNow;
        unchecked {
            cumNow = p.cumSqrtP + uint192(uint256(sqrtPriceX96) * uint256(nowTs - p.tObs));
        }
        uint64 target = nowTs > window ? nowTs - uint64(window) : 0;

        // The ring is ordered by timestamp starting at `oldestSlot`, so the newest entry at or
        // before `target` is found by BINARY search: a linear scan would cost up to 2 SLOADs per
        // entry per call, and the keeper path makes one call per generation.
        uint256 stored = count < cardinality ? count : cardinality;
        uint256 oldestSlot = count < cardinality ? 0 : count % cardinality;
        uint256 bestIndex;
        uint256 lo;
        uint256 hi = stored - 1;
        while (lo <= hi) {
            uint256 mid = (lo + hi) / 2;
            if (ring[(oldestSlot + mid) % cardinality].timestamp <= target) {
                bestIndex = mid;
                lo = mid + 1;
            } else {
                if (mid == 0) break;
                hi = mid - 1;
            }
        }
        Observation memory best = ring[(oldestSlot + bestIndex) % cardinality];
        if (nowTs <= best.timestamp) return (sqrtPriceX96, 0);
        uint64 covered = nowTs - best.timestamp;
        // the difference of two points of a wrapping accumulator: exact mod 2^192
        uint192 span;
        unchecked {
            span = cumNow - best.cumSqrtP;
        }
        return (uint160(uint256(span) / covered), uint32(covered));
    }

    /// @inheritdoc IFamilyHook
    function observationCount(PoolId id) external view returns (uint256) {
        return obsCount[id];
    }

    /// @inheritdoc IFamilyHook
    function slowObservationCount(PoolId id) external view returns (uint256) {
        return slowObsCount[id];
    }

    // -------------------------------------------------------------------------------------
    // disabled entrypoints (permission bits are not set, so these are unreachable)
    // -------------------------------------------------------------------------------------

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
