// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {stdStorage, StdStorage, Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FamilyLens} from "../contracts/FamilyLens.sol";
import {BidDeployer} from "../contracts/BidDeployer.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice FORWARD CONTINUATION (README "Upgrade model"): a v2 deployment that continues the
/// trunk from v1's head instead of forking it. Two complete stacks live in the same PoolManager;
/// v2 owns indices 2.. and answers everything at or below index 1 by delegating to v1's registry.
///
/// What is pinned down here:
///   - v2 starts at v1's head (index + token) and can never create a genesis of its own;
///   - `canonical/indexOf/parentOf/creatorOf/isCanonical/poolKeyOf/genesisToken` delegate;
///   - the first v2 candidate is quoted in v1's head token - a parent the v2 hook and Locker
///     have never seen, and only ever handle as a plain ERC-20;
///   - a canonical route ETH -> #0 -> #1 -> #2 crosses both versions' pools in one unlock;
///   - v2's payouts for v1-era generations are placed by v1's OWN FeeVault and Locker, because
///     v1's hook accepts liquidity from nobody else;
///   - a v3 continuing v2 resolves index 0 and 1 through TWO registry hops.
contract ContinuationTest is RoundTestBase {
    using StateLibrary for IPoolManager;
    using stdStorage for StdStorage;

    uint256 internal constant WINNING_BUY = 6_100_000e18;
    address internal constant STEWARD = address(0x57E4A2D);
    Currency internal constant ETH = Currency.wrap(address(0));

    Stack internal v1;
    Stack internal v2;

    address internal genesis; // canonical #0, created by v1
    address internal link1; // canonical #1, created by v1
    address internal link2; // canonical #2, created by v2

    function setUp() public {
        steward = STEWARD;

        // ---- v1: genesis plus one succession -> head is #1 ----
        _setUpFamily();
        v1 = _currentStack();
        _buyGenesis(5 ether);
        genesis = address(token);
        link1 = _runWinningRound(1, WINNING_BUY).token;
        assertEq(v1.roundManager.headIndex(), 1, "v1 head is #1");

        // ---- v2: a complete second stack that CONTINUES v1 ----
        v2 = _deployStack(true, STEWARD, address(v1.roundManager));
        _useStack(v2);
    }

    // ---------------------------------------------------------------------------------
    // construction
    // ---------------------------------------------------------------------------------

    function test_v2StartsAtTheInheritedHead() public view {
        assertEq(v2.roundManager.priorRegistry(), address(v1.roundManager));
        assertEq(v2.roundManager.priorIndex(), 1, "v1's head index at construction");
        assertEq(v2.roundManager.headIndex(), 1, "v2 starts where v1 stopped");
        assertEq(v2.roundManager.head(), link1);
        assertEq(v2.roundManager.headToken(), link1);
        assertEq(v2.roundManager.roundCount(), 0, "v2 has run no round of its own yet");
        assertTrue(v2.vault.isContinuation(), "the vault knows it is a continuation");
        assertFalse(v1.vault.isContinuation());
    }

    function test_v2CannotCreateAGenesis() public {
        vm.expectRevert(FamilyFactory.ContinuationHasGenesis.selector);
        v2.factory.createGenesis("FAKE", "FAKE", "");

        // ...and not through the RoundManager either
        vm.prank(address(v2.factory));
        vm.expectRevert(RoundManager.GenesisAlreadyRegistered.selector);
        v2.roundManager.registerGenesis(address(0xDEAD), key, address(this));
    }

    // ---------------------------------------------------------------------------------
    // delegated reads
    // ---------------------------------------------------------------------------------

    function test_delegatedReadsForPriorIndices() public view {
        // ownership: v2 owns nothing at or below index 1
        assertEq(v2.roundManager.registryOf(0), address(v1.roundManager));
        assertEq(v2.roundManager.registryOf(1), address(v1.roundManager));
        assertEq(v2.roundManager.registryOf(2), address(v2.roundManager), "index 2 is v2's to write");
        assertFalse(v2.roundManager.ownsToken(genesis), "v2 never wrote genesis");
        assertTrue(v1.roundManager.ownsToken(genesis));

        // index-keyed
        assertEq(v2.roundManager.canonical(0), genesis);
        assertEq(v2.roundManager.canonical(1), link1);
        assertEq(v2.roundManager.genesisToken(), genesis);
        assertEq(v2.factory.genesisToken(), genesis, "the v2 factory reports the trunk's genesis");
        assertEq(
            PoolId.unwrap(v2.roundManager.poolKeyOf(0).toId()),
            PoolId.unwrap(v1.roundManager.poolKeyOf(0).toId()),
            "pool key #0 delegates"
        );
        assertEq(
            PoolId.unwrap(v2.roundManager.poolKeyOf(1).toId()),
            PoolId.unwrap(v1.roundManager.poolKeyOf(1).toId()),
            "pool key #1 delegates"
        );
        assertEq(address(v2.roundManager.poolKeyOf(1).hooks), address(v1.hook), "a delegated key carries v1's hook");

        // token-keyed
        assertEq(v2.roundManager.indexOf(genesis), 0);
        assertEq(v2.roundManager.indexOf(link1), 1);
        assertTrue(v2.roundManager.isCanonical(genesis));
        assertTrue(v2.roundManager.isCanonical(link1));
        assertEq(v2.roundManager.parentOf(link1), genesis);
        assertEq(v2.roundManager.parentOf(genesis), address(0), "genesis has no parent");
        assertEq(v2.roundManager.creatorOf(genesis), v1.roundManager.creatorOf(genesis));
        assertEq(v2.roundManager.creatorOf(link1), v1.roundManager.creatorOf(link1));

        // a token nobody in the chain knows reads as empty rather than reverting
        assertFalse(v2.roundManager.isCanonical(address(0xFFFF)));
        assertEq(v2.roundManager.indexOf(address(0xFFFF)), 0);
        assertEq(v2.roundManager.parentOf(address(0xFFFF)), address(0));
    }

    // ---------------------------------------------------------------------------------
    // a round in v2, quoted in v1's token
    // ---------------------------------------------------------------------------------

    /// @notice The first v2 candidate is paired against an ERC-20 that v2's own factory never
    /// deployed. The v2 hook takes its parent from the per-pool registration the factory writes,
    /// not from any "is this one of mine" check, so a foreign parent needs no special case.
    function test_v2RoundCrownsLinkTwoQuotedInV1sHead() public {
        _crownLink2();

        assertEq(v2.roundManager.headIndex(), 2, "v2 wrote index 2");
        assertEq(v2.roundManager.head(), link2);
        assertEq(v2.roundManager.canonical(2), link2);
        assertEq(v2.roundManager.parentOf(link2), link1, "#2's parent is v1's #1");
        assertEq(v2.roundManager.registryOf(2), address(v2.roundManager));
        assertTrue(v2.roundManager.ownsToken(link2));

        // v1 is completely untouched by v2's succession
        assertEq(v1.roundManager.headIndex(), 1, "v1's own head never moved");
        assertEq(v1.roundManager.head(), link1);
        assertEq(v1.roundManager.canonical(2), address(0), "v1 knows nothing about #2");

        // the pool really does pair #2 against a v1-factory token, under v2's hook
        PoolKey memory k2 = v2.roundManager.poolKeyOf(2);
        address c0 = Currency.unwrap(k2.currency0);
        address c1 = Currency.unwrap(k2.currency1);
        assertTrue((c0 == link2 && c1 == link1) || (c1 == link2 && c0 == link1), "#2 is quoted in #1");
        assertEq(address(k2.hooks), address(v2.hook), "#2's pool is a v2 pool");
        assertTrue(v1.roundManager.ownsToken(link1), "the parent was minted by v1's factory");

        // and the parent side of the round really was v1's head supply
        RoundManager.Round memory r = v2.roundManager.roundInfo(1);
        assertEq(r.parentToken, link1);
        assertEq(r.parentIndex, 1);
        assertEq(r.hUsed, (IERC20(link1).totalSupply() * H_FRAC_WAD) / 1e18, "H re-based on #1's supply");
    }

    // ---------------------------------------------------------------------------------
    // F1: lazy head adoption
    // ---------------------------------------------------------------------------------

    /// @notice A continuation deployment may not open a round of its own until the version it
    /// continues has really stopped: sunset EFFECTIVE, this contract named as its successor, and
    /// its last round finalized. Anything else would let two live registries write the same
    /// canonical index.
    function test_v2CannotOpenARoundBeforeTheHandover() public {
        uint256 bond = v2.roundManager.currentBond();
        vm.deal(address(0xA11CE), bond * 4);

        // nothing announced yet
        vm.prank(address(0xA11CE));
        vm.expectRevert(RoundManager.PriorNotHandedOver.selector);
        v2.factory.registerCandidate{value: bond}("EARLY", "EARLY", "");

        // announced, but the 7-day delay has not run out
        vm.prank(STEWARD);
        v1.roundManager.announceSunset(address(v2.roundManager));
        vm.prank(address(0xA11CE));
        vm.expectRevert(RoundManager.PriorNotHandedOver.selector);
        v2.factory.registerCandidate{value: bond}("EARLY", "EARLY", "");

        // ...and v1's LAST round - opened before the sunset landed, as the procedure allows -
        // is still running, so its head is not final yet
        _useStack(v1);
        _registerCandidate(address(0xB0B), "LAST");
        _useStack(v2);
        vm.warp(v1.roundManager.sunsetAt());
        assertTrue(v1.roundManager.isSunsetEffective());
        assertFalse(v1.roundManager.isIdle(), "v1 is mid-round");
        vm.prank(address(0xA11CE));
        vm.expectRevert(RoundManager.PriorNotHandedOver.selector);
        v2.factory.registerCandidate{value: bond}("EARLY", "EARLY", "");
        assertFalse(v2.roundManager.adopted(), "and nothing was adopted along the way");
    }

    /// @notice THE TWO-TRUNK BUG (audit F1). v1 keeps crowning links after v2 is deployed - the
    /// designed upgrade explicitly leaves it running for the 7-day delay plus its in-flight
    /// round. The old code read the head in v2's CONSTRUCTOR, so every v1 win after that forked
    /// the chain: two different tokens at canonical index 2. With lazy adoption v2 reads the head
    /// at the moment v1 can no longer move, so it adopts the LATER head and the trunk stays one.
    function test_v2AdoptsTheHeadV1CrownedAfterV2WasDeployed() public {
        // v1 crowns #2 AFTER v2 exists, exactly as the sunset procedure allows
        _useStack(v1);
        address lateLink = _runWinningRound(1, WINNING_BUY).token;
        assertEq(v1.roundManager.headIndex(), 2, "v1 crowned another link after v2's deploy");

        // v2 still delegates every read, so it already sees the later head
        assertEq(v2.roundManager.headIndex(), 2, "v2 delegates its head to the live v1");
        assertEq(v2.roundManager.head(), lateLink);
        assertFalse(v2.roundManager.adopted());

        // hand over, then run v2's first round
        _useStack(v2);
        _sunsetV1();
        address v2Link = _runWinningRound(1, WINNING_BUY).token;

        assertTrue(v2.roundManager.adopted(), "v2 adopted at the first round it opened");
        assertEq(v2.roundManager.priorIndex(), 2, "and it adopted v1's LATE head, not its deploy-time one");
        assertEq(v2.roundManager.canonical(2), lateLink, "index 2 is v1's late link, by delegation");
        assertEq(v2.roundManager.canonical(3), v2Link, "v2's own link is index 3");
        assertEq(v2.roundManager.headIndex(), 3);

        // THE PROBE: there is exactly one token at every index of the trunk
        assertEq(v1.roundManager.canonical(2), v2.roundManager.canonical(2), "one canonical #2, not two");
        assertEq(v1.roundManager.canonical(3), address(0), "v1 never wrote #3");
        assertEq(v2.roundManager.parentOf(v2Link), lateLink, "v2's link hangs off v1's late head");
    }

    /// @notice AUDIT 2 - THE UNADOPTED INTERMEDIATE. v1 sunsets in favour of v2, v2 never opens
    /// a round (so it never adopts and owns nothing), and a v3 is deployed on top of it. If v2
    /// could hand a trunk it does not own to v3, v3 would start numbering above a head that v1 -
    /// still live, still crowning inside its in-flight round - can still move: two tokens at the
    /// same index. `announceSunset` therefore refuses on an unadopted continuation, and adoption
    /// refuses to walk through one.
    function test_v3CannotAdoptThroughAnUnadoptedV2() public {
        Stack memory v3 = _deployStack(true, STEWARD, address(v2.roundManager));

        // v1 hands over to v2, but v2 never opens a round: it is still delegating everything
        _sunsetV1();
        assertFalse(v2.roundManager.adopted(), "v2 owns nothing yet");
        assertTrue(v2.roundManager.isIdle(), "...and it reports idle, because it has no rounds");

        // so it cannot hand anything on
        vm.prank(STEWARD);
        vm.expectRevert(RoundManager.NotAdopted.selector);
        v2.roundManager.announceSunset(address(v3.roundManager));

        // and with no sunset behind it, v3 cannot open a round either
        uint256 bond = v3.roundManager.currentBond();
        vm.deal(address(0xA11CE), bond * 4);
        vm.prank(address(0xA11CE));
        vm.expectRevert(RoundManager.PriorNotHandedOver.selector);
        v3.factory.registerCandidate{value: bond}("EARLY", "EARLY", "");

        // the LEGAL order: v2 adopts by running its own round, then hands over to v3
        _useStack(v2);
        _crownLink2();
        assertTrue(v2.roundManager.adopted());
        vm.prank(STEWARD);
        v2.roundManager.announceSunset(address(v3.roundManager));
        vm.warp(v2.roundManager.sunsetAt());
        _useStack(v3);
        address link3 = _runWinningRound(1, WINNING_BUY).token;

        // ONE token per index across all three registries
        assertEq(v3.roundManager.canonical(2), link2, "index 2 is v2's link, by delegation");
        assertEq(v3.roundManager.canonical(3), link3);
        assertEq(v2.roundManager.canonical(3), address(0), "v2 never wrote #3");
        assertEq(v1.roundManager.canonical(2), address(0), "v1 never wrote #2");
        assertEq(v3.roundManager.headIndex(), 3);
    }

    /// @notice AUDIT 2, the transitive half: even a registry that IS sunset, idle and names the
    /// caller as its successor cannot be adopted through while it is an unadopted continuation.
    /// Pinned with a stand-in prior that reports exactly that state.
    function test_adoptionRefusesASunsetButUnadoptedPrior() public {
        UnadoptedPrior fake = new UnadoptedPrior(address(v1.roundManager), link1);
        Stack memory v3 = _deployStack(true, STEWARD, address(fake));
        fake.setSuccessor(address(v3.roundManager));

        uint256 bond = v3.roundManager.currentBond();
        vm.deal(address(0xA11CE), bond * 4);
        vm.prank(address(0xA11CE));
        vm.expectRevert(RoundManager.PriorNotAdopted.selector);
        v3.factory.registerCandidate{value: bond}("EARLY", "EARLY", "");

        // the SAME state, with the prior reporting that it adopted, is accepted
        fake.setAdopted(true);
        vm.prank(address(0xA11CE));
        v3.factory.registerCandidate{value: bond}("OK", "OK", "");
        assertTrue(v3.roundManager.adopted(), "an adopted prior hands the trunk over");
    }

    /// @notice AUDIT 2 - the sunset delay is a DEPLOY CONSTANT (mainnet 7 days, testnet as little
    /// as an hour), so a testnet run can exercise the whole handover without a seven-day wait.
    function test_sunsetDelayIsAConstructorParameter() public {
        assertEq(v1.roundManager.sunsetDelay(), 7 days, "the default stack deploys with 7 days");

        sunsetDelay = 1 hours;
        Stack memory fast = _deployStack(true, STEWARD, address(0));
        assertEq(fast.roundManager.sunsetDelay(), 1 hours);

        uint256 announcedAt = block.timestamp;
        vm.prank(STEWARD);
        fast.roundManager.announceSunset(address(v2.roundManager));
        assertEq(fast.roundManager.sunsetAt(), announcedAt + 1 hours, "the parameter, not the constant");
        vm.warp(announcedAt + 1 hours - 1);
        assertFalse(fast.roundManager.isSunsetEffective());
        vm.warp(announcedAt + 1 hours);
        assertTrue(fast.roundManager.isSunsetEffective(), "sunset after an hour, not a week");

        // ...but never shorter than the floor: an announcement has to stay a public warning
        sunsetDelay = 1 hours - 1;
        vm.expectRevert(RoundManager.BadSunsetDelay.selector);
        _deployStack(true, STEWARD, address(0));
        sunsetDelay = 7 days;
    }

    // ---------------------------------------------------------------------------------
    // routing across versions
    // ---------------------------------------------------------------------------------

    /// @notice ETH -> #0 (v1 pool) -> #1 (v1 pool) -> #2 (v2 pool), in one unlock, driven by the
    /// v2 router off delegated pool keys. The hook address differs per leg; the PoolManager does
    /// not care, and neither does the router.
    function test_routeFromEthAcrossBothVersions() public {
        _crownLink2();

        assertEq(address(v2.roundManager.poolKeyOf(0).hooks), address(v1.hook), "leg 1 is a v1 pool");
        assertEq(address(v2.roundManager.poolKeyOf(1).hooks), address(v1.hook), "leg 2 is a v1 pool");
        assertEq(address(v2.roundManager.poolKeyOf(2).hooks), address(v2.hook), "leg 3 is a v2 pool");

        uint256 ethBefore = address(this).balance;
        uint256 before2 = IERC20(link2).balanceOf(address(this));
        uint256 g = gasleft();
        uint256 out = v2.router.buyExactIn{value: 1 ether}(2, 1, address(this), 3);
        emit log_named_uint("cross-version 3-hop route (ETH -> #0 -> #1 -> #2) gas", g - gasleft());

        assertGt(out, 0, "the cross-version route delivered #2");
        assertEq(IERC20(link2).balanceOf(address(this)) - before2, out, "delivered to `to`");
        assertEq(ethBefore - address(this).balance, 1 ether, "exact-in spends exactly msg.value");
        assertEq(address(v2.router).balance, 0, "no ETH stranded in the router");
        assertEq(IERC20(genesis).balanceOf(address(v2.router)), 0, "no #0 stranded");
        assertEq(IERC20(link1).balanceOf(address(v2.router)), 0, "no #1 stranded");

        // both versions' vaults were paid, each by its own hook
        assertGt(v1.vault.devBalance(), 0, "v1's vault took the ETH-edge fee on its own pool");
        assertGt(v2.vault.reinforcementBalance(link1), 0, "v2's vault took the hop fee on its own pool");

        // and back out again
        IERC20(link2).approve(address(v2.router), type(uint256).max);
        uint256 back = v2.router.sellExactIn(2, out, 1, address(this), 3);
        assertGt(back, 0, "sold back to ETH across both versions");
        assertLt(back, 1 ether, "a round trip still cannot be profitable");
    }

    function test_lensChainViewSpansVersions() public {
        _crownLink2();
        FamilyLens.LinkView[] memory links = v2.lens.chainView(0, 2);
        assertEq(links.length, 3, "the lens walks the whole trunk, not just v2's part");
        assertEq(links[0].token, genesis);
        assertEq(links[1].token, link1);
        assertEq(links[2].token, link2);
        assertEq(links[1].parent, genesis);
        assertEq(links[2].parent, link1);
        assertEq(links[0].creator, v1.roundManager.creatorOf(genesis));
        assertEq(links[2].creator, v2.roundManager.creatorOf(link2));
        for (uint256 i = 0; i < 3; i++) {
            assertGt(links[i].spotSqrtPriceX96, 0, "every link has a live pool");
        }
    }

    // ---------------------------------------------------------------------------------
    // cross-version payouts
    // ---------------------------------------------------------------------------------

    /// @notice The LIVE cross-version payout: v2's own forfeited bonds are genesis-generation
    /// ETH, and genesis is a v1 pool. v2's Locker may not add liquidity there, so v2's FeeVault
    /// hands the ETH to v1's FeeVault through {FeeVault.depositExternalBid} and v1's own Locker
    /// places the bid. Nothing is stranded and the beneficiary is still generation 0.
    function test_v2GenesisBidIsPlacedByV1sVault() public {
        _crownLink2();
        _warmOracles();

        uint256 earmark = v2.vault.genesisBidEarmark();
        assertGt(earmark, 0, "v2's losing bonds are generation-0 ETH");
        assertEq(v1.vault.genesisBidEarmark(), 0, "and they are held by v2, not v1");

        PoolId gid = v1.roundManager.poolKeyOf(0).toId();
        uint256 v1EthBefore = address(v1.bidDeployer).balance;

        vm.expectEmit(true, true, false, false, address(v2.bidDeployer));
        emit BidDeployer.AncestorForwarded(0, address(v1.bidDeployer), 0);
        vm.recordLogs();
        uint256 deposited = v2.bidDeployer.deployGenesisBid();

        assertGt(deposited, 0, "the bid was placed");
        _assertBidPlacedBy(address(v1.locker), gid);
        // H2: the draw is partial, bounded by the genesis pool's active-bucket size cap
        assertLt(v2.vault.genesisBidEarmark(), earmark, "v2's earmark was drawn down");
        assertEq(address(v1.bidDeployer).balance, v1EthBefore, "v1's deployer kept nothing: it only placed the bid");
        _assertSolvent();
    }

    /// @notice The same rule for a non-genesis prior-version generation: `deployAncestor(1)` on
    /// v2 buys the keeper's #0 tokens and forwards them to v1's vault, which places the bid in
    /// v1's #1 pool.
    ///
    /// @dev Generation 1's ETH sleeve is SEEDED here rather than earned. A continuation stack has
    /// no ETH-paired pool of its own, so `FamilyHook` charges it no protocol fee and its Fenwick
    /// sleeve never fills from its own swaps (see the note in docs/DEPLOY_CONSTANTS.md). The
    /// forwarding path below is what matters and is exercised for real.
    function test_deployAncestorForAPriorVersionGenerationGoesThroughV1sVault() public {
        _crownLink2();
        _warmOracles();

        // seed generation 1's immediate-parent ETH sleeve in v2's vault
        uint256 seed = 2 ether;
        vm.deal(address(v2.vault), address(v2.vault).balance + seed);
        stdstore.target(address(v2.vault)).sig("reinforcementEth(uint256)").with_key(uint256(1)).checked_write(seed);
        stdstore.target(address(v2.vault))
            .sig("ledgerTotal(address)")
            .with_key(address(0))
            .checked_write(v2.vault.ledgerTotal(Currency.wrap(address(0))) + seed);
        // the handover has already sent some of v1's edge here, so the sleeve is the seed PLUS
        // whatever generation 1 has genuinely earned
        assertGe(v2.vault.claimableEth(1), seed);

        // the keeper brings generation 0's token (a v1 token) and is paid out of that sleeve
        uint256 cap = v2.bidDeployer.bidCap(1);
        uint256 maxParent = v2.bidDeployer.maxParentForDeploy(1);
        uint256 amount = cap < maxParent ? cap : maxParent;
        assertGt(amount, 0, "there is room for a bid");
        address keeper = address(0xC0FFEE);
        deal(genesis, keeper, amount);

        PoolId id1 = v1.roundManager.poolKeyOf(1).toId();
        uint256 keeperEthBefore = keeper.balance;

        vm.startPrank(keeper);
        IERC20(genesis).approve(address(v2.bidDeployer), amount);
        vm.expectEmit(true, true, false, false, address(v2.bidDeployer));
        emit BidDeployer.AncestorForwarded(1, address(v1.bidDeployer), 0);
        vm.recordLogs();
        uint256 deposited = v2.bidDeployer.deployAncestor(1, amount);
        vm.stopPrank();

        assertEq(deposited, amount, "the whole parent amount went into the bid");
        _assertBidPlacedBy(address(v1.locker), id1);
        assertGt(keeper.balance, keeperEthBefore, "the keeper was paid in ETH plus the bounty");
        assertEq(IERC20(genesis).balanceOf(address(v2.bidDeployer)), 0, "v2's deployer forwarded everything");
        assertEq(IERC20(genesis).balanceOf(address(v1.bidDeployer)), 0, "v1's deployer kept nothing either");
        _assertSolvent();
    }

    /// @notice {depositExternalBid} is permissionless, but only for links of the version that
    /// owns the pool: v2 must not be able to talk its own Locker into a v1 pool.
    function test_depositExternalBidRefusesAForeignLink() public {
        _crownLink2();
        _warmOracles();

        // #2 belongs to v2, not to v1
        vm.expectRevert(BidDeployer.NotOurLink.selector);
        v1.bidDeployer.depositExternalBid(link2, 1e18);

        // #0 belongs to v1, not to v2
        vm.expectRevert(BidDeployer.NotOurLink.selector);
        v2.bidDeployer.depositExternalBid(genesis, 1e18);

        // and a token nobody minted is refused by both
        vm.expectRevert(BidDeployer.NotOurLink.selector);
        v1.bidDeployer.depositExternalBid(address(0xFFFF), 1e18);
    }

    // ---------------------------------------------------------------------------------
    // three versions deep
    // ---------------------------------------------------------------------------------

    /// @notice A v3 that continues v2 resolves indices 0 and 1 through TWO registry hops, and
    /// index 2 through one. The loop is bounded at {MAX_CONTINUATION_HOPS}.
    function test_v3ContinuingV2ResolvesPriorIndicesThroughTwoHops() public {
        _crownLink2();
        Stack memory v3 = _deployStack(true, STEWARD, address(v2.roundManager));

        assertEq(v3.roundManager.priorRegistry(), address(v2.roundManager));
        assertEq(v3.roundManager.priorIndex(), 2);
        assertEq(v3.roundManager.headIndex(), 2);
        assertEq(v3.roundManager.head(), link2);

        // two hops for v1's indices, one for v2's
        assertEq(v3.roundManager.registryOf(0), address(v1.roundManager), "index 0 is two hops away");
        assertEq(v3.roundManager.registryOf(1), address(v1.roundManager), "index 1 is two hops away");
        assertEq(v3.roundManager.registryOf(2), address(v2.roundManager), "index 2 is one hop away");
        assertEq(v3.roundManager.registryOf(3), address(v3.roundManager), "index 3 is v3's to write");

        assertEq(v3.roundManager.canonical(0), genesis);
        assertEq(v3.roundManager.canonical(1), link1);
        assertEq(v3.roundManager.canonical(2), link2);
        assertEq(v3.roundManager.genesisToken(), genesis);
        assertEq(v3.roundManager.indexOf(genesis), 0, "token-keyed reads walk two hops too");
        assertEq(v3.roundManager.indexOf(link1), 1);
        assertEq(v3.roundManager.indexOf(link2), 2);
        assertEq(v3.roundManager.parentOf(link1), genesis);
        assertEq(v3.roundManager.parentOf(link2), link1);
        assertEq(
            PoolId.unwrap(v3.roundManager.poolKeyOf(0).toId()),
            PoolId.unwrap(v1.roundManager.poolKeyOf(0).toId()),
            "pool key #0 delegates twice"
        );

        // a route through v3 crosses all three versions' registries (two of pools)
        uint256 out = v3.router.buyExactIn{value: 0.5 ether}(2, 1, address(this), 3);
        assertGt(out, 0, "a v3 route resolves both prior versions' pools");
    }

    // ---------------------------------------------------------------------------------
    // sunset handover: the ETH edge follows the live version
    // ---------------------------------------------------------------------------------

    /// @notice After v1's sunset takes effect, the 1% ETH edge is still CHARGED by v1's hook on
    /// v1's genesis pool - v2 has no ETH-paired pool - but it is no longer BOOKED by v1: the
    /// claim is handed to v2's vault, which splits it with v2's own constants and attributes it
    /// through v2's own registry, so a buy of #2 pays #2's creator.
    function test_afterTheHandoverTheEdgeIsBookedByV2AndAttributedToItsCreator() public {
        _crownLink2();
        address creator2 = v2.roundManager.creatorOf(link2);
        _sunsetV1();

        uint256 v1DevBefore = v1.vault.devBalance();
        uint256 v1LedgerBefore = v1.vault.ledgerTotal(ETH);
        uint256 v1HopBefore = v1.vault.reinforcementBalance(address(0));
        // v2 already holds its own forfeited bonds as a genesis earmark, so measure the delta
        uint256 v2LedgerBefore = v2.vault.ledgerTotal(ETH);

        uint256 g = gasleft();
        uint256 out = v2.router.buyExactIn{value: 1 ether}(2, 1, address(this), 3);
        emit log_named_uint("post-handover cross-version route gas", g - gasleft());
        assertGt(out, 0, "the route still delivers");

        uint256 fee = 1 ether / 100; // PROTOCOL_FEE_PPM of the ETH specified on the genesis leg
        uint256 hop = (1 ether * HOP_FEE_PPM) / PPM;

        // v1 booked the HOP fee (it reinforces v1's own genesis pool) and nothing else
        assertEq(v1.vault.devBalance(), v1DevBefore, "v1's dev ledger is frozen at the handover");
        assertEq(v1.vault.reinforcementBalance(address(0)) - v1HopBefore, hop, "the hop fee stays with v1");
        assertEq(v1.vault.ledgerTotal(ETH) - v1LedgerBefore, hop, "v1 books the hop fee only");
        assertEq(v1.vault.successorVault(), address(v2.vault), "v1 resolved and cached v2's vault");

        // v2 booked the whole protocol fee, with V2's split and V2's attribution
        assertEq(v2.vault.ledgerTotal(ETH) - v2LedgerBefore, fee, "the edge landed in v2's ETH ledger");
        assertEq(v2.vault.devBalance(), (fee * v2.vault.DEV_BPS()) / 10_000, "v2's dev share, v2's constant");
        assertEq(v2.vault.creatorBalance(link2), (fee * CREATOR_BPS) / 10_000, "attributed to #2's creator");
        assertEq(v2.vault.creatorRecipient(link2), creator2);
        assertGt(v2.vault.claimableAncestor(0), 0, "genesis is paid out of v2's sleeve, by delegation");

        // and it is really there: the claim itself moved
        assertGe(v2.vault.holdings(ETH), v2.vault.ledgerTotal(ETH), "v2 holds what it promises");
        _assertVaultSolvent(v1.vault);
        _assertVaultSolvent(v2.vault);
    }

    /// @notice BEFORE the sunset takes effect nothing moves: v1 books the edge on its own
    /// ledgers, and a route driven by v2's router is unattributed there, exactly as it was. (v2
    /// owns no link of its own yet - it cannot, until the handover - so the route is the ETH
    /// edge on v1's genesis pool, driven by v2's router.)
    function test_beforeTheHandoverTheEdgeStaysInV1sVaultUnattributed() public {
        uint256 v1DevBefore = v1.vault.devBalance();
        uint256 v2LedgerBefore = v2.vault.ledgerTotal(ETH);
        uint256 v1Link1Before = v1.vault.creatorBalance(link1);
        v2.router.buyExactIn{value: 1 ether}(1, 0, address(this), 2);

        uint256 fee = 1 ether / 100;
        assertEq(v1.vault.devBalance() - v1DevBefore, (fee * v1.vault.DEV_BPS()) / 10_000, "v1 booked the edge");
        assertEq(v2.vault.ledgerTotal(ETH), v2LedgerBefore, "v2 got none of it");
        assertEq(v1.vault.successorVault(), address(0), "no successor was ever resolved");
        assertEq(v1.vault.creatorBalance(link1), v1Link1Before, "v2's router is not v1's trusted router yet");
        _assertVaultSolvent(v1.vault);
    }

    /// @notice Balances accrued BEFORE the handover stay where they were and stay claimable: the
    /// handover moves the future flow, never the ledger.
    function test_v1DevClaimsAccruedBeforeTheHandoverSurviveIt() public {
        _crownLink2();
        v2.router.buyExactIn{value: 1 ether}(2, 1, address(this), 3); // pre-handover edge -> v1
        uint256 owed = v1.vault.devBalance();
        assertGt(owed, 0, "v1 accrued something before the handover");

        _sunsetV1();
        v2.router.buyExactIn{value: 1 ether}(2, 1, address(this), 3); // post-handover edge -> v2
        assertEq(v1.vault.devBalance(), owed, "the handover did not touch v1's ledger");

        vm.prank(developer);
        uint256 paid = v1.vault.claimDev(developer);
        assertEq(paid, owed, "and v1's developer is still paid in full");
        _assertVaultSolvent(v1.vault);
        _assertVaultSolvent(v2.vault);
    }

    /// @notice v1 -> v2 -> v3: each sunset version passes the edge one hop further on, so the fee
    /// charged on v1's genesis pool is booked by v3, with v3's constants. The route is driven by
    /// v2's router, which v1's hook trusts (v2 is v1's named successor), so it stays attributed
    /// the whole way and v3 resolves #2 out of its own registry.
    function test_theEdgeForwardsTwoHopsFromV1ThroughV2ToV3() public {
        _crownLink2(); // v1 is already sunset in favour of v2 by now (F1)
        Stack memory v3 = _deployStack(true, STEWARD, address(v2.roundManager));

        vm.prank(STEWARD);
        v2.roundManager.announceSunset(address(v3.roundManager));
        vm.warp(block.timestamp + v1.roundManager.sunsetDelay());
        assertTrue(v1.roundManager.isSunsetEffective() && v2.roundManager.isSunsetEffective());

        uint256 v1DevBefore = v1.vault.devBalance();
        uint256 v2DevBefore = v2.vault.devBalance();
        uint256 v2LedgerBefore = v2.vault.ledgerTotal(ETH);
        v2.router.buyExactIn{value: 1 ether}(2, 1, address(this), 3);

        uint256 fee = 1 ether / 100;
        assertEq(v1.vault.devBalance(), v1DevBefore, "v1 kept none of the edge");
        assertEq(v1.vault.pendingForwardTotal(), 0, "v1 handed it straight on inside the swap");
        // AUDIT 4: the MIDDLE version does not recurse. It is sunset too, so it queues the fee for
        // its own flush instead of trying to complete the whole chain inside this swap's gas.
        assertEq(v2.vault.devBalance(), v2DevBefore, "neither did the middle version");
        assertEq(v2.vault.pendingForwardTotal(), fee, "v2 queued it for a flush");
        assertEq(v3.vault.ledgerTotal(ETH), 0, "...and nothing has reached v3 yet");
        _assertVaultSolvent(v1.vault);
        _assertVaultSolvent(v2.vault);

        // anyone can push it on, with their own gas
        (uint256 attribution, uint256 flushed) = _flushOneHop(v2.vault);
        assertEq(flushed, fee, "the whole queue moved");
        assertEq(attribution, 2, "and it still carries the attribution the charging hook accepted");
        assertEq(v2.vault.pendingForwardTotal(), 0, "v2's queue is empty");
        assertEq(v2.vault.ledgerTotal(ETH), v2LedgerBefore, "and it booked none of it");
        assertEq(v3.vault.ledgerTotal(ETH), fee, "v3 - the live version - booked it");
        assertEq(v3.vault.devBalance(), (fee * v3.vault.DEV_BPS()) / 10_000);
        assertEq(v3.vault.creatorBalance(link2), (fee * CREATOR_BPS) / 10_000, "still attributed to #2's creator");
        assertEq(v1.vault.successorVault(), address(v2.vault));
        assertEq(v2.vault.successorVault(), address(v3.vault));

        _assertVaultSolvent(v1.vault);
        _assertVaultSolvent(v2.vault);
        _assertVaultSolvent(v3.vault);
    }

    /// @notice AUDIT 4 - GAS NO LONGER DECIDES WHERE A FEE GOES. A post-sunset swap that has too
    /// little gas left to run the handover hop does NOT book the fee locally any more: it queues
    /// it, and a later permissionless {FeeVault.flushForward} delivers it to the successor with
    /// the attribution intact.
    function test_aLowGasPostSunsetSwapQueuesTheEdgeAndAFlushDeliversIt() public {
        _crownLink2();
        address creator2 = v2.roundManager.creatorOf(link2);
        _sunsetV1();

        uint256 v1DevBefore = v1.vault.devBalance();
        uint256 v2LedgerBefore = v2.vault.ledgerTotal(ETH);

        // the same route, run with barely more gas than the swap itself needs: the vault sees no
        // room for the FORWARD_GAS hop and queues instead
        uint256 out = v2.router.buyExactIn{value: 1 ether, gas: 2_000_000}(2, 1, address(this), 3);
        assertGt(out, 0, "the swap went through");

        uint256 fee = 1 ether / 100;
        assertEq(v1.vault.devBalance(), v1DevBefore, "v1 booked none of the edge");
        assertEq(v1.vault.pendingForward(2), fee, "it is queued under the attributed terminal link");
        assertEq(v1.vault.pendingForwardTotal(), fee);
        assertEq(v2.vault.ledgerTotal(ETH), v2LedgerBefore, "v2 has not been paid yet");
        assertFalse(v1.vault.forwardingFailed(), "a thin gas budget says nothing about the successor");
        _assertVaultSolvent(v1.vault);

        // a partial flush works too: the queue is a ledger, not an all-or-nothing hop
        uint256 half = v1.vault.flushForward(2, fee / 2);
        assertEq(half, fee / 2, "half of it moved");
        assertEq(v1.vault.pendingForward(2), fee - half, "the rest is still queued");
        uint256 rest = v1.vault.flushForward(2, type(uint256).max);
        assertEq(rest, fee - half);

        assertEq(v1.vault.pendingForwardTotal(), 0, "v1's queue is empty");
        assertEq(v2.vault.ledgerTotal(ETH) - v2LedgerBefore, fee, "the whole edge landed in v2's ledger");
        assertEq(v2.vault.creatorBalance(link2), (fee * CREATOR_BPS) / 10_000, "attributed to #2's creator");
        assertEq(v2.vault.creatorRecipient(link2), creator2);
        assertEq(address(v2.vault).balance >= fee, true, "and it arrived as real ETH");
        _assertVaultSolvent(v1.vault);
        _assertVaultSolvent(v2.vault);

        // an empty queue is a revert, not a silent no-op
        vm.expectRevert(FeeVault.NothingToForward.selector);
        v1.vault.flushForward(2, type(uint256).max);
    }

    /// @notice AUDIT 4 - SIX VERSIONS. The old recursion ran out of gas by about v5 and left the
    /// fee wherever it stopped. One hop per flush, paid for by whoever calls it, walks v1's edge
    /// all the way to v6 - and no vault in the chain ever books a wei of it.
    function test_theEdgeReachesTheSixthVersionThroughFlushes() public {
        _crownLink2();

        // v3..v6, each continuing the one before it: a version must have ADOPTED before it can
        // hand the trunk on (audit 2), so every version in the chain runs one round of its own
        Stack[] memory chain = new Stack[](4);
        Stack memory prev = v2;
        for (uint256 i = 0; i < 4; i++) {
            Stack memory next = _deployStack(true, STEWARD, address(prev.roundManager));
            vm.prank(STEWARD);
            prev.roundManager.announceSunset(address(next.roundManager));
            vm.warp(prev.roundManager.sunsetAt());
            _useStack(next);
            _runWinningRound(1, WINNING_BUY);
            chain[i] = next;
            prev = next;
        }
        Stack memory v6 = chain[3];
        assertEq(v6.roundManager.headIndex(), 6, "six versions, six links");

        // a plain genesis buy through the live version's router: the edge is charged by V1's hook
        FeeVault[] memory vaults = new FeeVault[](6);
        vaults[0] = v1.vault;
        vaults[1] = v2.vault;
        uint256[] memory devBefore = new uint256[](6);
        for (uint256 i = 0; i < 4; i++) {
            vaults[i + 2] = chain[i].vault;
        }
        for (uint256 i = 0; i < 6; i++) {
            devBefore[i] = vaults[i].devBalance();
        }
        uint256 v6LedgerBefore = v6.vault.ledgerTotal(ETH);
        uint256 out = v6.router.buyExactIn{value: 1 ether}(0, 0, address(this), 1);
        assertGt(out, 0, "the swap went through");
        uint256 fee = 1 ether / 100;

        // v1 forwarded inside the swap; v2 queued it, because v2 is sunset too
        assertEq(v1.vault.pendingForwardTotal() + v2.vault.pendingForwardTotal(), fee, "queued one hop along");

        // walk it the rest of the way, one permissionless flush per version
        for (uint256 i = 0; i < 5; i++) {
            if (vaults[i].pendingForwardTotal() == 0) continue;
            (, uint256 moved) = _flushOneHop(vaults[i]);
            assertEq(moved, fee, "each hop carries the whole fee");
        }

        // v6 - the only version that is not sunset - is the one that booked it
        for (uint256 i = 0; i < 5; i++) {
            assertEq(vaults[i].devBalance(), devBefore[i], "no earlier version kept a wei of the edge");
            assertEq(vaults[i].pendingForwardTotal(), 0, "and no earlier version is still holding it");
            _assertVaultSolvent(vaults[i]);
        }
        assertEq(v6.vault.ledgerTotal(ETH) - v6LedgerBefore, fee, "v6 booked the edge");
        assertEq(v6.vault.devBalance() - devBefore[5], (fee * v6.vault.DEV_BPS()) / 10_000, "with v6's own constants");
        assertGt(v6.vault.claimableAncestor(0), 0, "and v6's own sleeve, resolved by delegation");
        _assertVaultSolvent(v6.vault);
    }

    /// @notice The handover may not become a way to fail a swap: a successor that is not a real
    /// deployment (the sunset switch only checks for code) is caught, and the edge is booked
    /// locally exactly as before.
    function test_aBrokenSuccessorQueuesInsteadOfBookingLocally() public {
        address stub = address(new NotAStack());
        vm.prank(STEWARD);
        v1.roundManager.announceSunset(stub);
        vm.warp(v1.roundManager.sunsetAt());

        uint256 before = v1.vault.devBalance();
        uint256 out = v1.router.buyExactIn{value: 1 ether}(1, 0, address(this), 2);
        assertGt(out, 0, "the swap went through anyway");
        uint256 fee = 1 ether / 100;
        // AUDIT 4: NOT booked locally - a broken successor must not quietly make the old version
        // the beneficiary again. The fee waits in the queue until the hop can be completed.
        assertEq(v1.vault.devBalance(), before, "nothing was booked here");
        assertEq(v1.vault.pendingForward(1), fee, "it is queued under the attributed link");
        assertEq(v1.vault.successorVault(), address(0), "nothing was cached");
        // F2: the failed hop is cached, so no later swap pays for it again
        assertTrue(v1.vault.forwardingFailed(), "the negative resolution is cached");
        v1.router.buyExactIn{value: 1 ether}(1, 0, address(this), 2);
        assertEq(v1.vault.devBalance(), before, "and it still books nothing locally");
        assertEq(v1.vault.pendingForward(1), 2 * fee, "the queue simply grows");

        // and a flush cannot invent a successor either: the stub has no stack behind it
        vm.expectRevert();
        v1.vault.flushForward(1, type(uint256).max);
        _assertVaultSolvent(v1.vault);
    }

    /// @notice {accrueForwarded} is not an open door: only a vault in this version's own prior
    /// chain may book a forwarded fee, and {forwardProtocolFee} is callable only by the vault
    /// itself.
    function test_accrueForwardedOnlyAcceptsAPriorVaultInTheChain() public {
        _crownLink2();

        vm.expectRevert(FeeVault.NotPriorVault.selector);
        v2.vault.accrueForwarded(0, 1 ether, 8);

        vm.prank(address(0xBADBAD));
        vm.expectRevert(FeeVault.NotPriorVault.selector);
        v2.vault.accrueForwarded(0, 1 ether, 8);

        // v1 is not a continuation at all, so nothing may ever forward INTO it
        vm.prank(address(v2.vault));
        vm.expectRevert(FeeVault.NotPriorVault.selector);
        v1.vault.accrueForwarded(0, 1 ether, 8);

        vm.expectRevert(FeeVault.NotSelf.selector);
        v1.vault.forwardProtocolFee(ETH, 1 ether, 0, 8);
    }

    /// @notice Gas of the genesis-pool leg the whole protocol pays for, before and after the
    /// handover (the forwarding hop is a claim transfer plus one booked split in the successor).
    function test_gas_genesisSwapAcrossTheHandover() public {
        _crownLink2();
        // the first swap of the test warms the pool, the vault and the registry; measure the
        // SECOND one on each side of the handover, so the two numbers are comparable
        v2.router.buyExactIn{value: 0.1 ether}(0, 1, address(this), 1);
        uint256 g = gasleft();
        v2.router.buyExactIn{value: 0.1 ether}(0, 1, address(this), 1);
        uint256 before = g - gasleft();

        _sunsetV1();
        g = gasleft();
        v2.router.buyExactIn{value: 0.1 ether}(0, 1, address(this), 1);
        uint256 firstAfter = g - gasleft();

        g = gasleft();
        v2.router.buyExactIn{value: 0.1 ether}(0, 1, address(this), 1);
        uint256 warmAfter = g - gasleft();

        emit log_named_uint("genesis ETH buy, before the handover", before);
        emit log_named_uint("genesis ETH buy, first swap after (resolves and caches)", firstAfter);
        emit log_named_uint("genesis ETH buy, after the handover (cached)", warmAfter);
        assertGt(v2.vault.ledgerTotal(ETH), 0, "the post-handover swaps really did forward");
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    /// @dev Announce v1's sunset in favour of v2 and warp past the 7-day delay. Idempotent: the
    /// handover is now a PRECONDITION of every v2 round (F1), so most tests reach it twice.
    function _sunsetV1() internal {
        if (v1.roundManager.sunsetAt() == 0) {
            vm.prank(STEWARD);
            v1.roundManager.announceSunset(address(v2.roundManager));
        }
        if (block.timestamp < v1.roundManager.sunsetAt()) vm.warp(v1.roundManager.sunsetAt());
        assertTrue(v1.roundManager.isSunsetEffective(), "the handover is live");
    }

    /// @dev Push whatever a vault has queued for its successor one hop along (audit 4), whether
    /// the charging hook attributed the swap or not.
    function _flushOneHop(FeeVault v) internal returns (uint256 attribution, uint256 amount) {
        attribution = type(uint256).max;
        for (uint256 i = 0; i <= v.roundManager().headIndex(); i++) {
            if (v.pendingForward(i) != 0) attribution = i;
        }
        amount = v.flushForward(attribution, type(uint256).max);
    }

    /// @dev The solvency invariant for ANY version's vault: every ledger it keeps is backed by
    /// what it holds, in every currency of the trunk - forwarding included.
    function _assertVaultSolvent(FeeVault v) internal view {
        assertLe(v.ledgerTotal(ETH), v.holdings(ETH), "ETH ledgers <= ETH holdings");
        RoundManager rm = v.roundManager();
        for (uint256 i = 0; i <= rm.headIndex(); i++) {
            Currency c = Currency.wrap(rm.canonical(i));
            assertLe(v.ledgerTotal(c), v.holdings(c), "token ledgers <= token holdings");
        }
    }

    /// @dev Assert that `lockerAddr` - and therefore the version that owns it - really did place
    /// a locked bid in `id`, and that the position is held by that Locker forever.
    function _assertBidPlacedBy(address lockerAddr, PoolId id) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("BidDeposited(bytes32,uint256,int24,int24,uint128)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != lockerAddr || logs[i].topics[0] != sig) continue;
            assertEq(logs[i].topics[1], PoolId.unwrap(id), "the bid landed in that version's own pool");
            (, int24 lower, int24 upper, uint128 liq) = abi.decode(logs[i].data, (uint256, int24, int24, uint128));
            assertGt(liq, 0, "the bid is real liquidity, not a no-op");
            (uint128 posLiq,,) = im.getPositionInfo(id, lockerAddr, lower, upper, bytes32(0));
            assertGe(posLiq, liq, "the position belongs to that version's Locker, forever");
            found = true;
        }
        assertTrue(found, "the prior version's own Locker placed the bid");
    }

    /// @dev Run one round in v2 (three candidates, so two bonds are forfeited) and crown #2.
    /// F1: v2 may not open a round at all until v1 has handed the trunk over, so the sunset is
    /// part of getting to a v2 round.
    function _crownLink2() internal {
        if (link2 != address(0)) return;
        _sunsetV1();
        link2 = _runWinningRound(3, WINNING_BUY).token;
        assertEq(v2.roundManager.headIndex(), 2, "v2 crowned #2");
    }
}

/// @dev A "successor" with code but no stack behind it: `announceSunset` accepts it, and the
/// handover must degrade to booking locally rather than reverting a swap.
contract NotAStack {
    function ping() external pure returns (bool) {
        return true;
    }
}

/// @dev A stand-in prior registry (audit 2): sunset, idle, naming its successor - and an
/// UNADOPTED continuation of another registry, which is exactly the state that must not be
/// adopted through. Everything a continuation reads at construction is answered for real.
contract UnadoptedPrior {
    address public immutable priorRegistry;
    address public immutable headToken;
    address public successor;
    bool public adopted;

    constructor(address _prior, address _head) {
        priorRegistry = _prior;
        headToken = _head;
    }

    function setSuccessor(address s) external {
        successor = s;
    }

    function setAdopted(bool a) external {
        adopted = a;
    }

    function isSunsetEffective() external pure returns (bool) {
        return true;
    }

    function isIdle() external pure returns (bool) {
        return true;
    }

    function sunsetAt() external view returns (uint64) {
        return uint64(block.timestamp);
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        // every other registry read (canonical/indexOf/poolKeyOf/...) is answered by the real v1
        (bool ok, bytes memory ret) = priorRegistry.staticcall(data);
        require(ok, "prior read");
        return ret;
    }
}
