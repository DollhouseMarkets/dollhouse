// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FamilyFactory} from "../../contracts/FamilyFactory.sol";
import {FamilyHook} from "../../contracts/FamilyHook.sol";
import {FamilyToken} from "../../contracts/FamilyToken.sol";
import {MockDoll} from "../utils/MockDoll.sol";
import {MockVenueOracle} from "../utils/MockVenueOracle.sol";
import {MockV2Pair} from "../utils/SidePoolMocks.sol";
import {FamilyRouter} from "../../contracts/FamilyRouter.sol";
import {BidDeployer} from "../../contracts/BidDeployer.sol";
import {FeeVault} from "../../contracts/FeeVault.sol";
import {Locker} from "../../contracts/Locker.sol";
import {RoundManager, RoundManagerDeployer} from "../../contracts/RoundManager.sol";
import {MockRandomnessSource} from "../../contracts/randomness/MockRandomnessSource.sol";
import {CurveSegment} from "../../contracts/types/CurveSegment.sol";

/// @title MedusaTarget
/// @notice A cheatcode-free deployment of the whole protocol plus the fuzz action set, so that
/// Medusa (which has no `setUp()` and no forge-std invariant machinery) has something to fuzz.
/// Everything the forge-std suite does with `vm.computeCreateAddress` / `HookMiner` is done here
/// in plain Solidity inside the constructor:
///   * contract-address predictions are RLP-computed from this contract's own CREATE nonce,
///     which is 1 at the start of the constructor and increments per `new`;
///   * the v4 hook salt is mined in a loop over `keccak256(0xff ++ factory ++ salt ++ initHash)`,
///     with the init-code hash taken ONCE outside the loop (HookMiner re-hashes the whole init
///     code every iteration, which would cost hundreds of millions of gas here).
/// Time is advanced by Medusa itself (`blockTimestampDelayMax`). The stack is ERC-20
/// only, so the working capital is the mock $DOLL this contract mints itself rather than the ETH
/// balance `fuzzing.targetContractsBalances` would otherwise supply.
contract MedusaTarget is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // ---------------------------------------------------------------------------------
    // deployment constants (mirrors test/utils/FamilyTestBase.sol)
    // ---------------------------------------------------------------------------------
    uint256 internal constant HOP_FEE_PPM = 1_000;
    uint256 internal constant BOND_BASE = 0.001 ether;
    uint256 internal constant BOND_DOUBLING_EVERY = 4;
    uint256 internal constant BOND_MAX = 0.064 ether;
    uint256 internal constant H_FRAC_WAD = 1.5e15;
    uint256 internal constant H_MIN_FRAC_WAD = 3.75e14;
    uint256 internal constant CREATOR_BPS = 1_000;
    uint256 internal constant ANCESTOR_BPS = 7_143;
    uint256 internal constant REINFORCE_BPS = 2_857;
    uint256 internal constant MIN_BOUNTY_DOLL = 3e14;
    /// @dev The working balance of the adopted edge currency this target starts with.
    uint256 internal constant DOLL_SUPPLY = 1e9 * 1e18;

    address internal constant DEVELOPER = address(0xDE7);
    address internal constant STEWARD = address(0x57E);
    /// @dev Arbitrary non-zero venue id the mock oracle reports; nothing reads it as a real
    /// {PoolId}, it only has to round-trip through {FamilyFactory.bindVenueOracle}'s equality
    /// check against the {FamilyFactory.EXPECTED_VENUE_ID} baked in at construction.
    bytes32 internal constant MOCK_VENUE_ID = keccak256("medusa-mock-venue");
    /// @dev The mock oracle's initial sqrt price: Q96, i.e. a 1:1 starting quote.
    uint160 internal constant INITIAL_SQRT_P = 79228162514264337593543950336;

    // ---------------------------------------------------------------------------------
    // the stack
    // ---------------------------------------------------------------------------------
    PoolManager public poolManager;
    PoolSwapTest public swapRouter;
    FamilyFactory public factory;
    FamilyHook public hook;
    Locker public locker;
    RoundManager public roundManager;
    FeeVault public vault;
    BidDeployer public bidDeployer;
    FamilyRouter public router;
    MockRandomnessSource public randomness;
    MockDoll public doll;
    MockVenueOracle public mockOracle;
    address public genesisToken;

    // ---------------------------------------------------------------------------------
    // ghosts
    // ---------------------------------------------------------------------------------
    address[] public tokens;
    mapping(address => bool) public known;
    mapping(address => uint256) public supplySeen;
    /// @notice Canonical history as first observed - RND-09 says it is never rewritten.
    mapping(uint256 => address) public canonicalSeen;
    uint256 public canonicalSeenCount;
    uint256[] internal _candidates;

    /// @notice Coverage ghosts: a run in which these stay at zero fuzzed nothing interesting.
    uint256 public calls;
    uint256 public buysSucceeded;
    uint256 public registrations;
    uint256 public finalizations;
    uint256 public successions;
    uint256 public deploysSucceeded;
    uint256 public claims;
    uint256 public submissionsSucceeded;
    /// @notice Set if {RoundManager.submitScore} ever reverted for a live
    /// candidate while that round's submission window was open.
    bool public scoreDeniedInWindow;
    /// @notice Set if {RoundManager.finalize} ever SUCCEEDED before `submitEnd` with a candidate's
    /// score still missing: the early-finalize gate's whole premise is `submittedCount ==
    /// candidateCount` at the moment it crosses before the deadline, so a true value here is a
    /// gate failure, not a coverage note.
    bool public finalizeSucceededEarlyWithGap;
    uint256 internal _headSeen;
    /// @notice Burn ghosts: the supply each family token lost to holder burns this harness
    /// caused itself ({burnSome}). Anything else that moves a supply - a mint, a charge on a
    /// transfer - is unexplained.
    mapping(address => uint256) public explainedDecrease;
    /// @notice One v2-shaped copy pair per family token, deployed lazily by {sideTrade}.
    mapping(address => MockV2Pair) public sidePair;
    /// @notice Copy-pair legs the venue lock refused, and those it let through (never expected).
    uint256 public sideTrades;
    uint256 public sideTradesAccepted;
    uint256 public burns;
    /// @notice Canonical sells ({sell}) that reverted, and those whose revert carried
    /// `NonCanonicalVenue`: the venue lock refusing a canonical settlement.
    uint256 public canonicalSellReverts;
    uint256 public canonicalSellVenueLockReverts;
    /// @notice The hookless copy pool of link one (its canonical pool's currencies, no hook, the
    /// same PoolManager), opened and seeded lazily by {sideTradeHookless}.
    PoolKey internal _hooklessKey;
    bool public hooklessOpened;
    /// @notice {sideTradeHookless} unlocks that went through, and those that reverted.
    uint256 public hooklessSideTrades;
    uint256 public hooklessSideTradeReverts;
    /// @notice ERC-20 exits of hookless-pool output: refused by the venue lock, and let through
    /// for MORE than the outbound canonical allowance open at that moment (never expected).
    uint256 public hooklessExitsRefused;
    uint256 public hooklessExitsBeyondAllowance;

    constructor() payable {
        poolManager = new PoolManager(address(this)); // nonce 1
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager))); // nonce 2
        RoundManagerDeployer rmDeployer = new RoundManagerDeployer(); // nonce 3
        randomness = new MockRandomnessSource(0); // nonce 4
        // The EXTERNAL genesis token, deployed here because there is nothing to launch
        doll = new MockDoll(18); // nonce 5
        doll.mint(address(this), DOLL_SUPPLY);

        // The oracle is deployed (and set to a healthy state) before the factory so its own
        // codehash can be baked into the factory's EXPECTED_ORACLE_CODEHASH immutable, exactly
        // as FamilyTestBase does for the forge suite (see test/utils/FamilyTestBase.sol).
        mockOracle = new MockVenueOracle(); // nonce 6
        mockOracle.setVenue(MOCK_VENUE_ID, address(poolManager));
        mockOracle.set(INITIAL_SQRT_P, 0, 0, 0);

        address predictedFactory = _createAddress(address(this), 8);
        address predictedLocker = _createAddress(predictedFactory, 1);
        address predictedVault = _createAddress(address(this), 9);
        address predictedBidDeployer = _createAddress(address(this), 10);
        address predictedRouter = _createAddress(address(this), 11);

        (bytes32 salt, address predictedHook) = _mineHookSalt(
            predictedFactory,
            abi.encode(
                address(poolManager), predictedFactory, predictedLocker, predictedVault, predictedRouter, HOP_FEE_PPM
            )
        );
        // the implementation carries the venue-lock immutables, so the hook is mined first
        FamilyToken tokenImplementation = new FamilyToken( // nonce 7
            predictedFactory, address(poolManager), predictedHook, predictedLocker, predictedVault
        );

        factory = new FamilyFactory( // nonce 8
            IPoolManager(address(poolManager)),
            predictedVault,
            predictedBidDeployer,
            predictedRouter,
            HOP_FEE_PPM,
            H_FRAC_WAD,
            H_MIN_FRAC_WAD,
            address(doll),
            RoundManager.Bond({base: BOND_BASE, doublingEvery: BOND_DOUBLING_EVERY, max: BOND_MAX}),
            0,
            STEWARD,
            7 days,
            address(0),
            _standardCurveSpec(),
            salt,
            address(tokenImplementation),
            "https://meta.test/token/4663/",
            FamilyFactory.RoundSetup({
                deployer: address(rmDeployer),
                randomness: address(randomness),
                endTimeout: 30 minutes,
                durationScaleDiv: 1
            }),
            // the mock oracle deployed above: a zero fallback so the oracle's healthy state
            // (rather than the constant fallback) drives the start price by default
            FamilyFactory.StartSetup({
                expectedVenueId: MOCK_VENUE_ID,
                oracleCodehash: address(mockOracle).codehash,
                fdvWei: 5e18,
                maxParentBps: 5_000,
                minParentWad: 1e15,
                fallbackDoll: 0,
                oracleGas: 200_000,
                linkMinCoverS: 1800,
                walkMax: 24
            })
        );
        vault = new FeeVault(factory, DEVELOPER, CREATOR_BPS, ANCESTOR_BPS, REINFORCE_BPS); // nonce 9
        bidDeployer = new BidDeployer(vault, MIN_BOUNTY_DOLL); // nonce 10
        router = new FamilyRouter(factory); // nonce 11

        require(address(factory) == predictedFactory, "factory prediction");
        require(address(vault) == predictedVault, "vault prediction");
        require(address(bidDeployer) == predictedBidDeployer, "bid deployer prediction");
        require(address(router) == predictedRouter, "router prediction");

        hook = factory.hook();
        locker = factory.locker();
        roundManager = factory.roundManager();
        require(address(locker) == predictedLocker, "locker prediction");

        factory.wire(); // wiring adopts canonical index 0
        factory.bindVenueOracle(address(mockOracle));
        genesisToken = address(doll);
        _noteToken(genesisToken);
        doll.approve(address(factory), type(uint256).max);
        doll.approve(address(router), type(uint256).max);
        doll.approve(address(swapRouter), type(uint256).max);
        doll.approve(address(bidDeployer), type(uint256).max);
        _snapshot();
    }

    // ---------------------------------------------------------------------------------
    // cheatcode-free address helpers
    // ---------------------------------------------------------------------------------

    /// @dev CREATE address for nonces 1..127 (all this harness ever needs): the RLP encoding is
    /// `0xd6 0x94 <20-byte address> <1-byte nonce>`.
    function _createAddress(address deployer, uint256 nonce) internal pure returns (address) {
        require(nonce > 0 && nonce < 0x80, "nonce range");
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce))))));
    }

    /// @dev The v4 flag bits {FamilyHook} declares.
    function _hookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    /// @dev {HookMiner.find} with the init-code hash hoisted out of the loop.
    function _mineHookSalt(address deployer, bytes memory args) internal pure returns (bytes32, address) {
        uint160 flags = _hookFlags() & Hooks.ALL_HOOK_MASK;
        bytes32 initHash = keccak256(abi.encodePacked(type(FamilyHook).creationCode, args));
        for (uint256 salt = 0; salt < 200_000; salt++) {
            address a =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags) return (bytes32(salt), a);
        }
        revert("no hook salt");
    }

    function _standardCurveSpec() internal pure returns (CurveSegment[] memory spec) {
        spec = new CurveSegment[](4);
        spec[0] = CurveSegment({shareWad: 0.2e18, fdvRatioLowerWad: 1e15, fdvRatioUpperWad: 1e16});
        spec[1] = CurveSegment({shareWad: 0.25e18, fdvRatioLowerWad: 1e16, fdvRatioUpperWad: 1e17});
        spec[2] = CurveSegment({shareWad: 0.35e18, fdvRatioLowerWad: 1e17, fdvRatioUpperWad: 1e18});
        spec[3] = CurveSegment({shareWad: 0.2e18, fdvRatioLowerWad: 1e18, fdvRatioUpperWad: 100e18});
    }

    // ---------------------------------------------------------------------------------
    // ghost bookkeeping
    // ---------------------------------------------------------------------------------

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function _noteToken(address t) internal {
        if (t == address(0) || known[t]) return;
        known[t] = true;
        tokens.push(t);
        supplySeen[t] = IERC20(t).totalSupply();
        IERC20(t).approve(address(swapRouter), type(uint256).max);
        IERC20(t).approve(address(router), type(uint256).max);
        IERC20(t).approve(address(bidDeployer), type(uint256).max);
    }

    function _snapshot() internal {
        uint256 head = roundManager.headIndex();
        for (uint256 i = canonicalSeenCount; i <= head; i++) {
            canonicalSeen[i] = roundManager.canonical(i);
            canonicalSeenCount = i + 1;
            _noteToken(canonicalSeen[i]);
        }
        if (head != _headSeen) {
            successions++;
            _headSeen = head;
        }
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    // ---------------------------------------------------------------------------------
    // actions
    // ---------------------------------------------------------------------------------

    function buy(uint256 targetSeed, uint256 amountSeed) external {
        calls++;
        uint256 head = roundManager.headIndex();
        if (head == 0) return; // index 0 has no pool of ours: there is nothing to buy yet
        uint256 target = 1 + (targetSeed % head);
        uint256 dollIn = _bound(amountSeed, 0.001 ether, 20 ether);
        if (doll.balanceOf(address(this)) < dollIn) return;
        try router.buyExactIn(target, dollIn, 0, address(this), target + 1) returns (uint256) {
            buysSucceeded++;
        } catch {}
        _snapshot();
    }

    function sell(uint256 targetSeed, uint256 tokenAmount) external {
        calls++;
        uint256 head = roundManager.headIndex();
        if (head == 0) return;
        uint256 target = 1 + (targetSeed % head);
        address t = roundManager.canonical(target);
        uint256 balance = IERC20(t).balanceOf(address(this));
        if (balance == 0) return;
        try router.sellExactIn(target, _bound(tokenAmount, 1, balance), 0, address(this), target + 1) returns (uint256)
        {} catch (bytes memory reason) {
            canonicalSellReverts++;
            // A canonical sell settles exactly what the hook credited, so the venue lock must
            // let every leg through. Its refusal surfaces as `NonCanonicalVenue`, raw on a
            // payment into the PoolManager or inside the PoolManager's `WrappedError` on a take;
            // either is counted. Every other revert (a price limit, an empty curve) stays allowed.
            if (_carriesSelector(reason, FamilyToken.NonCanonicalVenue.selector)) {
                canonicalSellVenueLockReverts++;
            }
        }
        _snapshot();
    }

    function register() external {
        calls++;
        uint256 bond = roundManager.currentBond();
        if (doll.balanceOf(address(this)) < bond) return;
        try factory.registerCandidate("H", "H", "", type(uint256).max) returns (address t, PoolKey memory, uint256 id) {
            _noteToken(t);
            _candidates.push(id);
            registrations++;
        } catch {}
        _snapshot();
    }

    function tradeCandidate(uint256 seed, uint256 amountSeed) external {
        calls++;
        if (_candidates.length == 0) return;
        RoundManager.Candidate memory c = roundManager.candidateInfo(_candidates[seed % _candidates.length]);
        address parent = roundManager.head();
        uint256 balance = IERC20(parent).balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = _bound(amountSeed, 1, balance);
        bool zeroForOne = Currency.unwrap(c.key.currency0) == parent;
        try swapRouter.swap(
            c.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {} catch {}
        _snapshot();
    }

    /// @dev Drives the bound {MockVenueOracle} through the states {FamilyFactory._venueStart}
    /// must survive without ever reverting: a healthy quote (mode 0) anywhere in the v4 sqrt
    /// price range, any status byte (0 normal, {FamilyFactory.ORACLE_STALE} = 2 stale-with-price,
    /// {FamilyFactory.ORACLE_SLOW_SHORT} = 8 fast-only-with-price, anything else or either of
    /// those without a price treated as failed), plus the oracle actively reverting, burning all the gas
    /// it is given, or returning a short/malformed word (modes 1-4).
    /// @dev A holder burns part of its own balance of a family token.
    function burnSome(uint256 seed, uint256 amountSeed) external {
        calls++;
        address t = _familyToken(seed);
        if (t == address(0)) return;
        uint256 balance = IERC20(t).balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = _bound(amountSeed, 1, balance);
        FamilyToken(t).burn(amount);
        explainedDecrease[t] += amount;
        burns++;
        _snapshot();
    }

    /// @dev Try to trade a family token through a v2-shaped copy pair: into it (a sell or LP add)
    /// or out of it (a buy or LP remove). The venue lock refuses every leg, so no supply and no
    /// balance moves; a leg that goes through is counted in {sideTradesAccepted}.
    function sideTrade(uint256 seed, uint256 amountSeed, bool intoPair) external {
        calls++;
        address t = _familyToken(seed);
        if (t == address(0)) return;
        MockV2Pair pair = sidePair[t];
        if (address(pair) == address(0)) {
            pair = new MockV2Pair(t, address(doll));
            sidePair[t] = pair;
        }
        address from = intoPair ? address(this) : address(pair);
        uint256 balance = IERC20(t).balanceOf(from);
        if (balance == 0) return;
        uint256 amount = _bound(amountSeed, 1, balance);
        bool ok;
        if (intoPair) {
            (ok,) = t.call(abi.encodeCall(IERC20.transfer, (address(pair), amount)));
        } else {
            (ok,) = address(pair).call(abi.encodeCall(MockV2Pair.send, (t, address(this), amount)));
        }
        if (ok) sideTradesAccepted++;
        else sideTrades++;
        _snapshot();
    }

    /// @dev Trade link one on a HOOKLESS v4 pool in the same PoolManager through ERC-6909 claims
    /// (the claims residual), inside one unlock - all this harness can do in one transaction:
    ///   mode 0: a canonical buy kept as claims (no ERC-20 moves; its outbound allowance stays
    ///           unused), then half of all claims held (earlier calls' included) sold on the
    ///           hookless pool for $DOLL;
    ///   mode 1: a hookless buy for $DOLL, kept as claims;
    ///   mode 2: a hookless buy for $DOLL, then an attempt to take it out as ERC-20, which the
    ///           venue lock must refuse beyond the outbound allowance (kept as claims if refused).
    /// The first call opens the pool at the canonical price and seeds it, its link-one side paid
    /// by an exact-output canonical buy netted in the PoolManager (no link one moves).
    function sideTradeHookless(uint256 amountSeed, uint8 mode) external {
        calls++;
        if (roundManager.headIndex() == 0) return;
        PoolKey memory canon = roundManager.poolKeyOf(1);
        if (!hooklessOpened) {
            (uint160 sqrtP,,,) = IPoolManager(address(poolManager)).getSlot0(canon.toId());
            if (sqrtP == 0) return;
            _hooklessKey = PoolKey({
                currency0: canon.currency0,
                currency1: canon.currency1,
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
            try poolManager.initialize(_hooklessKey, sqrtP) {} catch {}
            hooklessOpened = true;
        }
        uint256 amount = _bound(amountSeed, 1e12, 1e19);
        try poolManager.unlock(abi.encode(canon, mode % 3, amount)) {
            hooklessSideTrades++;
        } catch {
            hooklessSideTradeReverts++;
        }
        _snapshot();
    }

    /// @dev {sideTradeHookless}'s unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not the manager");
        (PoolKey memory canon, uint256 mode, uint256 amount) = abi.decode(data, (PoolKey, uint256, uint256));
        IPoolManager pm = IPoolManager(address(poolManager));
        PoolKey memory side = _hooklessKey;
        Currency cDoll = Currency.wrap(address(doll));
        Currency cLink = Currency.unwrap(canon.currency0) == address(doll) ? canon.currency1 : canon.currency0;
        bool dollIs0 = Currency.unwrap(canon.currency0) == address(doll);

        if (pm.getLiquidity(side.toId()) == 0) {
            pm.modifyLiquidity(
                side,
                ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(60),
                    tickUpper: TickMath.maxUsableTick(60),
                    liquidityDelta: 1e18,
                    salt: 0
                }),
                ""
            );
            int256 owed = pm.currencyDelta(address(this), cLink);
            if (owed < 0) _swap(pm, canon, dollIs0, -owed); // exact-output canonical buy
        }

        if (mode == 0) {
            _swap(pm, canon, dollIs0, -int256(amount)); // canonical buy, exact in
            _mintCredit(pm, cLink); // kept as claims
            uint256 half = pm.balanceOf(address(this), cLink.toId()) / 2;
            if (half != 0) {
                pm.burn(address(this), cLink.toId(), half);
                _swap(pm, side, !dollIs0, -int256(half)); // hookless sell of the claims
                _mintCredit(pm, cLink); // whatever a partial fill left unsold
            }
        } else {
            _swap(pm, side, dollIs0, -int256(amount)); // hookless buy, exact in
            int256 got = pm.currencyDelta(address(this), cLink);
            if (mode == 2 && got > 0) {
                (, uint256 outAllowance) = FamilyToken(Currency.unwrap(cLink)).canonicalAllowance();
                try pm.take(cLink, address(this), uint256(got)) {
                    if (uint256(got) > outAllowance) hooklessExitsBeyondAllowance++;
                } catch {
                    hooklessExitsRefused++;
                }
            }
            _mintCredit(pm, cLink);
        }

        int256 d = pm.currencyDelta(address(this), cDoll);
        if (d < 0) {
            pm.sync(cDoll);
            doll.transfer(address(poolManager), uint256(-d));
            pm.settle();
        } else if (d > 0) {
            pm.take(cDoll, address(this), uint256(d));
        }
        return "";
    }

    function _swap(IPoolManager pm, PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal {
        pm.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
    }

    /// @dev Keep this contract's whole credit in `c` as ERC-6909 claims.
    function _mintCredit(IPoolManager pm, Currency c) internal {
        int256 d = pm.currencyDelta(address(this), c);
        if (d > 0) pm.mint(address(this), c.toId(), uint256(d));
    }

    /// @dev `reason` carries `selector` at a word boundary plus 0 or 4 bytes: at its start (a raw
    /// custom error) or as the head of a nested revert reason (an ERC-7751 `WrappedError`).
    function _carriesSelector(bytes memory reason, bytes4 selector) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= reason.length; i++) {
            if (
                reason[i] == selector[0] && reason[i + 1] == selector[1] && reason[i + 2] == selector[2]
                    && reason[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    /// @dev A family token (never the adopted genesis) picked by `seed`, or zero if none yet.
    function _familyToken(uint256 seed) internal view returns (address) {
        if (tokens.length < 2) return address(0);
        return tokens[1 + (seed % (tokens.length - 1))];
    }

    function setOracle(uint256 sqrtPSeed, uint256 statusSeed, uint256 streakSeed, uint256 modeSeed) external {
        calls++;
        uint160 sqrtP = uint160(_bound(sqrtPSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        uint8 status = uint8(_bound(statusSeed, 0, type(uint8).max));
        uint32 streak = uint32(_bound(streakSeed, 0, type(uint32).max));
        uint8 mode = uint8(_bound(modeSeed, 0, 4));
        mockOracle.set(sqrtP, status, streak, mode);
        _snapshot();
    }

    function requestEnd() external {
        calls++;
        try roundManager.requestEnd() returns (bytes32) {} catch {}
        _snapshot();
    }

    /// @dev The mock relays a word of 0, i.e. `T_end == T`.
    function fulfilMock() external {
        calls++;
        try roundManager.fulfilEnd("") returns (uint64) {} catch {}
        _snapshot();
    }

    function submitScores() external {
        calls++;
        _submitAll();
        _snapshot();
    }

    /// @dev A submission that REVERTS while the submission window is OPEN is a
    /// property violation, not something to swallow. The old harness caught every revert here,
    /// which is exactly why a fuzzer never surfaced the score-availability hole: the round simply
    /// finalized with no best candidate and every invariant still held.
    function _submitAll() internal {
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
        bool windowOpen = r.tradingEnd != 0 && block.timestamp >= r.tradingEnd && block.timestamp < r.submitEnd;
        for (uint256 i = 0; i < _candidates.length; i++) {
            try roundManager.submitScore(_candidates[i]) returns (int256) {
                submissionsSucceeded++;
            } catch {
                if (windowOpen) scoreDeniedInWindow = true;
            }
        }
    }

    function finalize() external {
        calls++;
        uint256 roundId = roundManager.roundCount();
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        _submitAll();
        try roundManager.finalize() {
            // THE EARLY-FINALIZE GATE, CHECKED AT THE MOMENT IT CROSSED. `r` is the round as it
            // stood before this call (and before `_submitAll` above), which is exactly the state
            // `finalize` itself read to decide whether the early path was open.
            if (block.timestamp < r.submitEnd && roundManager.submittedCount(roundId) < r.candidateCount) {
                finalizeSucceededEarlyWithGap = true;
            }
            delete _candidates;
            finalizations++;
        } catch {}
        _snapshot();
    }

    function keeperDeploy(uint256 seed, uint256 amountSeed) external {
        calls++;
        try bidDeployer.deployEdgeBid() returns (uint256) {
            deploysSucceeded++;
        } catch {}
        uint256 head = roundManager.headIndex();
        if (head == 0) return;
        uint256 j = 1 + (seed % head);
        {
            address parent = roundManager.canonical(j - 1);
            uint256 balance = IERC20(parent).balanceOf(address(this));
            if (balance != 0) {
                uint256 amount = _bound(amountSeed, 1, balance / 1000 == 0 ? balance : balance / 1000);
                try bidDeployer.deployAncestor(j, amount) returns (uint256) {
                    deploysSucceeded++;
                } catch {}
            }
        }
        try bidDeployer.deployHopPot(j) returns (uint256, uint256) {
            deploysSucceeded++;
        } catch {}
        _snapshot();
    }

    function claimDev() external {
        calls++;
        try vault.claimDev(DEVELOPER) returns (uint256) {
            claims++;
        } catch {}
        _snapshot();
    }

    function claimCreator(uint256 seed) external {
        calls++;
        uint256 head = roundManager.headIndex();
        address t = roundManager.canonical(head == 0 ? 0 : seed % (head + 1));
        address recipient = vault.creatorRecipient(t);
        if (recipient == address(0)) return;
        try vault.claimCreator(t, recipient) returns (uint256) {
            claims++;
        } catch {}
        _snapshot();
    }

    function claimForward(uint256 seed) external {
        calls++;
        uint256 head = roundManager.headIndex();
        uint256 j = head == 0 ? 0 : seed % (head + 1);
        try vault.flushForward(j, 1) returns (uint256) {} catch {}
        _snapshot();
    }

    // ---------------------------------------------------------------------------------
    // properties
    // ---------------------------------------------------------------------------------

    /// @notice A candidate's closing-window score is ALWAYS readable for the
    /// whole submission window. Nothing a trader does after the reveal - including burying the
    /// checkpoint rings under dust - may make {RoundManager.submitScore} revert.
    function property_SCR13_scoreIsAlwaysSubmittable() public view returns (bool) {
        return !scoreDeniedInWindow;
    }

    /// @notice THE EARLY-FINALIZE GATE: `finalize()` never succeeds before `submitEnd` unless
    /// `submittedCount == candidateCount` at that moment - restated here as the negation of the
    /// ghost {finalize} sets the instant it would have been violated.
    function property_finalizeNeverBeforeAllScoresOrSubmitEnd() public view returns (bool) {
        return !finalizeSucceededEarlyWithGap;
    }

    /// @notice FEE-11: for every currency `ledgerTotal[c] <= holdings(c)` - the vault's promises
    /// are always backed by its real balance plus unredeemed ERC-6909 claims.
    function property_FEE11_vaultIsSolvent() public view returns (bool) {
        Currency edge = vault.EDGE();
        if (vault.ledgerTotal(edge) > vault.holdings(edge)) return false;
        if (vault.ledgerTotal(edge) < vault.pendingForwardTotal()) return false;
        uint256 head = roundManager.headIndex();
        for (uint256 i = 0; i <= head; i++) {
            Currency c = Currency.wrap(roundManager.canonical(i));
            if (vault.ledgerTotal(c) > vault.holdings(c)) return false;
        }
        return true;
    }

    /// @notice FEE-08: the NON-EDGE ledgers are hop fees (and snipe tax) alone - a protocol fee
    /// exists only on an edge (link-one) pool, whose parent currency is index 0.
    function property_FEE08_familyLedgersAreHopFeesOnly() public view returns (bool) {
        uint256 head = roundManager.headIndex();
        for (uint256 i = 1; i <= head; i++) {
            address t = roundManager.canonical(i);
            if (vault.ledgerTotal(Currency.wrap(t)) != vault.reinforcementBalance(t)) return false;
        }
        return true;
    }

    /// @notice SUP-01: there is no mint path: `totalSupply()` never rises above what it was when
    /// the token was first seen. (It may FALL, by a holder's burn; see
    /// {property_supplyOnlyDecreasesByBurn} for the exact account of every decrease.)
    function property_SUP01_supplyNeverMoves() public view returns (bool) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (IERC20(tokens[i]).totalSupply() > supplySeen[tokens[i]]) return false;
        }
        return true;
    }

    /// @notice VENUE LOCK: every family token's supply decreases ONLY by a holder's plain burn,
    /// to the wei: `totalSupply + burned == launch supply`. Canonical trades (router buys and
    /// sells, direct candidate swaps), refused copy-pair legs, keeper bids, vault redemptions
    /// and claims must move no supply at all, so any charge on a transfer breaks this equality.
    function property_supplyOnlyDecreasesByBurn() public view returns (bool) {
        for (uint256 i = 1; i < tokens.length; i++) {
            address t = tokens[i];
            if (IERC20(t).totalSupply() + explainedDecrease[t] != supplySeen[t]) return false;
        }
        return true;
    }

    /// @notice VENUE LOCK: a canonical sell through the FamilyRouter is never refused by the
    /// venue lock. A revert of {sell} carrying `NonCanonicalVenue` is a FAILURE, not a swallowed
    /// revert; genuine slippage and limit reverts are still allowed (they are counted in
    /// {canonicalSellReverts} only).
    function property_canonicalSellsNeverRevertOnVenueLock() public view returns (bool) {
        return canonicalSellVenueLockReverts == 0;
    }

    /// @notice VENUE LOCK: link one bought on the hookless copy pool never leaves the PoolManager
    /// as ERC-20 for more than the outbound canonical allowance open at that moment
    /// ({sideTradeHookless} mode 2). Claims may trade there; the ERC-20 exit is what is held.
    function property_hooklessExitNeverExceedsTheAllowance() public view returns (bool) {
        return hooklessExitsBeyondAllowance == 0;
    }

    /// @notice `canonical[i]` is write-once, has no gaps, and the reverse index agrees.
    function property_RND09_canonicalHistoryIsAppendOnly() public view returns (bool) {
        for (uint256 i = 0; i < canonicalSeenCount; i++) {
            if (canonicalSeen[i] == address(0)) continue;
            if (roundManager.canonical(i) != canonicalSeen[i]) return false;
        }
        uint256 head = roundManager.headIndex();
        for (uint256 i = 0; i <= head; i++) {
            address t = roundManager.canonical(i);
            if (t == address(0)) return false;
            if (roundManager.indexOf(t) != i) return false;
            if (!roundManager.isCanonical(t)) return false;
            if (i > 0 && roundManager.parentOf(t) != roundManager.canonical(i - 1)) return false;
        }
        return true;
    }

    /// @notice BID-05: value leaves the vault on the keeper path only against a credit created in
    /// the same call, so no keeper call ever leaves a residual credit or balance behind.
    function property_BID05_keeperLeashIsNeverSlack() public view returns (bool) {
        if (vault.deployerCredit() != 0) return false;
        if (doll.balanceOf(address(bidDeployer)) != 0) return false;
        return true;
    }

    /// @notice No contract of this protocol ever holds native ETH.
    function property_NOETH_stackHoldsNoEth() public view returns (bool) {
        if (address(factory).balance != 0) return false;
        if (address(hook).balance != 0) return false;
        if (address(locker).balance != 0) return false;
        if (address(roundManager).balance != 0) return false;
        if (address(vault).balance != 0) return false;
        if (address(bidDeployer).balance != 0) return false;
        if (address(router).balance != 0) return false;
        return true;
    }

    /// @notice V2 start rule: {FamilyFactory.quoteStart}'s cap is always within the configured
    /// [Y, X] clamp of the parent's live supply ({FamilyFactory.START_MIN_PARENT_WAD} /
    /// {FamilyFactory.START_MAX_PARENT_BPS}), for every canonical parent, whatever state
    /// {setOracle} last left the bound oracle mock in.
    function property_startWithinClamps() public view returns (bool) {
        uint256 head = roundManager.headIndex();
        for (uint256 i = 0; i <= head; i++) {
            address parent = roundManager.canonical(i);
            uint256 cap;
            try factory.quoteStart(parent) returns (uint256 c, uint256, uint16) {
                cap = c;
            } catch {
                return false;
            }
            uint256 supply = IERC20(parent).totalSupply();
            uint256 lo = supply * factory.START_MIN_PARENT_WAD() / 1e18;
            uint256 hi = supply * factory.START_MAX_PARENT_BPS() / factory.BPS();
            if (lo == 0) lo = 1;
            if (cap < lo || cap > hi) return false;
        }
        return true;
    }

    /// @notice V2 start rule: {FamilyFactory.quoteStart} - the price step every registration
    /// goes through - never reverts for a canonical parent, no matter what the bound oracle mock
    /// answers or how it misbehaves ({setOracle} modes 1-4: revert, burn-all-gas, short return,
    /// malformed return). Per {FamilyFactory._venueStart}'s NatSpec, a bad oracle must degrade to
    /// ORACLE_FAILED, never bubble a revert into the registration path.
    function property_registrationNeverRevertsOnOracleState() public view returns (bool) {
        uint256 head = roundManager.headIndex();
        for (uint256 i = 0; i <= head; i++) {
            address parent = roundManager.canonical(i);
            try factory.quoteStart(parent) returns (uint256, uint256, uint16) {}
            catch {
                return false;
            }
        }
        return true;
    }
}
