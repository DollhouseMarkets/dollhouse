// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FamilyFactory} from "../../contracts/FamilyFactory.sol";
import {FamilyHook} from "../../contracts/FamilyHook.sol";
import {FamilyToken} from "../../contracts/FamilyToken.sol";
import {FamilyRouter} from "../../contracts/FamilyRouter.sol";
import {FamilyLens} from "../../contracts/FamilyLens.sol";
import {BidDeployer} from "../../contracts/BidDeployer.sol";
import {FeeVault} from "../../contracts/FeeVault.sol";
import {Locker} from "../../contracts/Locker.sol";
import {RoundManager, RoundManagerDeployer} from "../../contracts/RoundManager.sol";
import {MockRandomnessSource} from "../../contracts/randomness/MockRandomnessSource.sol";
import {CurveMath} from "../../contracts/libraries/CurveMath.sol";
import {CurveRange} from "../../contracts/types/CurveRange.sol";
import {CurveSegment} from "../../contracts/types/CurveSegment.sol";
import {MockDoll} from "./MockDoll.sol";
import {CurveQuoter} from "./CurveQuoter.sol";

/// @dev Shared deployment for the family contracts: a fresh PoolManager, the factory (which
/// deploys the Locker and the CREATE2-mined hook), the v4 test routers, and the genesis curve.
abstract contract FamilyTestBase is Test {
    using StateLibrary for IPoolManager;

    // fee rates are parts-per-million now: 1000 ppm = 10 bps per hop, 10000 ppm = 1%
    uint256 internal constant PPM = 1_000_000;
    uint256 internal constant HOP_FEE_PPM = 1_000; // 0.10% per hop, parent side
    uint256 internal constant PROTOCOL_FEE_PPM = 10_000; // 1% on an EDGE (link one) pool
    uint256 internal constant TOTAL_FEE_PPM = HOP_FEE_PPM + PROTOCOL_FEE_PPM;
    uint256 internal constant SUPPLY = 1e9 * 1e18;
    /// @dev The adopted genesis token's supply. Index 0 is an EXTERNAL token, so this
    /// is a property of the mock, not of the protocol.
    uint256 internal constant DOLL_SUPPLY = 1e9 * 1e18;
    /// @dev Candidate bond schedule: base, doubling every 4 links, capped at 64x base -
    /// the testnet row of docs/DEPLOY_CONSTANTS.md, now denominated in $DOLL. Tests read
    /// {RoundManager.currentBond}.
    uint256 internal constant BOND_BASE = 0.001 ether;
    uint256 internal constant BOND_DOUBLING_EVERY = 4;
    uint256 internal constant BOND_MAX = 0.064 ether;
    /// @dev The fixed, deliberately LOW address the mock $DOLL is etched at, so that the edge
    /// currency always sorts as `currency0` of every link-one pool, which keeps every
    /// `zeroForOne` convention in the suite meaning "spend the parent".
    address internal constant DOLL_ADDRESS = address(0x00000000000000000000000000000000000000d0);

    /// @dev The depth cap the stack under test deploys with; 0 (unlimited) unless a test
    /// overrides it before {_deployProtocol}.
    uint256 internal maxIndex;

    /// @dev The sunset delay the stack under test deploys with (a constructor parameter,
    /// mainnet 7 days / testnet 1 hour). Tests that exercise the handover override it before
    /// {_deployProtocol}.
    uint64 internal sunsetDelay = 7 days;

    /// @dev The keeper bounty floor the stack under test deploys with: the testnet row
    /// of docs/DEPLOY_CONSTANTS.md, in $DOLL.
    uint256 internal minBountyDoll = 3e14;

    /// @dev sec.3: the random-end wiring the stack under test deploys with. The
    /// default is a {MockRandomnessSource} whose default word is 0, so every round settles at
    /// `T_end == T` and the pre-v3 timing assertions still hold; tests that exercise the random
    /// end set a word, and tests that exercise the fallback simply never fulfil.
    RoundManagerDeployer internal roundManagerDeployer;
    MockRandomnessSource internal randomness;
    uint64 internal randomnessDelayS = 0;
    uint64 internal endTimeout = 30 minutes;
    /// @dev Testnet schedule divisor (1 = the real schedule).
    uint64 internal durationScaleDiv = 1;

    /// @dev The bounty a deployment of `dollValue` pays under the stack's constants:
    /// `max(1%, MIN_BOUNTY_DOLL)`, capped at 20% of what the call consumes in total.
    function _expectedBounty(uint256 dollValue) internal view returns (uint256 bounty) {
        bounty = (dollValue * bidDeployer.BOUNTY_BPS()) / 10_000;
        if (bounty < bidDeployer.MIN_BOUNTY_DOLL()) bounty = bidDeployer.MIN_BOUNTY_DOLL();
        uint256 ceiling =
            (dollValue * bidDeployer.MAX_BOUNTY_SHARE_BPS()) / (10_000 - bidDeployer.MAX_BOUNTY_SHARE_BPS());
        if (bounty > ceiling) bounty = ceiling;
    }

    function _bondSchedule() internal view virtual returns (RoundManager.Bond memory) {
        return RoundManager.Bond({base: BOND_BASE, doublingEvery: BOND_DOUBLING_EVERY, max: BOND_MAX});
    }

    // fee split (sim.family.FeeAllocator defaults): dev 20%, creator 10%, and the 70% remainder
    // split 50/20 between the ancestor sleeve and the immediate-parent reinforcement sleeve
    uint256 internal constant CREATOR_BPS = 1_000;
    uint256 internal constant ANCESTOR_BPS = 7_143;
    uint256 internal constant REINFORCE_BPS = 2_857;

    /// @dev The constants {_deployStack} actually deploys with. They default to the tranche-1
    /// test values above; `DeployConstantsTest` overrides them with the real, locked
    /// docs/DEPLOY_CONSTANTS.md values and asserts the resulting split to the wei.
    function _hopFeePpm() internal view virtual returns (uint256) {
        return HOP_FEE_PPM;
    }

    function _creatorBps() internal view virtual returns (uint256) {
        return CREATOR_BPS;
    }

    function _ancestorBps() internal view virtual returns (uint256) {
        return ANCESTOR_BPS;
    }

    function _reinforceBps() internal view virtual returns (uint256) {
        return REINFORCE_BPS;
    }
    // threshold: h = 0.15% of the parent supply, decaying to a floor of 0.0375% (0.25 x h)
    uint256 internal constant H_FRAC_WAD = 1.5e15;
    uint256 internal constant H_MIN_FRAC_WAD = 3.75e14;

    /// @dev {_factoryArgs} defaults to the tranche-1 threshold above; `DeployConstantsTest`
    /// overrides these to the real, locked docs/DEPLOY_CONSTANTS.md values (both zero: the
    /// threshold is disabled in this deployment).
    function _hFracWad() internal view virtual returns (uint256) {
        return H_FRAC_WAD;
    }

    function _hMinFracWad() internal view virtual returns (uint256) {
        return H_MIN_FRAC_WAD;
    }

    /// @dev The deploy-target standard curve: a four-range ladder in parent-supply units,
    /// shares 20/25/35/20% over FDV ratios 1e-3 -> 1e-2 -> 1e-1 -> 1 -> 100 (the last is the tail).
    function _standardCurveSpec() internal pure returns (CurveSegment[] memory spec) {
        spec = new CurveSegment[](4);
        spec[0] = CurveSegment({shareWad: 0.2e18, fdvRatioLowerWad: 1e15, fdvRatioUpperWad: 1e16});
        spec[1] = CurveSegment({shareWad: 0.25e18, fdvRatioLowerWad: 1e16, fdvRatioUpperWad: 1e17});
        spec[2] = CurveSegment({shareWad: 0.35e18, fdvRatioLowerWad: 1e17, fdvRatioUpperWad: 1e18});
        spec[3] = CurveSegment({shareWad: 0.2e18, fdvRatioLowerWad: 1e18, fdvRatioUpperWad: 100e18});
    }

    PoolManager internal manager;
    IPoolManager internal im; // same PoolManager, typed for StateLibrary
    PoolSwapTest internal swapRouter; // doubles as the "canonical router" for attribution
    PoolSwapTest internal plainRouter; // an unattributed direct caller
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolDonateTest internal donateRouter;

    FamilyFactory internal factory;
    FamilyHook internal hook;
    Locker internal locker;
    RoundManager internal roundManager;
    FeeVault internal vault;
    BidDeployer internal bidDeployer;
    FamilyRouter internal familyRouter;
    FamilyLens internal lens;
    address internal feeVault = address(0xFEE);
    /// @dev The BidDeployer address the factory (and therefore the Locker) is built against; a
    /// prediction, exactly as {feeVault} is.
    address internal bidDeployerAddress = address(0xB1D);
    address internal developer = address(0xDE7);
    /// @dev The immutable steward of the stack under test: the only address that may announce a
    /// sunset. Tests that care override it before {_deployProtocol}.
    address internal steward = address(0x57E);
    /// @dev The registry the stack under test CONTINUES; address(0) for a fresh trunk.
    address internal priorRegistry;

    /// @dev One complete, independent deployment of the protocol. {_deployProtocol} builds one
    /// and copies it into the members above; a continuation test holds two.
    struct Stack {
        FamilyFactory factory;
        FamilyHook hook;
        Locker locker;
        RoundManager roundManager;
        FeeVault vault;
        BidDeployer bidDeployer;
        FamilyRouter router;
        FamilyLens lens;
    }

    FamilyToken internal token;
    PoolKey internal key;
    PoolId internal poolId;
    CurveRange[] internal ranges;
    uint160 internal initSqrtPriceX96;

    /// @dev The externally launched token this stack adopts as canonical index 0. It
    /// is etched at {DOLL_ADDRESS} so its sort order against every family token is fixed.
    MockDoll internal doll;
    /// @dev The decimals the mock $DOLL is deployed with; a test that exercises the adoption
    /// check overrides it before {_deployProtocol}.
    uint8 internal dollDecimals = 18;
    /// @dev The external curve helper {_curveOf} goes through; see {CurveQuoter}.
    CurveQuoter internal curveQuoter;

    receive() external payable {}

    function _deployProtocol() internal {
        _deployProtocol(false);
    }

    /// @dev Put the mock $DOLL at its fixed low address and fund this test contract with it.
    function _deployDoll() internal {
        MockDoll impl = new MockDoll(dollDecimals);
        vm.etch(DOLL_ADDRESS, address(impl).code);
        doll = MockDoll(DOLL_ADDRESS);
        doll.mint(address(this), DOLL_SUPPLY);
        vm.label(DOLL_ADDRESS, "DOLL");
    }

    /// @dev Give `who` `amount` of the edge currency.
    function _fundDoll(address who, uint256 amount) internal virtual {
        doll.mint(who, amount);
    }

    /// @dev Deploys the whole stack. The hook's trusted attribution router is either the v4 test
    /// swap router (tranche-1 fee tests, which drive the pool directly) or the real
    /// {FamilyRouter}. Deployment order is fixed so that the hook — whose address is CREATE2
    /// mined and therefore fixed before anything else exists — can be given the FeeVault and
    /// router addresses as predictions.
    function _deployProtocol(bool useFamilyRouter) internal {
        if (address(doll) == address(0)) _deployDoll();
        manager = new PoolManager(address(this));
        im = IPoolManager(address(manager));
        swapRouter = new PoolSwapTest(manager);
        plainRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        donateRouter = new PoolDonateTest(manager);

        Stack memory s = _deployStack(useFamilyRouter, steward, priorRegistry);
        factory = s.factory;
        hook = s.hook;
        locker = s.locker;
        roundManager = s.roundManager;
        vault = s.vault;
        bidDeployer = s.bidDeployer;
        familyRouter = s.router;
        lens = s.lens;

        _approveDoll();
    }

    /// @dev Approve every contract the suite spends the edge currency through.
    function _approveDoll() internal {
        doll.approve(address(swapRouter), type(uint256).max);
        doll.approve(address(plainRouter), type(uint256).max);
        doll.approve(address(liquidityRouter), type(uint256).max);
        doll.approve(address(familyRouter), type(uint256).max);
        doll.approve(address(factory), type(uint256).max);
        doll.approve(address(bidDeployer), type(uint256).max);
    }

    /// @dev Deploy ONE complete stack against the PoolManager already in {manager}, with its own
    /// factory, hook, Locker, RoundManager, FeeVault, router and lens. `prior` is the registry
    /// this stack continues (address(0) for a fresh trunk). Note that {feeVault} - the address the
    /// hook was mined against - is a member, so the most recently deployed stack owns it; tests
    /// that hold two stacks must read the vault out of the returned struct.
    function _deployStack(bool useFamilyRouter, address _steward, address prior) internal returns (Stack memory s) {
        // nonce chain: the FamilyToken implementation, then the factory (which CREATEs the
        // Locker, the hook and the RoundManager), then the FeeVault, then the BidDeployer it
        // named, then the router and the lens
        // the RoundManager helper and the randomness source are deployed ONCE, before the nonce
        // chain below is read, so a second (continuation) stack reuses them and the predictions
        // are unaffected
        if (address(roundManagerDeployer) == address(0)) roundManagerDeployer = new RoundManagerDeployer();
        if (address(randomness) == address(0)) randomness = new MockRandomnessSource(randomnessDelayS);
        uint256 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedBidDeployer = vm.computeCreateAddress(address(this), nonce + 3);
        address predictedRouter = vm.computeCreateAddress(address(this), nonce + 4);
        feeVault = predictedVault;
        bidDeployerAddress = predictedBidDeployer;

        (s.factory, s.hook) = _deployFactory(useFamilyRouter ? predictedRouter : address(swapRouter), _steward, prior);
        // refused at construction: nothing further can be deployed against it, and
        // {lastFactoryError} is what a test asserting the refusal reads
        if (address(s.factory) == address(0)) return s;
        s.vault = new FeeVault(s.factory, developer, _creatorBps(), _ancestorBps(), _reinforceBps());
        s.bidDeployer = new BidDeployer(s.vault, minBountyDoll);
        s.router = new FamilyRouter(s.factory);
        s.lens = new FamilyLens(s.factory);
        assertEq(address(s.vault), predictedVault, "fee vault address prediction");
        assertEq(address(s.bidDeployer), predictedBidDeployer, "bid deployer address prediction");
        assertEq(address(s.router), predictedRouter, "router address prediction");

        s.locker = s.factory.locker();
        s.roundManager = s.factory.roundManager();

        // every stack spends the edge currency through its OWN factory, router and deployer, so a
        // continuation test that holds two stacks needs both of them approved
        if (address(doll) != address(0)) {
            doll.approve(address(s.factory), type(uint256).max);
            doll.approve(address(s.router), type(uint256).max);
            doll.approve(address(s.bidDeployer), type(uint256).max);
        }
    }

    /// @dev The stack the base members currently point at.
    function _currentStack() internal view returns (Stack memory s) {
        s = Stack({
            factory: factory,
            hook: hook,
            locker: locker,
            roundManager: roundManager,
            vault: vault,
            bidDeployer: bidDeployer,
            router: familyRouter,
            lens: lens
        });
    }

    /// @dev Point every helper in this base (and in {RoundTestBase}) at `s`. A continuation test
    /// deploys v1, runs a round, deploys v2 and switches over: from then on `_registerCandidate`,
    /// `_runWinningRound`, `_warmOracles` and `_assertSolvent` all drive v2, while v1 keeps
    /// trading under its own hook.
    function _useStack(Stack memory s) internal {
        factory = s.factory;
        hook = s.hook;
        locker = s.locker;
        roundManager = s.roundManager;
        vault = s.vault;
        feeVault = address(s.vault);
        bidDeployer = s.bidDeployer;
        bidDeployerAddress = address(s.bidDeployer);
        familyRouter = s.router;
        lens = s.lens;
    }

    /// @dev Mine a hook salt for a factory that will be deployed at `deployer` with `args`.
    function _mine(address deployer, bytes memory args) internal view returns (address hookAddress, bytes32 salt) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        return HookMiner.find(deployer, flags, type(FamilyHook).creationCode, args);
    }

    /// @dev The FamilyToken implementation is deployed FIRST (it names the factory), then the
    /// factory, which CREATEs the Locker (its nonce-1 CREATE) and the hook (CREATE2 with a mined
    /// salt) - so all three addresses are predicted before the factory itself is deployed.
    /// There is no `DevVestingDeployer` in the ladder, so the hook salt and every nonce offset
    /// here count from the three contracts actually deployed.
    function _deployFactory(address router) internal returns (FamilyFactory f, FamilyHook h) {
        return _deployFactory(router, steward, priorRegistry);
    }

    /// @dev The hook address mining, lifted out of {_deployFactory}. The factory constructor below
    /// takes eighteen arguments, three of them structs built in memory, and the IR pipeline has no
    /// stack left for the mining locals on top of them: keeping them in their own frame is what
    /// makes this file compile.
    function _mineHook(address predictedFactory, address router)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        address predictedLocker = vm.computeCreateAddress(predictedFactory, 1);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory args =
            abi.encode(address(manager), predictedFactory, predictedLocker, feeVault, router, _hopFeePpm());
        return HookMiner.find(predictedFactory, flags, type(FamilyHook).creationCode, args);
    }

    /// @dev What {_deployFactory} is told, as opposed to what it reads off this contract.
    struct FactorySpec {
        address router;
        address steward;
        address prior;
        bytes32 salt;
        address tokenImplementation;
    }

    /// @dev EVERY constructor argument, filled in field by field. `new FamilyFactory(...)` takes
    /// seventeen of them, three of them structs, and evaluating that argument list in one frame
    /// leaves the IR pipeline a stack slot short: a nested call or a struct literal among the
    /// arguments needs a temporary that does not fit. Built here and loaded one field at a time,
    /// the deployment below is seventeen memory reads off a single pointer. Nothing about what is
    /// deployed changes; this is purely where the values are assembled.
    struct FactoryArgs {
        IPoolManager poolManager;
        address feeVault;
        address bidDeployer;
        address router;
        uint256 hopFeePpm;
        uint256 hFracWad;
        uint256 hMinFracWad;
        address genesisToken;
        RoundManager.Bond bond;
        uint256 maxIndex;
        address steward;
        uint64 sunsetDelay;
        address priorRegistry;
        CurveSegment[] standardCurve;
        bytes32 hookSalt;
        address tokenImplementation;
        FamilyFactory.RoundSetup roundSetup;
    }

    function _factoryArgs(FactorySpec memory sp) internal view returns (FactoryArgs memory a) {
        a.poolManager = IPoolManager(address(manager));
        a.feeVault = feeVault;
        a.bidDeployer = bidDeployerAddress;
        a.router = sp.router;
        a.hopFeePpm = _hopFeePpm();
        a.hFracWad = _hFracWad();
        a.hMinFracWad = _hMinFracWad();
        a.genesisToken = address(doll);
        a.bond = _bondSchedule();
        a.maxIndex = maxIndex;
        a.steward = sp.steward;
        a.sunsetDelay = sunsetDelay;
        a.priorRegistry = sp.prior;
        a.standardCurve = _standardCurveSpec();
        a.hookSalt = sp.salt;
        a.tokenImplementation = sp.tokenImplementation;
        a.roundSetup = FamilyFactory.RoundSetup({
            deployer: address(roundManagerDeployer),
            randomness: address(randomness),
            endTimeout: endTimeout,
            durationScaleDiv: durationScaleDiv
        });
    }

    /// @dev The factory's creation code with its seventeen constructor arguments appended.
    /// Encoding a struct IS encoding its members, so the only difference from what
    /// `new FamilyFactory(...)` would build is the leading offset word, overwritten below with
    /// the remaining length.
    function _factoryCreationCode(FactorySpec memory sp) internal view returns (bytes memory) {
        bytes memory enc = abi.encode(_factoryArgs(sp));
        bytes memory args;
        assembly ("memory-safe") {
            args := add(enc, 0x20)
            mstore(args, sub(mload(enc), 0x20))
        }
        return abi.encodePacked(type(FamilyFactory).creationCode, args);
    }

    /// @dev The CREATE itself. It is raw because `new FamilyFactory(...)` evaluates seventeen
    /// constructor arguments and deploys in ONE frame, and the IR pipeline is a stack slot short
    /// there. It cannot be moved behind an external self-call: that costs a nonce and every
    /// address prediction in {_deployStack} is built on the nonce ladder.
    /// @notice The error the last REFUSED factory deployment reverted with, as its selector.
    /// @dev The CREATE below is raw, so a constructor revert arrives here as returndata rather
    /// than as the reverting `new` expression `vm.expectRevert` used to watch. It is recorded
    /// here and NOT re-raised: {_deployFactory} and {_deployStack} unwind with a zero factory
    /// instead, and the tests that assert a deployment is REFUSED name the error off this. The
    /// cost is that an UNEXPECTED deployment failure surfaces as a zero address downstream rather
    /// than as the constructor's own message; this field is what says why.
    bytes4 internal lastFactoryError;

    function _newFactory(FactorySpec memory sp) internal returns (FamilyFactory) {
        bytes memory code = _factoryCreationCode(sp);
        address deployed;
        bytes4 err;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 0x20), mload(code))
            if iszero(deployed) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                err := mload(ptr)
            }
        }
        lastFactoryError = err;
        return FamilyFactory(deployed);
    }

    function _deployFactory(address router, address _steward, address prior)
        internal
        returns (FamilyFactory f, FamilyHook h)
    {
        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        FactorySpec memory sp;
        sp.router = router;
        sp.steward = _steward;
        sp.prior = prior;
        sp.tokenImplementation = address(new FamilyToken(predictedFactory));
        address hookAddress;
        (hookAddress, sp.salt) = _mineHook(predictedFactory, router);

        f = _newFactory(sp);
        // refused at construction: {lastFactoryError} says why, and the caller asserts on it
        if (address(f) == address(0)) return (f, FamilyHook(address(0)));
        h = f.hook();
        assertEq(address(f), predictedFactory, "factory address prediction");
        assertEq(address(h), hookAddress, "mined hook address");
    }

    /// @dev Adopt the external genesis as canonical index 0. There is no pool and no
    /// curve at index 0 any more; the first pool this protocol owns is link one.
    /// Adoption is part of {FamilyFactory.wire}, the deployment's one-time wiring
    /// step, so there is no separate entry point for anyone to front-run.
    function _adoptGenesis() internal {
        factory.wire();
    }

    /// @dev The registered launch curve of canonical link `j`, for tests that quote against the
    /// range table rather than against pool state.
    function _buildCurve(uint256 j) internal {
        (CurveRange[] memory rs, uint160 p) = _curveOf(j);
        initSqrtPriceX96 = p;
        ranges = rs;
    }

    /// @dev The registered launch curve of link `j`, as the factory built it. Behind an EXTERNAL
    /// call ({CurveQuoter}) so the curve construction is never inlined into a test-base frame.
    function _curveOf(uint256 j) internal returns (CurveRange[] memory, uint160) {
        if (address(curveQuoter) == address(0)) curveQuoter = new CurveQuoter();
        return curveQuoter.build(
            factory.curveSpec(),
            IERC20(roundManager.canonical(j - 1)).totalSupply(),
            SUPPLY,
            factory.TICK_SPACING(),
            Currency.unwrap(roundManager.poolKeyOf(j).currency0) == roundManager.canonical(j)
        );
    }

    /// @dev Point {key}, {poolId} and {token} at canonical link `j`'s pool. Link ONE is the EDGE
    /// pool - $DOLL-quoted, carrying the 1% protocol fee, and (thanks to {DOLL_ADDRESS}) with
    /// $DOLL as `currency0`.
    function _useLink(uint256 j) internal {
        address t = roundManager.canonical(j);
        token = FamilyToken(t);
        key = roundManager.poolKeyOf(j);
        poolId = key.toId();
        IERC20(t).approve(address(swapRouter), type(uint256).max);
        IERC20(t).approve(address(plainRouter), type(uint256).max);
        IERC20(t).approve(address(familyRouter), type(uint256).max);
        _buildCurve(j);
    }

    function _swap(PoolSwapTest r, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        return r.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev The vault's unredeemed claim on the EDGE currency.
    function _feeVaultEdge() internal view returns (uint256) {
        return manager.balanceOf(feeVault, uint256(uint160(address(doll))));
    }

    /// @dev Independent quote of a buy walking the curve description (not the pool state): how
    /// many tokens `parentIn` (net of hook fees) buys starting from the pool's current price.
    /// Assumes the parent is `currency0`, which holds for every link-one pool in this suite.
    function _quoteBuy(uint256 parentIn) internal view returns (uint256 tokensOut) {
        (uint160 sqrtP,,,) = im.getSlot0(poolId);
        for (uint256 i = 0; i < ranges.length && parentIn > 0; i++) {
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(ranges[i].tickUpper);
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(ranges[i].tickLower);
            if (sqrtP <= sqrtLower) continue;
            uint160 from = sqrtP < sqrtUpper ? sqrtP : sqrtUpper;
            uint128 liq = ranges[i].liquidity;
            uint256 costFull = SqrtPriceMath.getAmount0Delta(sqrtLower, from, liq, true);
            if (parentIn >= costFull) {
                tokensOut += SqrtPriceMath.getAmount1Delta(sqrtLower, from, liq, false);
                parentIn -= costFull;
                sqrtP = sqrtLower;
            } else {
                uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(from, liq, parentIn, true);
                tokensOut += SqrtPriceMath.getAmount1Delta(next, from, liq, false);
                parentIn = 0;
            }
        }
    }

    /// @dev NO PROTOCOL CONTRACT HOLDS ETH. Asserted at the end of every test that
    /// inherits this base: the stack is ERC-20 only, so a native balance anywhere in it is a
    /// bug, not an accident.
    function _assertNoEth() internal view {
        assertEq(address(factory).balance, 0, "factory holds ETH");
        assertEq(address(hook).balance, 0, "hook holds ETH");
        assertEq(address(locker).balance, 0, "locker holds ETH");
        assertEq(address(roundManager).balance, 0, "round manager holds ETH");
        assertEq(address(vault).balance, 0, "fee vault holds ETH");
        assertEq(address(bidDeployer).balance, 0, "bid deployer holds ETH");
        assertEq(address(familyRouter).balance, 0, "router holds ETH");
        assertEq(address(lens).balance, 0, "lens holds ETH");
    }

    /// @dev v4 wraps a reverting hook call in `WrappedError(hook, hookSelector, reason, details)`.
    function _expectHookRevert(address hookAddress, bytes4 hookSelector, bytes4 errorSelector) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hookAddress,
                hookSelector,
                abi.encodeWithSelector(errorSelector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}
