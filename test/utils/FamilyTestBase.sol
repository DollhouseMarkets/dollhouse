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
import {DevVestingDeployer} from "../../contracts/DevVesting.sol";
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

/// @dev Shared deployment for the family contracts: a fresh PoolManager, the factory (which
/// deploys the Locker and the CREATE2-mined hook), the v4 test routers, and the genesis curve.
abstract contract FamilyTestBase is Test {
    using StateLibrary for IPoolManager;

    // fee rates are parts-per-million now (L8): 1000 ppm = 10 bps per hop, 10000 ppm = 1%
    uint256 internal constant PPM = 1_000_000;
    uint256 internal constant HOP_FEE_PPM = 1_000; // 0.10% per hop, parent side
    uint256 internal constant PROTOCOL_FEE_PPM = 10_000; // 1% on the ETH edge (genesis only)
    uint256 internal constant TOTAL_FEE_PPM = HOP_FEE_PPM + PROTOCOL_FEE_PPM;
    uint256 internal constant SUPPLY = 1e9 * 1e18;
    /// @dev The genesis curve is the standard shape denominated in this ETH amount (C2).
    uint256 internal constant GENESIS_UNIT = 1000 ether;
    /// @dev Candidate bond schedule (F6): base, doubling every 4 links, capped at 64x base -
    /// the testnet row of docs/DEPLOY_CONSTANTS.md. Tests read {RoundManager.currentBond}.
    uint256 internal constant BOND_WEI = 0.001 ether;
    uint256 internal constant BOND_DOUBLING_EVERY = 4;
    uint256 internal constant BOND_MAX_WEI = 0.064 ether;

    /// @dev The depth cap the stack under test deploys with; 0 (unlimited) unless a test
    /// overrides it before {_deployProtocol}.
    uint256 internal maxIndex;

    /// @dev The sunset delay the stack under test deploys with (audit 2: a constructor parameter,
    /// mainnet 7 days / testnet 1 hour). Tests that exercise the handover override it before
    /// {_deployProtocol}.
    uint64 internal sunsetDelay = 7 days;

    /// @dev The keeper bounty floor the stack under test deploys with (audit 5): the testnet row
    /// of docs/DEPLOY_CONSTANTS.md.
    uint256 internal minBountyWei = 3e14;

    /// @dev The genesis developer allocation the stack under test deploys with: the locked
    /// docs/DEPLOY_CONSTANTS.md values (3% of the genesis supply, 30-day cliff, 12-month linear).
    /// Tests that need a different schedule override these before {_deployProtocol}.
    uint256 internal devAllocationBps = 300;
    uint64 internal vestingCliffS = 30 days;
    uint64 internal vestingDurationS = 365 days;

    /// @dev MECHANISM_v3 sec.3: the random-end wiring the stack under test deploys with. The
    /// default is a {MockRandomnessSource} whose default word is 0, so every round settles at
    /// `T_end == T` and the pre-v3 timing assertions still hold; tests that exercise the random
    /// end set a word, and tests that exercise the fallback simply never fulfil.
    RoundManagerDeployer internal roundManagerDeployer;
    MockRandomnessSource internal randomness;
    uint64 internal randomnessDelayS = 0;
    uint64 internal endTimeout = 30 minutes;
    /// @dev Testnet schedule divisor (1 = the real schedule).
    uint64 internal durationScaleDiv = 1;

    /// @dev The genesis supply actually placed on the curve: the total less the allocation.
    function _genesisTokensForSale() internal view returns (uint256) {
        return SUPPLY - (SUPPLY * devAllocationBps) / 10_000;
    }

    /// @dev The bounty an ETH deployment of `ethValue` pays under the stack's constants (audit
    /// 5): `max(1%, MIN_BOUNTY_WEI)`, capped at 20% of the ETH the call consumes in total.
    function _expectedBounty(uint256 ethValue) internal view returns (uint256 bounty) {
        bounty = (ethValue * bidDeployer.BOUNTY_BPS()) / 10_000;
        if (bounty < bidDeployer.MIN_BOUNTY_WEI()) bounty = bidDeployer.MIN_BOUNTY_WEI();
        uint256 ceiling =
            (ethValue * bidDeployer.MAX_BOUNTY_SHARE_BPS()) / (10_000 - bidDeployer.MAX_BOUNTY_SHARE_BPS());
        if (bounty > ceiling) bounty = ceiling;
    }

    function _bondSchedule() internal view virtual returns (RoundManager.Bond memory) {
        return RoundManager.Bond({base: BOND_WEI, doublingEvery: BOND_DOUBLING_EVERY, max: BOND_MAX_WEI});
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

    receive() external payable {}

    function _deployProtocol() internal {
        _deployProtocol(false);
    }

    /// @dev Deploys the whole stack. The hook's trusted attribution router is either the v4 test
    /// swap router (tranche-1 fee tests, which drive the pool directly) or the real
    /// {FamilyRouter}. Deployment order is fixed so that the hook — whose address is CREATE2
    /// mined and therefore fixed before anything else exists — can be given the FeeVault and
    /// router addresses as predictions.
    function _deployProtocol(bool useFamilyRouter) internal {
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
    }

    /// @dev Deploy ONE complete stack against the PoolManager already in {manager}, with its own
    /// factory, hook, Locker, RoundManager, FeeVault, router and lens. `prior` is the registry
    /// this stack continues (address(0) for a fresh trunk). Note that {feeVault} - the address the
    /// hook was mined against - is a member, so the most recently deployed stack owns it; tests
    /// that hold two stacks must read the vault out of the returned struct.
    function _deployStack(bool useFamilyRouter, address _steward, address prior) internal returns (Stack memory s) {
        // nonce chain: the FamilyToken implementation, the DevVestingDeployer, then the factory
        // (which CREATEs the Locker, the hook and the RoundManager), then the FeeVault, then the
        // BidDeployer it named, then the router and the lens
        // the RoundManager helper and the randomness source are deployed ONCE, before the nonce
        // chain below is read, so a second (continuation) stack reuses them and the predictions
        // are unaffected
        if (address(roundManagerDeployer) == address(0)) roundManagerDeployer = new RoundManagerDeployer();
        if (address(randomness) == address(0)) randomness = new MockRandomnessSource(randomnessDelayS);
        uint256 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 3);
        address predictedBidDeployer = vm.computeCreateAddress(address(this), nonce + 4);
        address predictedRouter = vm.computeCreateAddress(address(this), nonce + 5);
        feeVault = predictedVault;
        bidDeployerAddress = predictedBidDeployer;

        (s.factory, s.hook) = _deployFactory(useFamilyRouter ? predictedRouter : address(swapRouter), _steward, prior);
        s.vault = new FeeVault(s.factory, developer, _creatorBps(), _ancestorBps(), _reinforceBps());
        s.bidDeployer = new BidDeployer(s.vault, minBountyWei);
        s.router = new FamilyRouter(s.factory);
        s.lens = new FamilyLens(s.factory);
        assertEq(address(s.vault), predictedVault, "fee vault address prediction");
        assertEq(address(s.bidDeployer), predictedBidDeployer, "bid deployer address prediction");
        assertEq(address(s.router), predictedRouter, "router address prediction");

        s.locker = s.factory.locker();
        s.roundManager = s.factory.roundManager();
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
    function _deployFactory(address router) internal returns (FamilyFactory f, FamilyHook h) {
        return _deployFactory(router, steward, priorRegistry);
    }

    function _deployFactory(address router, address _steward, address prior)
        internal
        returns (FamilyFactory f, FamilyHook h)
    {
        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        address predictedLocker = vm.computeCreateAddress(predictedFactory, 1);
        FamilyToken tokenImplementation = new FamilyToken(predictedFactory);
        DevVestingDeployer vestingDeployer = new DevVestingDeployer();
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory args =
            abi.encode(address(manager), predictedFactory, predictedLocker, feeVault, router, _hopFeePpm());
        (address hookAddress, bytes32 salt) =
            HookMiner.find(predictedFactory, flags, type(FamilyHook).creationCode, args);

        f = new FamilyFactory(
            IPoolManager(address(manager)),
            feeVault,
            bidDeployerAddress,
            router,
            _hopFeePpm(),
            H_FRAC_WAD,
            H_MIN_FRAC_WAD,
            GENESIS_UNIT,
            _bondSchedule(),
            maxIndex,
            _steward,
            sunsetDelay,
            prior,
            _standardCurveSpec(),
            salt,
            address(tokenImplementation),
            FamilyFactory.DevAllocation({
                deployer: address(vestingDeployer),
                bps: devAllocationBps,
                cliff: vestingCliffS,
                duration: vestingDurationS
            }),
            FamilyFactory.RoundSetup({
                deployer: address(roundManagerDeployer),
                randomness: address(randomness),
                endTimeout: endTimeout,
                durationScaleDiv: durationScaleDiv
            })
        );
        h = f.hook();
        assertEq(address(f), predictedFactory, "factory address prediction");
        assertEq(address(h), hookAddress, "mined hook address");
    }

    /// @dev C2: the genesis curve is no longer supplied by the caller. Read back exactly what
    /// the factory will place, so the tests still have the range table to quote against.
    function _buildCurve() internal {
        delete ranges;
        (CurveRange[] memory rs, uint160 p) = factory.genesisCurve();
        for (uint256 i = 0; i < rs.length; i++) {
            ranges.push(rs[i]);
        }
        initSqrtPriceX96 = p;
    }

    function _createGenesis() internal {
        _buildCurve();
        (address t, PoolKey memory k) = factory.createGenesis("Family Genesis", "FAM", "ipfs://genesis");
        token = FamilyToken(t);
        key = k;
        poolId = k.toId();
        IERC20(t).approve(address(swapRouter), type(uint256).max);
        IERC20(t).approve(address(plainRouter), type(uint256).max);
    }

    function _swap(PoolSwapTest r, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        uint256 value = zeroForOne && amountSpecified < 0 ? uint256(-amountSpecified) : 0;
        if (zeroForOne && amountSpecified > 0) value = 100 ether; // exact-out buy: overpay, refunded
        return r.swap{value: value}(
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

    function _feeVaultEth() internal view returns (uint256) {
        return manager.balanceOf(feeVault, 0);
    }

    /// @dev Independent quote of a buy walking the curve description (not the pool state):
    /// how many tokens `ethIn` (net of hook fees) buys starting from the pool's current price.
    function _quoteBuy(uint256 ethIn) internal view returns (uint256 tokensOut) {
        (uint160 sqrtP,,,) = im.getSlot0(poolId);
        for (uint256 i = 0; i < ranges.length && ethIn > 0; i++) {
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(ranges[i].tickUpper);
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(ranges[i].tickLower);
            if (sqrtP <= sqrtLower) continue;
            uint160 from = sqrtP < sqrtUpper ? sqrtP : sqrtUpper;
            uint128 liq = ranges[i].liquidity;
            uint256 costFull = SqrtPriceMath.getAmount0Delta(sqrtLower, from, liq, true);
            if (ethIn >= costFull) {
                tokensOut += SqrtPriceMath.getAmount1Delta(sqrtLower, from, liq, false);
                ethIn -= costFull;
                sqrtP = sqrtLower;
            } else {
                uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(from, liq, ethIn, true);
                tokensOut += SqrtPriceMath.getAmount1Delta(next, from, liq, false);
                ethIn = 0;
            }
        }
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
