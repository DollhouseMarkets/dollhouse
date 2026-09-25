// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RoundManager} from "../../contracts/RoundManager.sol";
import {IFamilyHook} from "../../contracts/interfaces/IFamilyHook.sol";
import {IFeeVault} from "../../contracts/interfaces/IFeeVault.sol";

/// @notice Halmos symbolic checks over `RoundManager.finalize`'s FORFEIT PATH as changed at
/// The forfeit delivery is a `try` that is allowed to fail, a failure is
/// booked into `pendingForfeits` instead of reverting the round, and `flushForfeits` is the only
/// way the held amount later reaches the vault.
///
/// @dev THE CODE UNDER TEST IS THE REAL `finalize` AND THE REAL `flushForfeits`. What the harness
/// supplies is the PRE-STATE: driving a round to its submission deadline through the real
/// entrypoints means registering candidates, deploying their tokens and settling a random end,
/// none of which is symbolically tractable. `RoundManagerForfeitHarness` therefore writes the
/// round record directly and `finalize()` runs on it unmodified. The pre-state written is the one
/// the round machine itself produces: `candidateCount` candidates each holding `bondAmount`, the
/// matching `bondEscrow`, and a submission window that has closed.
///
/// @dev THE EDGE TOKEN MAY LIE. `MockEdgeToken.honest` is the symbolic switch the checks are
/// built around: a dishonest token returns `true` from `transfer` and moves nothing, which is
/// exactly the shape of failure this guards against (the vault's delivery check refuses the
/// deposit, and the forfeit has to be deferred rather than bricking the crowning).
///
/// @dev THE VAULT IS A MOCK that reproduces `FeeVault.depositEdgeBidEarmark`'s delivery guard
/// (`ledgerTotal > holdings` reverts). The REAL vault's version of that guard is proved
/// separately, on the real bytecode, by `FeeVaultHalmos.check_depositEdgeBidEarmarkKeepsSolvency`
/// and `check_undeliveredDepositAlwaysReverts`. It is a mock here only because the two contracts
/// name each other at construction and one of the two addresses has to be known first.
contract ForfeitHalmos {
    /// @dev Bond bound, as a bit width: `2^96` wei is far above any calibrated bond and keeps
    /// `candidateCount * bondAmount` clear of the overflow edge.
    uint256 internal constant BOND_BITS = 96;

    /// @dev Candidates per round. Concrete: the count only ever multiplies the bond, and a
    /// symbolic count turns that product into a symbolic multiplication for no extra coverage.
    uint256 internal constant CANDIDATES = 3;

    MockEdgeToken internal token;
    MockPoolManager internal pm;
    MockHook internal hook;
    MockEarmarkVault internal vault;
    RoundManagerForfeitHarness internal rm;

    function setUp() public {
        token = new MockEdgeToken();
        pm = new MockPoolManager();
        hook = new MockHook(address(pm));
        vault = new MockEarmarkVault();
        rm = new RoundManagerForfeitHarness(address(this), IFamilyHook(address(hook)), IFeeVault(address(vault)));
        vault.setToken(address(token));
    }

    function _bounded(uint256 x) internal pure returns (bool) {
        return (x >> BOND_BITS) == 0;
    }

    /// @dev Seed a closed round whose candidates all lose, and fund the escrow for real.
    function _seedAllLose(uint256 bond) internal returns (uint256 forfeited) {
        forfeited = CANDIDATES * bond;
        token.mint(address(rm), forfeited);
        rm.seedClosedRound(address(token), CANDIDATES, bond);
    }

    // -----------------------------------------------------------------------------------------
    // Booked equals delivered plus pending, and the round finalizes either way
    // -----------------------------------------------------------------------------------------

    /// @notice A round nobody won forfeits every bond. Whether the delivery to the
    /// earmark goes through or not, the round is finalized and the forfeited total is split with
    /// no remainder between what reached the earmark and what is held in `pendingForfeits`.
    function check_forfeitBookedEqualsDeliveredPlusPending(uint256 bond, bool honest) public {
        if (bond == 0 || !_bounded(bond)) return;
        token.setHonest(honest);
        uint256 forfeited = _seedAllLose(bond);

        rm.finalize();

        assert(rm.isIdle()); // the round finalized, on both branches
        assert(vault.edgeBidEarmark() + rm.pendingForfeits() == forfeited);
        // a forfeit is never in two places at once
        assert(vault.edgeBidEarmark() == 0 || rm.pendingForfeits() == 0);
        // the escrow released exactly the bonds it was holding
        assert(rm.bondEscrow() == 0);
        // and WHICH branch ran is decided by the token, not by anything else: this also pins the
        // check to the live path, since a vacuous run could not tell the two branches apart
        if (honest) {
            assert(vault.edgeBidEarmark() == forfeited && rm.pendingForfeits() == 0);
        } else {
            assert(vault.edgeBidEarmark() == 0 && rm.pendingForfeits() == forfeited);
        }
    }

    /// @notice The crowned case: the winner's bond is refunded and every OTHER candidate's
    /// is forfeited, so the forfeited total is `candidateCount * bond - winnerBond` and the same
    /// delivered-plus-pending identity holds over it.
    function check_forfeitOnACrownedRound(uint256 bond, bool honest) public {
        if (bond == 0 || !_bounded(bond)) return;
        token.setHonest(honest);
        uint256 escrow = CANDIDATES * bond;
        token.mint(address(rm), escrow);
        rm.seedCrownedRound(address(token), CANDIDATES, bond, address(this));

        uint256 forfeited = escrow - bond; // one winner's bond comes back out

        rm.finalize();

        assert(rm.isIdle());
        assert(vault.edgeBidEarmark() + rm.pendingForfeits() == forfeited);
        assert(vault.edgeBidEarmark() == 0 || rm.pendingForfeits() == 0);
    }

    /// @notice A failed delivery never silently eats the forfeit: if nothing reached the
    /// earmark, the whole amount is held, and the tokens are still here to be flushed later.
    function check_aFailedForfeitIsHeldInFull(uint256 bond) public {
        if (bond == 0 || !_bounded(bond)) return;
        token.setHonest(false); // the token accepts the transfer and moves nothing
        uint256 forfeited = _seedAllLose(bond);

        rm.finalize();

        assert(rm.isIdle());
        assert(vault.edgeBidEarmark() == 0);
        assert(rm.pendingForfeits() == forfeited);
    }

    // -----------------------------------------------------------------------------------------
    // flushForfeits: delivers or reverts, and never twice
    // -----------------------------------------------------------------------------------------

    /// @notice After a deferred forfeit, one `flushForfeits` either delivers the WHOLE
    /// held amount to the earmark or reverts and leaves it held. There is no partial delivery and
    /// no path on which the held amount falls without the earmark rising by the same figure.
    function check_flushForfeitsDeliversOrReverts(uint256 bond, bool honestLater) public {
        if (bond == 0 || !_bounded(bond)) return;
        token.setHonest(false);
        uint256 forfeited = _seedAllLose(bond);
        rm.finalize();
        assert(rm.pendingForfeits() == forfeited);

        // the token may or may not have started behaving by the time somebody flushes
        token.setHonest(honestLater);
        uint256 earmarkBefore = vault.edgeBidEarmark();

        bool ok = true;
        try rm.flushForfeits() {} catch { ok = false; }

        if (ok) {
            assert(rm.pendingForfeits() == 0);
            assert(vault.edgeBidEarmark() == earmarkBefore + forfeited);
        } else {
            assert(rm.pendingForfeits() == forfeited);
            assert(vault.edgeBidEarmark() == earmarkBefore);
        }
        // whichever branch ran, nothing was created or destroyed
        assert(vault.edgeBidEarmark() + rm.pendingForfeits() == forfeited);
    }

    /// @notice A flush never delivers twice: once the held amount is zero the second call
    /// reverts and the earmark does not move again.
    function check_flushForfeitsNeverDeliversTwice(uint256 bond) public {
        if (bond == 0 || !_bounded(bond)) return;
        token.setHonest(false);
        uint256 forfeited = _seedAllLose(bond);
        rm.finalize();

        token.setHonest(true);
        rm.flushForfeits();
        assert(vault.edgeBidEarmark() == forfeited);
        assert(rm.pendingForfeits() == 0);

        bool ok = true;
        try rm.flushForfeits() {} catch { ok = false; }
        assert(!ok);
        assert(vault.edgeBidEarmark() == forfeited);
    }
}

// ---------------------------------------------------------------------------------------------
// the harness and the environment
// ---------------------------------------------------------------------------------------------

/// @notice `RoundManager` with one added entrypoint that writes a closed round directly. Nothing
/// else is overridden: `finalize`, `flushForfeits`, `pushForfeit` and `_tryForfeit` are the
/// shipped implementations.
contract RoundManagerForfeitHarness is RoundManager {
    constructor(address _factory, IFamilyHook _hook, IFeeVault _vault)
        RoundManager(
            _factory,
            _hook,
            _vault,
            1.5e15, // H_FRAC_WAD, production
            3.75e14, // H_MIN_FRAC_WAD, production
            Bond({base: 25_000e18, doublingEvery: 4, max: 25_000e18}),
            0,
            address(0),
            7 days,
            Continuation({priorRegistry: address(0)}),
            EndRandomness({source: address(0), endTimeout: 30 minutes, durationScaleDiv: 1})
        )
    {}

    /// @dev A round past its submission deadline that nobody won: every candidate forfeits.
    function seedClosedRound(address edgeTok, uint256 n, uint256 bond) external {
        _seedCommon(edgeTok, n, bond);
    }

    /// @dev The same, with candidate 0 crowned: its bond is refunded and the rest forfeited.
    function seedCrownedRound(address edgeTok, uint256 n, uint256 bond, address creator) external {
        _seedCommon(edgeTok, n, bond);
        candidates.push();
        Candidate storage c = candidates[0];
        c.roundId = 1;
        c.token = edgeTok;
        c.creator = creator;
        c.bond = bond;
        c.submitted = true;
        Round storage r = rounds[1];
        r.hasBest = true;
        r.bestCandidateId = 0;
        r.bestAvg = 0;
        r.hUsed = 0;
    }

    function _seedCommon(address edgeTok, uint256 n, uint256 bond) internal {
        _canonical[0] = edgeTok;
        _head = edgeTok;
        _headIndex = 0;
        roundCount = 1;
        Round storage r = rounds[1];
        r.openedAt = 1;
        // `tradingEnd != 0` is "the end is settled"; `submitEnd == 0` closes the window at any
        // clock, which keeps `block.timestamp` out of the check entirely
        r.tradingEnd = 1;
        r.submitEnd = 0;
        r.candidateCount = n;
        r.bondAmount = bond;
        bondEscrow = n * bond;
    }
}

/// @notice The edge currency, with one switch: a DISHONEST token returns `true` from `transfer`
/// and moves nothing, which is what makes the vault's delivery check refuse the deposit.
contract MockEdgeToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    bool internal honest = true;

    function setHonest(bool v) external {
        honest = v;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (!honest) return true;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice The vault's earmark, with `FeeVault.depositEdgeBidEarmark`'s delivery guard.
contract MockEarmarkVault {
    address internal token;
    uint256 public edgeBidEarmark;
    uint256 public ledgerTotal;

    error NotDelivered();

    function setToken(address t) external {
        token = t;
    }

    function depositEdgeBidEarmark(uint256 amount) external {
        edgeBidEarmark += amount;
        ledgerTotal += amount;
        if (ledgerTotal > IERC20(token).balanceOf(address(this))) revert NotDelivered();
    }
}

contract MockPoolManager {
    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract MockHook {
    address internal pm;

    constructor(address _pm) {
        pm = _pm;
    }

    function poolManager() external view returns (address) {
        return pm;
    }
}
