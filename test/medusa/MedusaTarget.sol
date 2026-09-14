// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FamilyFactory} from "../../contracts/FamilyFactory.sol";
import {FamilyHook} from "../../contracts/FamilyHook.sol";
import {FamilyToken} from "../../contracts/FamilyToken.sol";
import {DevVestingDeployer} from "../../contracts/DevVesting.sol";
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
/// Time is advanced by Medusa itself (`blockTimestampDelayMax`), and ETH is provided by
/// `fuzzing.targetContractsBalances` in scripts/security/medusa.json - no `vm.deal`.
contract MedusaTarget {
    // ---------------------------------------------------------------------------------
    // deployment constants (mirrors test/utils/FamilyTestBase.sol)
    // ---------------------------------------------------------------------------------
    uint256 internal constant HOP_FEE_PPM = 1_000;
    uint256 internal constant GENESIS_UNIT = 1000 ether;
    uint256 internal constant BOND_WEI = 0.001 ether;
    uint256 internal constant BOND_DOUBLING_EVERY = 4;
    uint256 internal constant BOND_MAX_WEI = 0.064 ether;
    uint256 internal constant H_FRAC_WAD = 1.5e15;
    uint256 internal constant H_MIN_FRAC_WAD = 3.75e14;
    uint256 internal constant CREATOR_BPS = 1_000;
    uint256 internal constant ANCESTOR_BPS = 7_143;
    uint256 internal constant REINFORCE_BPS = 2_857;
    uint256 internal constant DEV_BPS = 300;
    uint256 internal constant MIN_BOUNTY_WEI = 3e14;

    address internal constant DEVELOPER = address(0xDE7);
    address internal constant STEWARD = address(0x57E);

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
    uint256 internal _headSeen;

    constructor() payable {
        poolManager = new PoolManager(address(this)); // nonce 1
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager))); // nonce 2
        RoundManagerDeployer rmDeployer = new RoundManagerDeployer(); // nonce 3
        randomness = new MockRandomnessSource(0); // nonce 4

        address predictedFactory = _createAddress(address(this), 7);
        address predictedLocker = _createAddress(predictedFactory, 1);
        address predictedVault = _createAddress(address(this), 8);
        address predictedBidDeployer = _createAddress(address(this), 9);
        address predictedRouter = _createAddress(address(this), 10);

        FamilyToken tokenImplementation = new FamilyToken(predictedFactory); // nonce 5
        DevVestingDeployer vestingDeployer = new DevVestingDeployer(); // nonce 6

        bytes32 salt = _mineHookSalt(
            predictedFactory,
            abi.encode(
                address(poolManager), predictedFactory, predictedLocker, predictedVault, predictedRouter, HOP_FEE_PPM
            )
        );

        factory = new FamilyFactory( // nonce 7
            IPoolManager(address(poolManager)),
            predictedVault,
            predictedBidDeployer,
            predictedRouter,
            HOP_FEE_PPM,
            H_FRAC_WAD,
            H_MIN_FRAC_WAD,
            GENESIS_UNIT,
            RoundManager.Bond({base: BOND_WEI, doublingEvery: BOND_DOUBLING_EVERY, max: BOND_MAX_WEI}),
            0,
            STEWARD,
            7 days,
            address(0),
            _standardCurveSpec(),
            salt,
            address(tokenImplementation),
            FamilyFactory.DevAllocation({
                deployer: address(vestingDeployer),
                bps: DEV_BPS,
                cliff: 30 days,
                duration: 365 days
            }),
            FamilyFactory.RoundSetup({
                deployer: address(rmDeployer),
                randomness: address(randomness),
                endTimeout: 30 minutes,
                durationScaleDiv: 1
            })
        );
        vault = new FeeVault(factory, DEVELOPER, CREATOR_BPS, ANCESTOR_BPS, REINFORCE_BPS); // nonce 8
        bidDeployer = new BidDeployer(vault, MIN_BOUNTY_WEI); // nonce 9
        router = new FamilyRouter(factory); // nonce 10

        require(address(factory) == predictedFactory, "factory prediction");
        require(address(vault) == predictedVault, "vault prediction");
        require(address(bidDeployer) == predictedBidDeployer, "bid deployer prediction");
        require(address(router) == predictedRouter, "router prediction");

        hook = factory.hook();
        locker = factory.locker();
        roundManager = factory.roundManager();
        require(address(locker) == predictedLocker, "locker prediction");

        (address t,) = factory.createGenesis("Family Genesis", "FAM", "ipfs://genesis");
        genesisToken = t;
        _noteToken(t);
        _snapshot();
    }

    receive() external payable {}

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
    function _mineHookSalt(address deployer, bytes memory args) internal pure returns (bytes32) {
        uint160 flags = _hookFlags() & Hooks.ALL_HOOK_MASK;
        bytes32 initHash = keccak256(abi.encodePacked(type(FamilyHook).creationCode, args));
        for (uint256 salt = 0; salt < 200_000; salt++) {
            address a =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags) return bytes32(salt);
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

    function buy(uint256 targetSeed, uint256 amountWei) external {
        calls++;
        uint256 head = roundManager.headIndex();
        uint256 target = head == 0 ? 0 : targetSeed % (head + 1);
        uint256 ethIn = _bound(amountWei, 0.001 ether, 20 ether);
        if (address(this).balance < ethIn) return;
        try router.buyExactIn{value: ethIn}(target, 0, address(this), target + 1) returns (uint256) {
            buysSucceeded++;
        } catch {}
        _snapshot();
    }

    function sell(uint256 targetSeed, uint256 tokenAmount) external {
        calls++;
        uint256 head = roundManager.headIndex();
        uint256 target = head == 0 ? 0 : targetSeed % (head + 1);
        address t = roundManager.canonical(target);
        uint256 balance = IERC20(t).balanceOf(address(this));
        if (balance == 0) return;
        try router.sellExactIn(target, _bound(tokenAmount, 1, balance), 0, address(this), target + 1) returns (uint256)
        {} catch {}
        _snapshot();
    }

    function register() external {
        calls++;
        uint256 bond = roundManager.currentBond();
        if (address(this).balance < bond) return;
        try factory.registerCandidate{value: bond}("H", "H", "") returns (address t, PoolKey memory, uint256 id) {
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
        for (uint256 i = 0; i < _candidates.length; i++) {
            try roundManager.submitScore(_candidates[i]) returns (int256) {} catch {}
        }
        _snapshot();
    }

    function finalize() external {
        calls++;
        for (uint256 i = 0; i < _candidates.length; i++) {
            try roundManager.submitScore(_candidates[i]) returns (int256) {} catch {}
        }
        try roundManager.finalize() {
            delete _candidates;
            finalizations++;
        } catch {}
        _snapshot();
    }

    function keeperDeploy(uint256 seed, uint256 amountSeed) external {
        calls++;
        try bidDeployer.deployGenesisBid() returns (uint256) {
            deploysSucceeded++;
        } catch {}
        uint256 head = roundManager.headIndex();
        uint256 j = head == 0 ? 0 : seed % (head + 1);
        if (j != 0) {
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

    /// @notice FEE-11: for every currency `ledgerTotal[c] <= holdings(c)` - the vault's promises
    /// are always backed by its real balance plus unredeemed ERC-6909 claims.
    function property_FEE11_vaultIsSolvent() public view returns (bool) {
        Currency eth = Currency.wrap(address(0));
        if (vault.ledgerTotal(eth) > vault.holdings(eth)) return false;
        if (vault.ledgerTotal(eth) < vault.pendingForwardTotal()) return false;
        uint256 head = roundManager.headIndex();
        for (uint256 i = 0; i <= head; i++) {
            Currency c = Currency.wrap(roundManager.canonical(i));
            if (vault.ledgerTotal(c) > vault.holdings(c)) return false;
        }
        return true;
    }

    /// @notice FEE-08: the non-ETH ledgers are hop fees (and snipe tax) alone - a protocol fee
    /// exists only on the ETH edge.
    function property_FEE08_familyLedgersAreHopFeesOnly() public view returns (bool) {
        uint256 head = roundManager.headIndex();
        for (uint256 i = 0; i <= head; i++) {
            address t = roundManager.canonical(i);
            if (vault.ledgerTotal(Currency.wrap(t)) != vault.reinforcementBalance(t)) return false;
        }
        return true;
    }

    /// @notice SUP-01: `totalSupply()` is fixed for every family token ever launched.
    function property_SUP01_supplyNeverMoves() public view returns (bool) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (IERC20(tokens[i]).totalSupply() != supplySeen[tokens[i]]) return false;
        }
        return true;
    }

    /// @notice RND-09: `canonical[i]` is write-once, has no gaps, and the reverse index agrees.
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

    /// @notice BID-05: ETH leaves the vault on the keeper path only against a credit created in
    /// the same call, so no keeper call ever leaves a residual credit or ETH behind.
    function property_BID05_keeperLeashIsNeverSlack() public view returns (bool) {
        if (vault.deployerCredit() != 0) return false;
        if (address(bidDeployer).balance != 0) return false;
        return true;
    }
}
