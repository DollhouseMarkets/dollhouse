// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {MockDoll} from "../utils/MockDoll.sol";
import {IFamilyHook} from "../../contracts/interfaces/IFamilyHook.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";
import {EthZap} from "../../contracts/EthZap.sol";

/// @dev The launch venue's factory, as far as this test drives it.
interface IVenueFactory {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    function launchFee() external view returns (uint256);
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);
    function setBuybackEnabled(address token, bool enabled) external;
    function createGraduatedPool(address token) external returns (uint256 positionId);
}

/// @dev The launch venue's bonding curve, as far as this test drives it.
interface IVenueCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function graduated() external view returns (bool);
    function buybackEnabled() external view returns (bool);
}

/// @dev The launch venue's pool hook: the per-pool terms it snapshotted at registration.
interface IVenueHook {
    function launches(PoolId poolId)
        external
        view
        returns (
            bool registered,
            bool memecoinIsCurrency0,
            address memecoin,
            address quoteToken,
            address creator,
            address buybackCreatorRecipient,
            address protocolFeeRecipient,
            uint16 creatorTaxBps,
            uint16 protocolFeeShareBps,
            uint16 buybackBurnBps,
            uint16 hookFeeBps,
            uint16 maxInternalPriceImpactBps,
            bool buybackEnabled
        );
}

/// @dev A `to` that tries to re-enter the zap from inside its ETH payout, records why it was
/// refused, and then accepts the payout.
contract ReenteringRecipient {
    EthZap public immutable zap;
    bytes4 public refusedWith;
    bool public reentered;

    constructor(EthZap _zap) {
        zap = _zap;
    }

    receive() external payable {
        if (msg.sender != address(zap) || refusedWith != bytes4(0)) return;
        try zap.buyWithEth{value: msg.value}(1, 0, address(this), 1, block.timestamp) returns (uint256) {
            reentered = true;
        } catch (bytes memory reason) {
            refusedWith = bytes4(reason);
        }
    }
}

/// @notice {EthZap} against the REAL graduated venue on a fork of chain 4663 mainnet.
///
/// @dev `setUp` replays the launch procedure inside the fork: a native-ETH launch through the
/// venue's factory (launch config 0, 1% creator tax, snipe tax on with no extra exemptions,
/// buyback enabled afterwards), a curve buy that crosses graduation (the curve graduates itself),
/// then `createGraduatedPool`. The graduated token is adopted as canonical index 0 of a fresh
/// stack on the chain's real PoolManager, deployed with the deploy script's constants (bond and
/// bounty floor at the calibrated launch values), link one is crowned through one won round,
/// and the zap is deployed against the graduated pool key. Nothing live is mutated.
///
/// The RPC URL is read from `RPC_MAINNET`; without it every test skips. The fork is taken at the
/// latest block (the public endpoint is not archival). The randomness source is the labelled mock,
/// as in every fork suite here: round timing is not what this file tests.
contract EthZapVenueForkTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant MAINNET_CHAIN_ID = 4663;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant VENUE_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant VENUE_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    /// @dev The runtime size recorded for {VENUE_HOOK} in the on-chain verification survey.
    uint256 internal constant VENUE_HOOK_CODE_SIZE = 15_167;
    /// @dev The runtime code hash first observed at {VENUE_HOOK} by this suite (2026-09-24),
    /// pinned so a later run notices a different contract at that address.
    bytes32 internal constant VENUE_HOOK_CODEHASH = 0xc21b1e6c1b45403e81a581f22ed6d9c747997af1cfdac1b1dc9f4b1d346a10db;
    uint24 internal constant VENUE_FEE = 0;
    int24 internal constant VENUE_TICK_SPACING = 200;
    uint16 internal constant CREATOR_TAX_BPS = 100;
    /// @dev Gross ETH the curve absorbs to graduate is 4.2 / 0.98 = 4.2857; the excess is refunded.
    uint256 internal constant CURVE_BUY = 4.3 ether;
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    // the deploy script's constants, and the calibrated launch bond and bounty floor
    uint256 internal constant DEPLOY_HOP_FEE_PPM = 750;
    uint256 internal constant DEPLOY_CREATOR_BPS = 4_000;
    uint256 internal constant DEPLOY_ANCESTOR_BPS = 5_000;
    uint256 internal constant DEPLOY_REINFORCE_BPS = 5_000;
    uint256 internal constant LAUNCH_BOND = 325_000e18;
    uint256 internal constant LAUNCH_MIN_BOUNTY = 6_600e18;

    bytes32 internal constant HOOK_FEE_COLLECTED = keccak256("HookFeeCollected(bytes32,address,uint256,uint256)");
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    bool internal forked;
    address internal venueToken;
    PoolKey internal venue;
    bytes32 internal initializedPoolId;
    EthZap internal zap;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _hopFeePpm() internal pure override returns (uint256) {
        return DEPLOY_HOP_FEE_PPM;
    }

    function _creatorBps() internal pure override returns (uint256) {
        return DEPLOY_CREATOR_BPS;
    }

    function _ancestorBps() internal pure override returns (uint256) {
        return DEPLOY_ANCESTOR_BPS;
    }

    function _reinforceBps() internal pure override returns (uint256) {
        return DEPLOY_REINFORCE_BPS;
    }

    function _hFracWad() internal pure override returns (uint256) {
        return 0;
    }

    function _hMinFracWad() internal pure override returns (uint256) {
        return 0;
    }

    function _bondSchedule() internal pure override returns (RoundManager.Bond memory) {
        return RoundManager.Bond({base: LAUNCH_BOND, doublingEvery: 4, max: LAUNCH_BOND});
    }

    /// @dev The graduated token cannot be minted: every bond is paid out of what this contract
    /// bought on the curve.
    function _fundDoll(address who, uint256 amount) internal override {
        if (who != address(this)) IERC20(venueToken).transfer(who, amount);
    }

    function setUp() public {
        string memory url = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        assertEq(block.chainid, MAINNET_CHAIN_ID, "forked the wrong chain");
        forked = true;
        vm.deal(address(this), 100 ether);

        _launchAndGraduate();
        _deployStackOnVenueToken();

        venue = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(venueToken),
            fee: VENUE_FEE,
            tickSpacing: VENUE_TICK_SPACING,
            hooks: IHooks(VENUE_HOOK)
        });
        zap = new EthZap(familyRouter, venue);
        vm.deal(alice, 10_000 ether);
    }

    function _requireFork() internal {
        if (!forked) vm.skip(true);
    }

    /// @dev The launch and graduation steps, in the fork.
    function _launchAndGraduate() internal {
        IVenueFactory f = IVenueFactory(VENUE_FACTORY);
        bytes32 econ = f.previewLaunchEconomics(0, address(0));
        IVenueFactory.TokenParams memory p = IVenueFactory.TokenParams({
            name: "Dollhouse",
            symbol: "DOLL",
            logo: "",
            description: "",
            socials: IVenueFactory.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(this),
            creatorTaxBps: CREATOR_TAX_BPS,
            buybackEnabled: false,
            expectedEconomics: econ,
            salt: keccak256("dollhouse.fork.ethzap")
        });
        address curve;
        (venueToken, curve) = f.launchToken{value: f.launchFee()}(p, 0, address(0));
        f.setBuybackEnabled(venueToken, true);
        assertTrue(IVenueCurve(curve).buybackEnabled(), "buyback on");

        IVenueCurve(curve).buy{value: CURVE_BUY}(CURVE_BUY, 0, address(this));
        assertTrue(IVenueCurve(curve).graduated(), "the crossing buy graduates the curve");

        vm.recordLogs();
        f.createGraduatedPool(venueToken);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == POOL_MANAGER && logs[i].topics[0] == IPoolManager.Initialize.selector) {
                initializedPoolId = logs[i].topics[1];
            }
        }
        assertTrue(initializedPoolId != bytes32(0), "no Initialize log from createGraduatedPool");
    }

    /// @dev The fork suites' stack, on the real PoolManager, adopting the graduated token, with
    /// link one crowned.
    function _deployStackOnVenueToken() internal {
        doll = MockDoll(venueToken); // typed as the mock for the base helpers; only ERC-20 calls are made
        minBountyDoll = LAUNCH_MIN_BOUNTY;
        manager = PoolManager(POOL_MANAGER);
        im = IPoolManager(POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);
        plainRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        donateRouter = new PoolDonateTest(manager);
        _useStack(_deployStack(true, steward, priorRegistry));
        _approveDoll();
        _adoptGenesis();
        assertEq(roundManager.canonical(0), venueToken, "the graduated token is index 0");
        _runWinningRound(1, WINNING_BUY);
        assertEq(roundManager.headIndex(), 1, "link one crowned");
    }

    // ---------------------------------------------------------------------------------
    // decoders
    // ---------------------------------------------------------------------------------

    struct VenueFee {
        uint256 n;
        address currency;
        uint256 fee;
        uint256 tax;
    }

    function _venueFee(Vm.Log[] memory logs) internal view returns (VenueFee memory v) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != VENUE_HOOK || logs[i].topics[0] != HOOK_FEE_COLLECTED) continue;
            assertEq(logs[i].topics[1], PoolId.unwrap(zap.venuePoolId()), "fee event for the venue pool");
            v.n++;
            (v.currency, v.fee, v.tax) = abi.decode(logs[i].data, (address, uint256, uint256));
        }
    }

    function _snapshotBps() internal view returns (uint16 hookFeeBps, uint16 taxBps) {
        (bool registered,,,,,,, uint16 t,,, uint16 h,,) = IVenueHook(VENUE_HOOK).launches(zap.venuePoolId());
        assertTrue(registered, "venue pool registered with the hook");
        return (h, t);
    }

    /// @dev Every FamilyHook fee event: its sender and attribution.
    function _familyFees(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 n, address lastSender, uint256 lastAttribution)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != IFamilyHook.FeeAccrued.selector) continue;
            n++;
            lastSender = address(uint160(uint256(logs[i].topics[3])));
            (,, lastAttribution) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(lastSender, address(familyRouter), "every family fee event names the router");
        }
    }

    /// @dev Sum of $DOLL transfers out of the zap, split by recipient.
    function _dollOutOfZap(Vm.Log[] memory logs, address to)
        internal
        view
        returns (uint256 toManager, uint256 toRecipient, uint256 other)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != venueToken || logs[i].topics[0] != TRANSFER) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != address(zap)) continue;
            address dst = address(uint160(uint256(logs[i].topics[2])));
            uint256 amt = abi.decode(logs[i].data, (uint256));
            if (dst == POOL_MANAGER) toManager += amt;
            else if (dst == to) toRecipient += amt;
            else other += amt;
        }
    }

    struct Buy {
        uint256 ethIn;
        uint256 ethRefunded;
        uint256 dollMid;
        uint256 dollRefunded;
        uint256 out;
    }

    function _ethBuy(Vm.Log[] memory logs) internal view returns (Buy memory b) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(zap) || logs[i].topics[0] != EthZap.EthBuy.selector) continue;
            (, b.ethIn, b.ethRefunded, b.dollMid, b.dollRefunded, b.out) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256, uint256));
        }
    }

    function _assertZapClean(address coin) internal view {
        assertEq(address(zap).balance, 0, "zap holds no ETH");
        assertEq(IERC20(venueToken).balanceOf(address(zap)), 0, "zap holds no $DOLL");
        assertEq(IERC20(venueToken).allowance(address(zap), address(familyRouter)), 0, "no $DOLL allowance left");
        if (coin != address(0)) {
            assertEq(IERC20(coin).balanceOf(address(zap)), 0, "zap holds no link coin");
            assertEq(IERC20(coin).allowance(address(zap), address(familyRouter)), 0, "no link allowance left");
        }
    }

    // ---------------------------------------------------------------------------------
    // tests
    // ---------------------------------------------------------------------------------

    /// @notice The zap swaps exactly the pool the graduation initialized, and the venue hook is
    /// the contract the survey recorded (runtime size) with the pinned code hash.
    function testFork_venueIdentity() public {
        _requireFork();
        assertEq(PoolId.unwrap(zap.venuePoolId()), initializedPoolId, "zap pool id == Initialize log id");
        assertEq(PoolId.unwrap(venue.toId()), initializedPoolId, "the venue key hashes to the Initialize id");
        assertEq(VENUE_HOOK.code.length, VENUE_HOOK_CODE_SIZE, "venue hook runtime size");
        assertEq(VENUE_HOOK.codehash, VENUE_HOOK_CODEHASH, "venue hook runtime code hash");
        console2.log("fork block", block.number);
        console2.log("venue hook code size", VENUE_HOOK.code.length);
        (uint16 h, uint16 t) = _snapshotBps();
        assertEq(t, CREATOR_TAX_BPS, "creator tax snapshotted");
        console2.log("snapshotted hookFeeBps", h);
        console2.log("snapshotted creatorTaxBps", t);
        assertGt(im.getLiquidity(zap.venuePoolId()), 0, "venue liquidity");
    }

    /// @notice ETH -> $DOLL (venue, fee in $DOLL) -> link one (router-attributed), zap left clean.
    function testFork_buyWithEthLinkOne() public {
        _requireFork();
        (uint16 hookFeeBps, uint16 taxBps) = _snapshotBps();
        address link1 = roundManager.canonical(1);
        uint256 before = IERC20(link1).balanceOf(alice);

        vm.recordLogs();
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 out = zap.buyWithEth{value: 0.05 ether}(1, 1, alice, 1, block.timestamp + 1 hours);
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        VenueFee memory v = _venueFee(logs);
        assertEq(v.n, 1, "one venue fee event");
        assertEq(v.currency, venueToken, "venue fee charged in $DOLL on a buy");
        Buy memory b = _ethBuy(logs);
        uint256 gross = b.dollMid + v.fee + v.tax;
        assertEq(v.fee, (gross * hookFeeBps) / 10_000, "venue hook fee at the snapshotted bps");
        assertEq(v.tax, (gross * taxBps) / 10_000, "creator tax at the snapshotted bps");

        (uint256 nFam,, uint256 attribution) = _familyFees(logs);
        assertGt(nFam, 0, "family hook charged");
        assertEq(attribution, 1, "terminal index 1");

        (uint256 routerSpend, uint256 refunded, uint256 other) = _dollOutOfZap(logs, alice);
        assertEq(other, 0, "no $DOLL anywhere else");
        assertEq(b.dollMid, routerSpend + b.dollRefunded, "dollMid == router spend + dollRefunded");
        assertEq(refunded, b.dollRefunded, "refund reported == refund sent");
        assertEq(b.ethIn, 0.05 ether, "ethIn");
        assertEq(b.ethRefunded, 0, "venue absorbed all the ETH");
        assertEq(b.out, out, "event out == returned out");
        assertEq(IERC20(link1).balanceOf(alice) - before, out, "alice received the link coin");
        _assertZapClean(link1);

        console2.log("buy gas", g);
        console2.log("venue fee / tax ($DOLL wei)", v.fee, v.tax);
        console2.log("dollMid / routerSpend", b.dollMid, routerSpend);
    }

    /// @notice link one -> $DOLL (router) -> ETH (venue, fee in ETH), paid to `to`, minEthOut held.
    function testFork_sellForEthLinkOne() public {
        _requireFork();
        (uint16 hookFeeBps, uint16 taxBps) = _snapshotBps();
        address link1 = roundManager.canonical(1);
        vm.prank(alice);
        uint256 bought = zap.buyWithEth{value: 0.05 ether}(1, 1, alice, 1, block.timestamp + 1 hours);
        vm.prank(alice);
        IERC20(link1).approve(address(zap), type(uint256).max);

        // the quote: run it, read it, roll it back
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 quoted = zap.sellForEth(1, bought, 0, bob, 1, block.timestamp + 1 hours);
        vm.revertToState(snap);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EthZap.InsufficientOutput.selector, quoted, quoted + 1));
        zap.sellForEth(1, bought, quoted + 1, bob, 1, block.timestamp + 1 hours);

        uint256 bobBefore = bob.balance;
        vm.recordLogs();
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 ethOut = zap.sellForEth(1, bought, quoted, bob, 1, block.timestamp + 1 hours);
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ethOut, quoted, "quoted == actual");
        assertEq(bob.balance - bobBefore, ethOut, "to paid in ETH");
        VenueFee memory v = _venueFee(logs);
        assertEq(v.n, 1, "one venue fee event");
        assertEq(v.currency, address(0), "venue fee charged in ETH on a sell");
        uint256 gross = ethOut + v.fee + v.tax;
        assertEq(v.fee, (gross * hookFeeBps) / 10_000, "venue hook fee at the snapshotted bps");
        assertEq(v.tax, (gross * taxBps) / 10_000, "creator tax at the snapshotted bps");
        (uint256 nFam,, uint256 attribution) = _familyFees(logs);
        assertGt(nFam, 0, "family hook charged");
        assertEq(attribution, 1, "terminal index 1");
        assertEq(IERC20(link1).balanceOf(alice), 0, "alice sold everything");
        _assertZapClean(link1);

        console2.log("sell gas", g);
        console2.log("sell ethOut / venue fee / tax (wei)", ethOut, v.fee, v.tax);
    }

    /// @notice A candidate buy and sell through the zap while round two is trading.
    function testFork_candidateBuyAndSell() public {
        _requireFork();
        Cand memory c = _registerCandidate(makeAddr("creator"), "CAND2");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(uint256(tradingStart) + 10);

        vm.recordLogs();
        vm.prank(alice);
        uint256 out = zap.buyCandidateWithEth{value: 0.02 ether}(c.id, 1, alice, 3, block.timestamp + 1 hours);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(out, 0, "candidate bought");
        assertEq(IERC20(c.token).balanceOf(alice), out, "alice holds the candidate");
        assertEq(_venueFee(logs).currency, venueToken, "venue fee in $DOLL");
        (uint256 nFam,,) = _familyFees(logs);
        assertGt(nFam, 0, "family fees router-attributed");
        _assertZapClean(c.token);

        vm.prank(alice);
        IERC20(c.token).approve(address(zap), type(uint256).max);
        uint256 aliceEth = alice.balance;
        vm.prank(alice);
        uint256 ethOut = zap.sellCandidateForEth(c.id, out, 1, alice, 3, block.timestamp + 1 hours);
        assertGt(ethOut, 0, "candidate sold for ETH");
        assertEq(alice.balance - aliceEth, ethOut, "ETH paid");
        assertEq(IERC20(c.token).balanceOf(alice), 0, "candidate sold out");
        _assertZapClean(c.token);
        console2.log("candidate out / ethOut", out, ethOut);
    }

    /// @notice The venue's liquidity cannot bind: the graduation position is full range, so the
    /// ETH it takes to push the price to the swap limit exceeds what a v4 delta can carry. The
    /// ETH-refund branch is unreachable on this pool while that position stands; a very large buy
    /// fills in full and leaves the zap clean.
    function testFork_hugeBuyFillsInFull() public {
        _requireFork();
        PoolId id = zap.venuePoolId();
        (uint160 sqrtP,,,) = im.getSlot0(id);
        uint128 liq = im.getLiquidity(id);
        uint256 ethToLimit = SqrtPriceMath.getAmount0Delta(TickMath.MIN_SQRT_PRICE + 1, sqrtP, liq, true);
        assertGt(ethToLimit, uint256(uint128(type(int128).max)), "the limit is out of reach of any delta");
        console2.log("ETH (wei) needed to reach the price limit", ethToLimit);

        uint256 huge = 1_000 ether;
        address link1 = roundManager.canonical(1);
        uint256 aliceEth = alice.balance;
        uint256 aliceDoll = IERC20(venueToken).balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = zap.buyWithEth{value: huge}(1, 1, alice, 1, block.timestamp + 1 hours);
        Buy memory b = _ethBuy(vm.getRecordedLogs());
        assertEq(b.ethRefunded, 0, "no ETH refund: the venue absorbed it all");
        assertEq(aliceEth - alice.balance, huge, "alice paid exactly msg.value");
        assertEq(IERC20(venueToken).balanceOf(alice) - aliceDoll, b.dollRefunded, "any $DOLL residue reached to");
        assertGt(out, 0, "link one bought");
        _assertZapClean(link1);
        console2.log("huge buy dollMid / dollRefunded", b.dollMid, b.dollRefunded);
    }

    /// @notice A `to` that re-enters from its ETH payout is refused with Reentrancy.
    function testFork_reenteringRecipientRefused() public {
        _requireFork();
        address link1 = roundManager.canonical(1);
        vm.prank(alice);
        uint256 bought = zap.buyWithEth{value: 0.05 ether}(1, 1, alice, 1, block.timestamp + 1 hours);
        ReenteringRecipient r = new ReenteringRecipient(zap);
        vm.startPrank(alice);
        IERC20(link1).approve(address(zap), type(uint256).max);
        uint256 ethOut = zap.sellForEth(1, bought, 1, address(r), 1, block.timestamp + 1 hours);
        vm.stopPrank();
        assertEq(r.refusedWith(), EthZap.Reentrancy.selector, "re-entry refused with Reentrancy");
        assertFalse(r.reentered(), "no nested buy");
        assertEq(address(r).balance, ethOut, "the payout itself still arrived");
        assertEq(IERC20(link1).balanceOf(address(r)), 0, "nothing bought by the re-entry");
        _assertZapClean(link1);
    }

    /// @notice A preview of a buy (the call run and rolled back, as an `eth_call` does) returns
    /// what the same call then delivers in the same block.
    function testFork_previewEqualsActual() public {
        _requireFork();
        uint256 blk = block.number;
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 previewed = zap.buyWithEth{value: 0.03 ether}(1, 1, alice, 1, block.timestamp + 1 hours);
        vm.revertToState(snap);
        assertEq(block.number, blk, "same block");
        vm.prank(alice);
        uint256 actual = zap.buyWithEth{value: 0.03 ether}(1, previewed, alice, 1, block.timestamp + 1 hours);
        assertEq(actual, previewed, "previewed == actual");
        console2.log("previewed / actual", previewed, actual);
    }
}
