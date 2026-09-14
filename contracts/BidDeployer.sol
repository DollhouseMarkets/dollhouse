// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FamilyFactory} from "./FamilyFactory.sol";
import {FamilyHook} from "./FamilyHook.sol";
import {FAMILY_TOTAL_SUPPLY} from "./FamilyToken.sol";
import {FeeVault} from "./FeeVault.sol";
import {Locker} from "./Locker.sol";
import {RoundManager} from "./RoundManager.sol";
import {IBidDeployer} from "./interfaces/IBidDeployer.sol";
import {IPriorRegistry} from "./interfaces/IPriorRegistry.sol";
import {IVersionFactory} from "./interfaces/IVersionFactory.sol";
import {StandardCurve} from "./libraries/StandardCurve.sol";
import {V4UnlockGuard} from "./libraries/V4UnlockGuard.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {CurveRange} from "./types/CurveRange.sol";

/// @title BidDeployer
/// @notice The permissionless KEEPER half of the protocol's treasury: it turns the FeeVault's
/// ledgers into permanently locked buy-support, and pays the caller a {BOUNTY_BPS} bounty for
/// the gas. No owner, no setter, no way to move value anywhere but into a Locker position or to
/// the keeper that earned the bounty.
///
/// @dev Split out of `FeeVault` because the two together no longer fit under EIP-170
/// (docs/TESTNET_RUN.md). The seam is exactly the keeper/bid machinery: the TWAP band guard, the
/// active-range reserve cap, the bid range and the launch-curve cold start. The vault keeps the
/// ledgers and exposes four tightly scoped hooks that ONLY this contract may call
/// ({FeeVault.consumeAncestorClaim}, {FeeVault.consumeReinforcement},
/// {FeeVault.consumeGenesisEarmark}, {FeeVault.payKeeper}), so the authority this contract holds
/// is exactly "spend what a generation is already owed, and only into that generation's pool".
///
/// The vault NEVER swaps and neither does this contract. Earlier versions routed generation `j`'s
/// ETH sleeve up the canonical chain through the FamilyRouter with `minOut = 0`, which cost `j`
/// swaps plus `2 * (j + 1)` TWAP consults per call - a hard gas wall somewhere around generation
/// 60-120, and an unbounded-slippage trade the vault could not price (H1/M3). Instead the KEEPER
/// brings the parent tokens and the protocol buys them at the chain's own TWAP:
///
///   ethValue = parentAmount * PROD_{k=0..j-1} twap_k        (O(j) consults, view-only)
///   vault pays the keeper  ethValue * (1 + BOUNTY_BPS)      out of generation `j`'s ETH
///   deposit                parentAmount (+ the parent-denominated hop pot) as a locked bid
///
/// Gas is therefore O(j) in STATIC CALLS ONLY (one `poolKeyOf`, one `consult`, one
/// `observationCount`, one `getSlot0` and one `poolInfo` per generation), with no swap, no
/// unlock and no liquidity walk per generation.
contract BidDeployer is IBidDeployer {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    // -------------------------------------------------------------------------------------
    // constants
    // -------------------------------------------------------------------------------------

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// @notice Keeper bounty on a verified deployment: 1% of the ETH deployed, ON TOP of it.
    uint256 public constant BOUNTY_BPS = 100;
    /// @notice Audit 5: the ceiling on {MIN_BOUNTY_WEI}. However small a deployment is, the
    /// bounty is never more than 20% of the ETH the call consumes in total (deployment plus
    /// bounty) - so the floor can never turn a keeper call into a drain of the sleeve.
    uint256 public constant MAX_BOUNTY_SHARE_BPS = 2_000;
    /// @notice Keeper deployments must execute within +/-3% of the pool's TWAP...
    uint256 public constant TWAP_BAND_BPS = 300;
    /// @notice ...measured over this window (seconds).
    uint32 public constant TWAP_WINDOW = 1800;
    /// @notice The SLOW window every conversion is also priced over (F4): the protocol pays
    /// `min(TWAP_30m, TWAP_7d)` per link, so a 30-minute pump of a thin ancestor pool cannot
    /// raise what the sleeve pays for a keeper's parent tokens.
    uint32 public constant SLOW_TWAP_WINDOW = 7 days;
    /// @notice How much slow history a pool must have before its slow average is used at all.
    /// Below this the fast average is used alone and {SlowTwapUnavailable} is emitted.
    uint32 public constant SLOW_TWAP_MIN_COVERAGE = 1 days;
    /// @notice ...and may not exceed this share of the target pool's parent reserve per call.
    uint256 public constant MAX_RESERVE_BPS = 200;
    /// @notice Bid width: 10 tick spacings immediately below spot.
    int24 public constant BID_WIDTH_SPACINGS = 10;

    // -------------------------------------------------------------------------------------
    // wiring (all immutable, all read off the version's own factory)
    // -------------------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    FamilyFactory public immutable factory;
    FamilyHook public immutable hook;
    Locker public immutable locker;
    RoundManager public immutable roundManager;
    FeeVault public immutable feeVault;
    /// @notice True when this stack CONTINUES an earlier version: generations at or below
    /// `roundManager.priorIndex()` then live in pools owned by an earlier hook/Locker, so their
    /// TWAPs must be read from that version's hook and their bids must be placed by that
    /// version's BidDeployer. Immutable, so a fresh deploy pays exactly nothing for any of it.
    bool public immutable isContinuation;

    /// @notice AUDIT 5 - KEEPER ECONOMICS. The proportional 1% bounty is worth less than the gas
    /// of the call at beta scale (Run 2: gas about 215x the bounty at j = 1, and 121 wei at
    /// j = 8), so nobody would ever deploy a bid. A deployment therefore pays
    /// `max(1% of the ETH deployed, MIN_BOUNTY_WEI)`, still out of the SAME generation's ETH
    /// entitlement and still capped at {MAX_BOUNTY_SHARE_BPS} of the ETH the call consumes. A
    /// deploy constant (testnet 3e14 = 0.0003 ETH); zero restores the pure 1% behaviour.
    uint256 public immutable MIN_BOUNTY_WEI;

    // -------------------------------------------------------------------------------------
    // events
    // -------------------------------------------------------------------------------------

    event AncestorDeployed(
        uint256 indexed generation, address indexed keeper, uint256 ethUsed, uint256 parentDeposited, uint256 bounty
    );
    event GenesisBidDeployed(address indexed keeper, uint256 ethDeposited, uint256 bounty);
    /// @notice MECHANISM_v3 sec.1: generation `j`'s purse was locked as bid liquidity under
    /// `trunk`, the coin that won round `j`. There is no other destination.
    event PurseDeployed(uint256 indexed generation, address indexed trunk, uint256 parentDeposited);
    /// @notice Audit 3: generation `j`'s PARENT-denominated hop pot was deployed on its own, with
    /// no ETH entitlement involved and the bounty paid in the same parent token.
    event HopPotDeployed(
        uint256 indexed generation, address indexed keeper, uint256 parentDeposited, uint256 parentBounty
    );
    /// @notice F4: at least one pool on the conversion chain has no slow (7-day) average yet, so
    /// this deployment was priced on the 30-minute average alone. Loud by design: it marks every
    /// payout made without the slow-price floor.
    event SlowTwapUnavailable(uint256 indexed generation);
    /// @notice A permissionless gift of parent liquidity under one of this version's links.
    event ExternalBidDeposited(uint256 indexed generation, address indexed from, uint256 parentDeposited);
    /// @notice Generation `j`'s bid was placed by an EARLIER version's BidDeployer, because `j`'s
    /// pool belongs to that version and only its Locker may add liquidity there.
    event AncestorForwarded(uint256 indexed generation, address indexed priorDeployer, uint256 parentDeposited);

    // -------------------------------------------------------------------------------------
    // errors
    // -------------------------------------------------------------------------------------

    error NoCode();
    error NotWired();
    error Reentrancy();
    error NothingToClaim();
    error TransferFailed();
    error UnknownGeneration();
    error PriceOutOfBand();
    error SizeCapExceeded(uint256 amount, uint256 cap);
    error TooMuchRequested();
    /// @notice The pool's oracle does not yet cover {TWAP_WINDOW}: there is no TWAP to band
    /// against, and a spot price is NOT an acceptable substitute (M2).
    error TwapNotReady(uint32 covered, uint256 observations);
    /// @notice The consult chain produced a zero or unusable ETH-per-parent rate.
    error BadConversionRate();
    /// @notice The bid range collapsed against the tick bounds (L3).
    error BidRangeEmpty();
    /// @notice {depositExternalBid} was called for a token this version does not own, or with the
    /// wrong `msg.value` for the pool's parent currency.
    error NotOurLink();
    error WrongValue();

    /// @notice REN-01: a keeper entrypoint was called from inside a v4 `PoolManager` unlock.
    error InsideUnlock();

    uint256 private _locked = 1;

    /// @notice REN-01 (defence in depth). Refuse a keeper deployment made from inside a v4
    /// `PoolManager` unlock, i.e. with somebody's flash accounting still open.
    ///
    /// @dev Every path below ends in a `Locker` deposit, which opens an unlock of its own and
    /// would revert `AlreadyUnlocked` - but only AFTER the vault ledgers have been drawn and the
    /// TWAP band read inside somebody else's half-settled frame. This says no at the door, and
    /// says it with an error of the protocol's own.
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

    /// @dev The vault is deployed one nonce before this contract and named this contract's
    /// PREDICTED address to the factory, which handed it to the Locker. Both ends of that
    /// prediction are checked here, so a mis-ordered deployment fails loudly and immediately
    /// instead of producing a stack whose keeper paths can never be authorised (L7).
    constructor(FeeVault _feeVault, uint256 _minBountyWei) {
        MIN_BOUNTY_WEI = _minBountyWei;
        if (address(_feeVault).code.length == 0) revert NoCode();
        feeVault = _feeVault;
        factory = _feeVault.factory();
        poolManager = _feeVault.poolManager();
        hook = _feeVault.hook();
        roundManager = _feeVault.roundManager();
        locker = factory.locker();
        if (address(locker).code.length == 0) revert NoCode();
        if (factory.bidDeployer() != address(this)) revert NotWired();
        if (_feeVault.bidDeployer() != address(this)) revert NotWired();
        isContinuation = roundManager.priorRegistry() != address(0);
    }

    /// @dev The vault pays the drawn ETH here, and it leaves again in the same call.
    receive() external payable {}

    // -------------------------------------------------------------------------------------
    // views a keeper must consult first
    // -------------------------------------------------------------------------------------

    /// @notice The ETH value of one WAD of generation `j`'s token, from the canonical chain's
    /// TWAPs. Convenience view over {ethValueOfParent}; deep chains where one WAD is worth less
    /// than a wei revert with {BadConversionRate}, which is exactly why the keeper paths convert
    /// the REAL amount instead of a normalised rate.
    function ethPerTokenWad(uint256 j) public view returns (uint256 rateWad) {
        (rateWad,) = ethValueOfParent(j, WAD);
    }

    /// @notice The ETH value of `amount` tokens of generation `j`, walked link by link down the
    /// canonical chain.
    ///
    /// @dev F3. The old implementation multiplied a WAD-normalised rate per link; each link is
    /// worth 5-8% of its parent, so the rate lost ~4 significant digits per generation and hit
    /// zero ({BadConversionRate}) around j = 10, stranding every deeper generation's ETH sleeve
    /// forever. Walking the AMOUNT through the chain with a full-precision {FullMath.mulDiv} per
    /// factor keeps all 256 bits of the value the whole way down: the only thing that has to be
    /// non-zero is the final ETH amount, not an intermediate rate.
    ///
    /// Every pool on the chain must have a usable TWAP (coverage guard, {_twap}); the BAND is
    /// checked on the target pool only (F5), because requiring j + 1 pools to be simultaneously
    /// in band made the keeper path progressively unusable with depth. Every link's price is
    /// `min(spot, TWAP_30m, TWAP_7d)` in VALUE terms (audit 1), so a crashed conversion pool
    /// cannot be paid for at its pre-crash average.
    /// @return ethValue The ETH value of `amount`.
    /// @return slowMissing True when at least one link had no slow average to floor the price
    /// with, so the conversion used the 30-minute average alone.
    function ethValueOfParent(uint256 j, uint256 amount) public view returns (uint256 ethValue, bool slowMissing) {
        ethValue = amount;
        for (uint256 k = 0;; k++) {
            PoolId id = roundManager.poolKeyOf(k).toId();
            FamilyHook h = _hookFor(k);
            bool parentIsCurrency0 = h.poolInfo(id).parentIsCurrency0;
            (uint160 twap, bool slowUsed) = _priceFor(h, id, parentIsCurrency0);
            if (!slowUsed) slowMissing = true;
            // parent per token: (Q96/sqrtP)^2 when the parent is currency0, (sqrtP/Q96)^2 when it
            // is currency1 - applied to the AMOUNT as two independent full-precision mulDivs, so
            // neither the square nor a normalised rate is ever materialised.
            if (parentIsCurrency0) {
                ethValue = FullMath.mulDiv(ethValue, FixedPoint96.Q96, twap);
                ethValue = FullMath.mulDiv(ethValue, FixedPoint96.Q96, twap);
            } else {
                ethValue = FullMath.mulDiv(ethValue, twap, FixedPoint96.Q96);
                ethValue = FullMath.mulDiv(ethValue, twap, FixedPoint96.Q96);
            }
            if (k == j) break;
        }
        if (ethValue == 0) revert BadConversionRate();
    }

    /// @notice The inverse walk: how much of generation `j`'s token is worth `ethValue` ETH.
    /// Step-wise, in the same full precision, so {maxParentForDeploy} stays meaningful at depth.
    function parentForEthValue(uint256 j, uint256 ethValue) public view returns (uint256 amount) {
        amount = ethValue;
        uint256 k = j + 1;
        while (k != 0) {
            --k;
            PoolId id = roundManager.poolKeyOf(k).toId();
            FamilyHook h = _hookFor(k);
            bool parentIsCurrency0 = h.poolInfo(id).parentIsCurrency0;
            (uint160 twap,) = _priceFor(h, id, parentIsCurrency0);
            if (parentIsCurrency0) {
                amount = FullMath.mulDiv(amount, twap, FixedPoint96.Q96);
                amount = FullMath.mulDiv(amount, twap, FixedPoint96.Q96);
            } else {
                amount = FullMath.mulDiv(amount, FixedPoint96.Q96, twap);
                amount = FullMath.mulDiv(amount, FixedPoint96.Q96, twap);
            }
        }
    }

    /// @notice The largest parent-token bid generation `j`'s pool will accept right now
    /// ({MAX_RESERVE_BPS} of the active range's parent reserve). A keeper MUST size its transfer
    /// against this and {maxParentForDeploy}; the smaller of the two is what will go through.
    function bidCap(uint256 j) public view returns (uint256) {
        PoolKey memory key = roundManager.poolKeyOf(j);
        if (address(key.hooks) == address(0)) return 0;
        bool parentIsCurrency0 = j == 0 || Currency.unwrap(key.currency0) == roundManager.canonical(j - 1);
        return _cap(key, parentIsCurrency0, j, roundManager.canonical(j));
    }

    /// @notice The most parent token generation `j`'s ETH sleeve can pay for, bounty included.
    /// Reverts through {_requireWithinBand} if any pool on the chain has no usable TWAP.
    function maxParentForDeploy(uint256 j) external view returns (uint256) {
        if (j == 0) return 0;
        uint256 available = feeVault.drawableEth(j);
        if (available == 0) return 0;
        return parentForEthValue(j - 1, _maxEthValueFor(available));
    }

    /// @dev The exact inverse of `payout(v) = v + {_bounty}(v) <= available`. `_bounty` is
    /// piecewise in `v` - proportional, then the {MIN_BOUNTY_WEI} floor, then the
    /// {MAX_BOUNTY_SHARE_BPS} ceiling that caps the floor at a share of the value - so the
    /// inverse is piecewise too. Writing `available - MIN_BOUNTY_WEI` and calling it a day was
    /// wrong for a SMALL allowance: below the floor the bounty is capped at 20% of the total the
    /// call consumes, so a deployment of `0.8 * available` is perfectly acceptable and the
    /// function used to report zero for it (run-3 finding).
    ///
    /// With `m = MIN_BOUNTY_WEI`, the three branches of `payout` and their inverses are:
    ///   v >= 100m  (proportional bounty)  payout = 1.01 v     -> v = available * 100 / 101
    ///   4m <= v < 100m (flat floor)       payout = v + m      -> v = available - m
    ///   v < 4m     (bounty ceiling)       payout = 1.25 v     -> v = available * 4 / 5
    /// which are selected by `available` against the same thresholds carried through `payout`.
    function _maxEthValueFor(uint256 available) internal view returns (uint256) {
        uint256 m = MIN_BOUNTY_WEI;
        // v >= 100m  <=>  payout >= 101m
        if (available >= m * (BPS + BOUNTY_BPS) / BOUNTY_BPS) {
            return (available * BPS) / (BPS + BOUNTY_BPS);
        }
        // 4m <= v  <=>  payout >= 5m
        uint256 ceilingKnee = (m * (BPS - MAX_BOUNTY_SHARE_BPS)) / MAX_BOUNTY_SHARE_BPS; // 4m
        if (available >= ceilingKnee + m) return available - m;
        // below the floor's own ceiling: the bounty is {MAX_BOUNTY_SHARE_BPS} of the total
        return (available * (BPS - MAX_BOUNTY_SHARE_BPS)) / BPS;
    }

    // -------------------------------------------------------------------------------------
    // keeper: deploy support
    // -------------------------------------------------------------------------------------

    /// @notice THE PURSE (MECHANISM_v3 sec.1). Buy `parentAmount` of generation `j`'s PARENT
    /// token from the keeper at the chain's TWAP and lock it as bids just below spot under
    /// `canonical(j)` - the trunk coin that won round `j`. The keeper is paid the ETH value plus
    /// {BOUNTY_BPS} out of `j`'s own ETH sleeve.
    ///
    /// @dev The purse is NOT contestable. Generation `j`'s share of the ancestor sleeve, fed by
    /// every later trade in the family forever, is deployed in one place: under the link that
    /// holds canonical index `j`. Nothing measured after the round can move it, there is no
    /// ranking, no board and no split, and a losing sibling never receives purse liquidity. The
    /// point is to keep as much value as possible on the canonical chain, where every later
    /// generation trades through it; a trunk coin that is dumped or abandoned is for its own
    /// community to take over, not for the protocol to penalise.
    ///
    /// Losers are not written off: they stay tradable and keep the creator share of their own
    /// pool's fees. They simply have no claim on the chain's fee stream.
    /// @dev The keeper must have approved THIS contract for `parentAmount` of `canonical(j - 1)`.
    function deployAncestor(uint256 j, uint256 parentAmount)
        external
        nonReentrant
        notInsideUnlock
        returns (uint256 deposited)
    {
        if (j == 0) revert UnknownGeneration(); // genesis takes ETH directly: see deployGenesisBid
        address trunk = roundManager.canonical(j);
        if (trunk == address(0)) revert UnknownGeneration();
        if (parentAmount == 0) revert NothingToClaim();

        address parentToken = roundManager.canonical(j - 1);

        // price the keeper's parent tokens in ETH off the chain's TWAPs; this band-checks every
        // pool whose price enters the product, and the TARGET pool is checked as it is bid into
        (uint256 ethValue, bool slowMissing) = ethValueOfParent(j - 1, parentAmount);
        if (slowMissing) emit SlowTwapUnavailable(j);
        if (ethValue == 0) revert BadConversionRate();

        // the keeper is paid the ETH value plus the bounty and both come out of `j`'s own ETH,
        // so the ledger must cover the WHOLE payout (stricter than `ethValue <= claimable`), and
        // the vault's 24 h drawdown allowance bounds it further (F4)
        uint256 payout = ethValue + _bounty(ethValue);
        uint256 available = feeVault.drawableEth(j);
        if (ethValue > available || payout > available) revert TooMuchRequested();

        IERC20(parentToken).safeTransferFrom(msg.sender, address(this), parentAmount);
        feeVault.consumeAncestorClaim(j, payout);

        deposited = _placeBid(j, parentToken, roundManager.poolKeyOf(j), trunk, parentAmount);

        feeVault.payKeeper(msg.sender, payout);
        emit AncestorDeployed(j, msg.sender, payout, deposited, payout - ethValue);
        emit PurseDeployed(j, trunk, deposited);
    }

    /// @dev Band-check one target pool, size it against its OWN curve and reserve, top it up from
    /// the shared reinforcement pot (H2) and lock the lot as a bid just below its spot.
    function _placeBid(uint256 j, address parentToken, PoolKey memory key, address childToken, uint256 amount)
        internal
        returns (uint256 deposited)
    {
        _requireWithinBand(_hookFor(j), key.toId());
        bool parentIsCurrency0 = Currency.unwrap(key.currency0) == parentToken;
        uint256 cap = _cap(key, parentIsCurrency0, j, childToken);
        if (amount > cap) revert SizeCapExceeded(amount, cap);

        // H2: the generation's own hop fees are already in parent units, and are drawn
        // PARTIALLY, up to whatever room the size cap leaves - never all-or-nothing.
        deposited = amount + feeVault.consumeReinforcement(parentToken, cap - amount);

        address priorDeployer = _priorDeployerFor(j);
        if (priorDeployer == address(0)) {
            (int24 tickLower, int24 tickUpper) = _bidTicks(key, parentIsCurrency0);
            IERC20(parentToken).safeTransfer(address(locker), deposited);
            locker.depositBid(key, deposited, tickLower, tickUpper);
        } else {
            // `j`'s pool belongs to an earlier version, whose hook accepts liquidity only from
            // its OWN Locker. Hand the parent tokens to that version's BidDeployer and let it
            // place the bid; nothing is stranded and the beneficiary is still generation `j`.
            IERC20(parentToken).forceApprove(priorDeployer, deposited);
            IBidDeployer(priorDeployer).depositExternalBid(childToken, deposited);
            emit AncestorForwarded(j, priorDeployer, deposited);
        }
    }

    /// @notice AUDIT 3 - DEPLOY A GENERATION'S HOP POT ON ITS OWN. Draw up to the size cap of the
    /// parent-denominated hop pot that generation `j`'s trades have collected and lock it as a bid
    /// just below spot in `j`'s pool, paying the caller {BOUNTY_BPS} of the draw IN THE SAME
    /// PARENT TOKEN. Permissionless, and nothing about it touches ETH.
    ///
    /// @dev The reinforcement pot was only ever deployable as a SUPPLEMENT to {deployAncestor},
    /// which needs generation `j`'s ETH sleeve - and a sleeve only fills when a DEEPER link is
    /// the attributed terminal token. The head of the chain therefore had no deployment path at
    /// all, permanently so at {RoundManager.MAX_INDEX}: its hop fees accumulated in the vault and
    /// could never become liquidity. This is that path. The bounty comes out of the draw itself
    /// (there is no other pot to pay it from), so the deposit plus the bounty is exactly what was
    /// drawn and the size cap still bounds the whole call.
    /// @return deposited The parent tokens locked as a bid under `j`.
    /// @return bounty The parent tokens paid to `msg.sender`.
    function deployHopPot(uint256 j) external nonReentrant notInsideUnlock returns (uint256 deposited, uint256 bounty) {
        if (j == 0) revert UnknownGeneration(); // genesis's pot is ETH: see deployGenesisBid
        if (roundManager.canonical(j) == address(0)) revert UnknownGeneration();

        address parentToken = roundManager.canonical(j - 1);
        PoolKey memory key = roundManager.poolKeyOf(j);
        // the same sandwich guard as every other bid: protocol-owned liquidity is never shoved
        // into a manipulated book
        _requireWithinBand(_hookFor(j), key.toId());

        bool parentIsCurrency0 = Currency.unwrap(key.currency0) == parentToken;
        uint256 cap = _cap(key, parentIsCurrency0, j, roundManager.canonical(j));
        if (cap == 0) revert SizeCapExceeded(0, 0);

        uint256 drawn = feeVault.consumeReinforcement(parentToken, cap);
        if (drawn == 0) revert NothingToClaim();
        bounty = (drawn * BOUNTY_BPS) / BPS;
        deposited = drawn - bounty;
        if (deposited == 0) revert NothingToClaim();

        address priorDeployer = _priorDeployerFor(j);
        if (priorDeployer == address(0)) {
            (int24 tickLower, int24 tickUpper) = _bidTicks(key, parentIsCurrency0);
            IERC20(parentToken).safeTransfer(address(locker), deposited);
            locker.depositBid(key, deposited, tickLower, tickUpper);
        } else {
            IERC20(parentToken).forceApprove(priorDeployer, deposited);
            IBidDeployer(priorDeployer).depositExternalBid(roundManager.canonical(j), deposited);
            emit AncestorForwarded(j, priorDeployer, deposited);
        }

        if (bounty != 0) IERC20(parentToken).safeTransfer(msg.sender, bounty);
        emit HopPotDeployed(j, msg.sender, deposited, bounty);
    }

    /// @notice Deposit the earmarked ETH - forfeited candidate bonds, the genesis-pool hop fees
    /// and genesis's own sleeve - as a locked ETH bid just below spot under genesis.
    function deployGenesisBid() external nonReentrant notInsideUnlock returns (uint256 deposited) {
        return _genesisBid(type(uint256).max);
    }

    /// @notice As {deployGenesisBid}, but deploying at most `ethAmount` of genesis's ETH sleeve
    /// (the hop pot and the bond earmark are still drawn up to whatever the size cap allows).
    function deployGenesisBid(uint256 ethAmount) external nonReentrant notInsideUnlock returns (uint256 deposited) {
        return _genesisBid(ethAmount);
    }

    /// @dev The genesis bid pays the bounty exactly the way {deployAncestor} does: ON TOP of the
    /// deployed amount, never out of it. So the three pots must fund `deposited * (1 + 1%)`, and
    /// the deposit itself is what the size cap bounds.
    function _genesisBid(uint256 sleeveRequested) internal returns (uint256 deposited) {
        PoolKey memory key = roundManager.poolKeyOf(0);
        if (address(key.hooks) == address(0)) revert UnknownGeneration();
        _requireWithinBand(_hookFor(0), key.toId());

        // native ETH is always currency0, so a genesis bid is a currency0-only range above spot
        uint256 room = _cap(key, true, 0, roundManager.canonical(0));
        if (room == 0) revert SizeCapExceeded(0, 0);

        // H2/L5: three independent pots, each drawn PARTIALLY up to what the deposit plus its
        // bounty needs. The sleeve may be zero and the hop pot non-zero, or the other way round:
        // any non-empty combination deploys, and nothing is ever zeroed beyond what is spent.
        uint256 sleeveAvailable = feeVault.drawableEth(0);
        if (sleeveRequested < sleeveAvailable) sleeveAvailable = sleeveRequested;
        uint256 potTotal = sleeveAvailable + feeVault.reinforcementBalance(address(0)) + feeVault.genesisBidEarmark();

        deposited = (potTotal * BPS) / (BPS + BOUNTY_BPS);
        if (deposited > room) deposited = room;
        if (deposited == 0) revert NothingToClaim();
        uint256 bounty = _bounty(deposited);
        // audit 5: the floored bounty may not fit next to a deposit sized for the 1% one, so the
        // DEPOSIT gives way - the pots are what they are, and the bounty is what makes the call
        // worth its gas
        if (deposited + bounty > potTotal) {
            deposited = potTotal > bounty ? potTotal - bounty : 0;
            if (deposited == 0) revert NothingToClaim();
            bounty = _bounty(deposited);
        }
        uint256 need = deposited + bounty;
        if (need > potTotal) revert NothingToClaim();

        // draw `need` from the pots in order: sleeve, then the genesis pool's hop fees, then the
        // forfeited bonds. Every draw arrives here as real ETH.
        uint256 fromSleeve = _draw(sleeveAvailable, need);
        if (fromSleeve != 0) {
            feeVault.consumeAncestorClaim(0, fromSleeve);
            feeVault.payKeeper(address(this), fromSleeve);
        }
        uint256 drawn = fromSleeve;
        if (drawn < need) drawn += feeVault.consumeReinforcement(address(0), need - drawn);
        if (drawn < need) drawn += feeVault.consumeGenesisEarmark(need - drawn);
        // the pots were measured a few lines above and only this contract can spend them, so a
        // short draw is impossible; refuse rather than place a bid the bounty cannot be paid on
        if (drawn != need) revert TooMuchRequested();

        address priorDeployer = _priorDeployerFor(0);
        if (priorDeployer == address(0)) {
            (int24 tickLower, int24 tickUpper) = _bidTicks(key, true);
            locker.depositBid{value: deposited}(key, deposited, tickLower, tickUpper);
        } else {
            // CONTINUATION: genesis always belongs to the original version, so its ETH bid - the
            // forfeited bonds of THIS version's rounds included - is placed by that version's
            // BidDeployer. This is the live cross-version payout path.
            IBidDeployer(priorDeployer).depositExternalBid{value: deposited}(roundManager.canonical(0), deposited);
            emit AncestorForwarded(0, priorDeployer, deposited);
        }

        if (bounty != 0) _sendEth(msg.sender, bounty);
        emit GenesisBidDeployed(msg.sender, deposited, bounty);
    }

    /// @inheritdoc IBidDeployer
    function depositExternalBid(address token, uint256 parentAmount)
        external
        payable
        nonReentrant
        notInsideUnlock
        returns (uint256 deposited)
    {
        if (parentAmount == 0) revert NothingToClaim();
        // only a link THIS version wrote: a delegated read would resolve a prior version's token
        // too, and this version's Locker cannot place liquidity in that version's pool
        if (!roundManager.ownsToken(token) || !roundManager.isCanonical(token)) revert NotOurLink();
        uint256 j = roundManager.indexOf(token);
        if (roundManager.canonical(j) != token) revert NotOurLink();

        PoolKey memory key = roundManager.poolKeyOf(j);
        // the same sandwich and size guards as the keeper path: a gift may not be used to shove
        // protocol-owned liquidity into a manipulated book
        _requireWithinBand(hook, key.toId());
        bool parentIsCurrency0 = j == 0 || Currency.unwrap(key.currency0) == roundManager.canonical(j - 1);
        uint256 cap = _cap(key, parentIsCurrency0, j, roundManager.canonical(j));
        if (parentAmount > cap) revert SizeCapExceeded(parentAmount, cap);

        (int24 tickLower, int24 tickUpper) = _bidTicks(key, parentIsCurrency0);
        Currency parent = parentIsCurrency0 ? key.currency0 : key.currency1;
        if (parent.isAddressZero()) {
            if (msg.value != parentAmount) revert WrongValue();
            locker.depositBid{value: parentAmount}(key, parentAmount, tickLower, tickUpper);
        } else {
            if (msg.value != 0) revert WrongValue();
            IERC20(Currency.unwrap(parent)).safeTransferFrom(msg.sender, address(locker), parentAmount);
            locker.depositBid(key, parentAmount, tickLower, tickUpper);
        }

        deposited = parentAmount;
        emit ExternalBidDeposited(j, msg.sender, parentAmount);
    }

    // -------------------------------------------------------------------------------------
    // cross-version resolution
    // -------------------------------------------------------------------------------------

    /// @dev The factory that launched generation `j`'s pool. This one, unless `j` predates this
    /// deployment, in which case the registry chain names the version that owns it.
    function _factoryFor(uint256 j) internal view returns (FamilyFactory) {
        if (!isContinuation) return factory;
        address reg = roundManager.registryOf(j);
        if (reg == address(roundManager)) return factory;
        return FamilyFactory(IPriorRegistry(reg).factory());
    }

    /// @dev The hook that holds generation `j`'s TWAP and orientation. Reading the wrong version's
    /// hook would report "no observations" and silently disable the band guard, so every consult
    /// on the canonical chain goes through here.
    function _hookFor(uint256 j) internal view returns (FamilyHook) {
        if (!isContinuation) return hook;
        address reg = roundManager.registryOf(j);
        if (reg == address(roundManager)) return hook;
        return FamilyFactory(IPriorRegistry(reg).factory()).hook();
    }

    /// @dev The BidDeployer that may place a bid in generation `j`'s pool: this one, or the
    /// earlier version's, whose Locker is the only address `j`'s hook accepts liquidity from.
    /// Returns `address(0)` when `j` belongs to this version.
    function _priorDeployerFor(uint256 j) internal view returns (address) {
        if (!isContinuation) return address(0);
        address reg = roundManager.registryOf(j);
        if (reg == address(roundManager)) return address(0);
        return IVersionFactory(IPriorRegistry(reg).factory()).bidDeployer();
    }

    // -------------------------------------------------------------------------------------
    // guards and geometry
    // -------------------------------------------------------------------------------------

    /// @dev The bounty an ETH deployment of `ethValue` pays (audit 5): the 1% proportional
    /// bounty, floored at {MIN_BOUNTY_WEI} so a small deployment is still worth its gas, and
    /// capped so the bounty is never more than {MAX_BOUNTY_SHARE_BPS} of the ETH the call
    /// consumes in total. `bounty <= 20% * (ethValue + bounty)` is exactly
    /// `bounty <= ethValue * 2000 / 8000`, so a deployment far below the floor pays a
    /// proportional bounty and no keeper can make a profit by fragmenting one into many calls.
    function _bounty(uint256 ethValue) internal view returns (uint256 bounty) {
        bounty = (ethValue * BOUNTY_BPS) / BPS;
        if (bounty < MIN_BOUNTY_WEI) bounty = MIN_BOUNTY_WEI;
        uint256 ceiling = (ethValue * MAX_BOUNTY_SHARE_BPS) / (BPS - MAX_BOUNTY_SHARE_BPS);
        if (bounty > ceiling) bounty = ceiling;
    }

    /// @dev `min(pot, room)`: the partial-draw primitive H2 is built on.
    function _draw(uint256 pot, uint256 room) internal pure returns (uint256) {
        return pot < room ? pot : room;
    }

    /// @dev Sandwich guard: spot within +/-{TWAP_BAND_BPS} of the TWAP. The band is applied to
    /// the SQRT price (which is what {FamilyHook.consult} averages), so it is roughly half as
    /// wide in price terms: +/-3% of sqrt price is about +/-6.1% of price.
    ///
    /// M2: a TWAP that does not cover the whole {TWAP_WINDOW}, or a pool with fewer than two
    /// observations, is NOT a pass - it reverts. The previous version silently accepted a zero
    /// or spot-price "TWAP", which turned the band guard off exactly when a pool was too young
    /// to have one.
    function _requireWithinBand(FamilyHook h, PoolId id) internal view returns (uint160 twap) {
        twap = _twap(h, id);
        (uint160 spot,,,) = poolManager.getSlot0(id);
        uint256 t = uint256(twap);
        if (spot < (t * (BPS - TWAP_BAND_BPS)) / BPS || spot > (t * (BPS + TWAP_BAND_BPS)) / BPS) {
            revert PriceOutOfBand();
        }
    }

    /// @dev The fast average of a pool, with the COVERAGE guard (M2) but no band check. Every
    /// pool whose price enters a conversion must have one; only the TARGET pool is band-checked
    /// (F5), since a stale ancestor price is already bounded by the min-of-two-TWAPs rule below.
    function _twap(FamilyHook h, PoolId id) internal view returns (uint160 twap) {
        uint32 covered;
        (twap, covered) = h.consult(id, TWAP_WINDOW);
        uint256 observations = h.observationCount(id);
        if (covered < TWAP_WINDOW || observations < 2 || twap == 0) revert TwapNotReady(covered, observations);
    }

    /// @dev The price a conversion uses for one link: whichever of the CURRENT SPOT, the
    /// 30-minute average and the 7-day average values the link LOWEST (audit 1 / F4). A
    /// 30-minute pump moves the fast average and leaves the slow one alone, so the protocol keeps
    /// paying the pre-pump price; a genuine repricing is picked up as soon as the slow ring
    /// catches up. Until a pool has {SLOW_TWAP_MIN_COVERAGE} of slow history there is nothing to
    /// floor with, and the caller is told so (`slowUsed == false`).
    ///
    /// AUDIT 1: the averages alone are not enough. Only the TARGET pool is band-checked against
    /// spot (F5), so after a crash in a CONVERSION pool both averages still quote the pre-crash
    /// price and the vault would pay ~1.01x the old value for a parcel now worth a tenth of it.
    /// Including spot in the same min makes every link's price at most what the market says right
    /// now; a pump cannot raise it (the averages cap it) and a crash cannot be ignored (spot caps
    /// it). The band guard on `j`'s own pool is unchanged - spot here only ever LOWERS a payout,
    /// so it cannot be used to extract more by moving a price.
    ///
    /// "Lowest" is orientation-dependent: the link is worth `(Q96/sqrtP)^2` of its parent when the
    /// PARENT is currency0 and `(sqrtP/Q96)^2` when it is currency1, so the conservative choice
    /// is the HIGHEST sqrt price in the first case and the LOWEST one in the second.
    function _priceFor(FamilyHook h, PoolId id, bool parentIsCurrency0)
        internal
        view
        returns (uint160 price, bool slowUsed)
    {
        price = _twap(h, id);
        (uint160 spot,,,) = poolManager.getSlot0(id);
        if (spot != 0 && (parentIsCurrency0 ? spot > price : spot < price)) price = spot;
        (uint160 slow, uint32 slowCovered) = h.consultSlow(id, SLOW_TWAP_WINDOW);
        if (slow == 0 || slowCovered < SLOW_TWAP_MIN_COVERAGE) return (price, false);
        if (parentIsCurrency0 ? slow > price : slow < price) price = slow;
        return (price, true);
    }

    /// @dev The size cap for one call: {MAX_RESERVE_BPS} of the LARGER of the active tick
    /// bucket's parent reserve and the parent needed to buy out the whole FIRST curve range from
    /// the current price (F7).
    ///
    /// Sizing against the active bucket alone made the keeper bounty smaller than the gas of the
    /// call at beta scale (a 60-tick bucket of a concentrated curve holds a tiny fraction of the
    /// range), so nobody would ever deploy a bid. The first range is the liquidity a buy actually
    /// walks into, which is the economically meaningful denominator; the 2% share is unchanged,
    /// so a single call still cannot move a pool.
    function _cap(PoolKey memory key, bool parentIsCurrency0, uint256 j, address token)
        internal
        view
        returns (uint256)
    {
        uint256 basis = _parentReserve(key, parentIsCurrency0, j, token);
        uint256 firstRange = _firstRangeParentCapacity(key, parentIsCurrency0, j, token);
        if (firstRange > basis) basis = firstRange;
        return (basis * MAX_RESERVE_BPS) / BPS;
    }

    /// @dev The parent amount that would buy out the whole first range of generation `j`'s
    /// registered launch curve, starting from the pool's current price. Zero once the price has
    /// walked past that range, in which case {_cap} falls back to the active bucket.
    function _firstRangeParentCapacity(PoolKey memory key, bool parentIsCurrency0, uint256 j, address token)
        internal
        view
        returns (uint256)
    {
        CurveRange[] memory ranges = _curveRanges(key, j, token);
        if (ranges.length == 0) return 0;
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        if (sqrtP == 0) return 0;
        uint160 lower = TickMath.getSqrtPriceAtTick(ranges[0].tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(ranges[0].tickUpper);
        if (parentIsCurrency0) {
            // buying the child with parent walks the price DOWN through the range
            uint160 from = sqrtP < upper ? sqrtP : upper;
            if (from <= lower) return 0;
            return SqrtPriceMath.getAmount0Delta(lower, from, ranges[0].liquidity, false);
        }
        uint160 fromMirrored = sqrtP > lower ? sqrtP : lower;
        if (fromMirrored >= upper) return 0;
        return SqrtPriceMath.getAmount1Delta(fromMirrored, upper, ranges[0].liquidity, false);
    }

    /// @dev Parent-side reserve of the pool's ACTIVE tick range: the real amount of parent
    /// currency between spot and the far edge of the current tick-spacing bucket, via
    /// `SqrtPriceMath` (H3), rather than the whole-range virtual reserve `L / sqrtP`, which
    /// over-states a concentrated book by orders of magnitude.
    ///
    /// Cold start: a freshly launched pool sits exactly AT the top tick of its curve, so no
    /// position is in range and `getLiquidity()` is zero. Rather than report a zero reserve
    /// (which caps every bid at zero and makes a cold pool permanently un-supportable), fall
    /// back to the liquidity of the registered curve's FIRST range - the liquidity a buy of one
    /// wei would immediately cross into.
    function _parentReserve(PoolKey memory key, bool parentIsCurrency0, uint256 j, address token)
        internal
        view
        returns (uint256)
    {
        PoolId id = key.toId();
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(id);
        if (sqrtP == 0) return 0;
        uint128 L = poolManager.getLiquidity(id);
        if (L == 0) L = _coldStartLiquidity(key, j, token);
        if (L == 0) return 0;

        int24 spacing = key.tickSpacing;
        int24 activeLower = CurveMath.floorToSpacing(tick, spacing);
        int24 activeUpper = activeLower + spacing;
        return parentIsCurrency0
            ? SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(activeUpper), L, false)
            : SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(activeLower), sqrtP, L, false);
    }

    /// @dev The first range of generation `j`'s registered launch curve, recomputed from the
    /// same deploy constants the factory launched it with.
    function _coldStartLiquidity(PoolKey memory key, uint256 j, address token) internal view returns (uint128) {
        CurveRange[] memory ranges = _curveRanges(key, j, token);
        return ranges.length == 0 ? 0 : ranges[0].liquidity;
    }

    /// @dev Generation `j`'s launch curve, rebuilt from the deploy constants of the version that
    /// launched it.
    /// @dev `token` is the CHILD of the pool being sized - `canonical(j)` for the trunk link, or a
    /// losing SIBLING of the same generation when the purse is being split. Every sibling of a
    /// generation launched off the same parent supply with the same standard curve, so the shape
    /// is identical; only the orientation depends on how the token sorted.
    function _curveRanges(PoolKey memory key, uint256 j, address token)
        internal
        view
        returns (CurveRange[] memory ranges)
    {
        if (token == address(0)) return ranges;
        FamilyFactory f = _factoryFor(j);
        if (j == 0) {
            (ranges,) = f.genesisCurve();
        } else {
            (ranges,) = StandardCurve.build(
                f.curveSpec(),
                IERC20(roundManager.canonical(j - 1)).totalSupply(),
                FAMILY_TOTAL_SUPPLY,
                key.tickSpacing,
                Currency.unwrap(key.currency0) == token
            );
        }
    }

    /// @dev The bid range: {BID_WIDTH_SPACINGS} tick spacings on the parent-only side of spot,
    /// i.e. immediately BELOW the child token's current price in both orientations.
    ///
    /// L3: both branches clamp against the usable tick bounds, and the clamp must never invert
    /// or collapse the range - `tickLower < tickUpper` is re-established after clamping (the
    /// old code clamped only one end and could produce an empty or inverted range at the
    /// extremes), and a range that still cannot fit a spacing is refused outright.
    function _bidTicks(PoolKey memory key, bool parentIsCurrency0)
        internal
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 spacing = key.tickSpacing;
        int24 width = spacing * BID_WIDTH_SPACINGS;
        int24 maxTick = CurveMath.floorToSpacing(TickMath.MAX_TICK, spacing);
        int24 minTick = CurveMath.floorToSpacing(TickMath.MIN_TICK, spacing) + spacing;
        if (parentIsCurrency0) {
            tickLower = CurveMath.floorToSpacing(currentTick, spacing) + spacing;
            if (tickLower > maxTick - spacing) tickLower = maxTick - spacing;
            tickUpper = tickLower + width;
            if (tickUpper > maxTick) tickUpper = maxTick;
        } else {
            tickUpper = CurveMath.floorToSpacing(currentTick, spacing);
            if (tickUpper < minTick + spacing) tickUpper = minTick + spacing;
            tickLower = tickUpper - width;
            if (tickLower < minTick) tickLower = minTick;
        }
        if (tickLower >= tickUpper) revert BidRangeEmpty();
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
