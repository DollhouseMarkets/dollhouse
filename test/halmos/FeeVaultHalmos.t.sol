// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/src/types/Currency.sol";

import {FamilyFactory} from "../../contracts/FamilyFactory.sol";
import {FeeVault} from "../../contracts/FeeVault.sol";

/// @notice Halmos symbolic checks over the REAL `FeeVault`: the delivery
/// guards on the two non-payable deposits (FEE-11, RND-11), the donation gap (SUP-04), the
/// zero-address guard on every payout path, the two-sided conservation of `flushForward` (CON-05)
/// and the edge-ledger decomposition (FEE-10). These stand in for `certora/specs/FeeVault.spec`,
/// which the Prover cannot currently load.
///
/// @dev THE DEPLOYMENT IS REAL, THE ENVIRONMENT IS MOCKED. `FeeVault`'s constructor reads six
/// addresses off the factory and one off the RoundManager; those two, the PoolManager and the
/// prior-version registry are replaced by the smallest contracts that answer the same ABI, so the
/// bytecode under test is the shipped contract's and nothing else is. The split constants are the
/// PRODUCTION ones from `script/Deploy.s.sol` (4000 / 5000 / 5000), not the test-base ones.
///
/// @dev Three bounds keep every check inside a few minutes of solver time:
///   - AMOUNTS ARE BOUNDED to `2^96` wei (about 7.9e28). `FenwickRangeAdd.addSleeve` multiplies
///     the sleeve by `WAD` before storing it and `claimableAncestor` divides it back out, and
///     that division is what the bound buys: unbounded, it does not discharge.
///   - THE ANCESTOR DEPTH IS `M = 0`. `addSleeve` routes through `FullMath.mulDiv` for `M > 0`,
///     which Z3 cannot discharge; at `M = 0` it is a plain range-add over
///     `[0, 0]`. Attribution is still fully symbolic: every index above `headIndex()` and every
///     candidate id resolves to "unattributed", which is also `M = 0`.
///   - THE POOL MANAGER HOLDS NO ERC-6909 CLAIMS, so `holdings` is the real ERC-20 balance and
///     `redeem` is a no-op. The claim half of `holdings` is covered by the fuzz and fork suites.
contract FeeVaultHalmos {
    /// @dev Amount bound, stated as a BIT WIDTH rather than a decimal cap. `2^96` is about
    /// 7.9e28 wei, far above any real fee and far below the `sleeve * WAD` overflow edge, and a
    /// power-of-two bound is a mask for the solver instead of a 256-bit comparison. The checks
    /// that read `claimableEdge` go through a `/ WAD` on a Fenwick prefix sum, and that division
    /// is what the bound is really for: at `1e30` it did not discharge inside ten minutes.
    uint256 internal constant AMOUNT_BITS = 96;

    /// @dev `FenwickRangeAdd.WAD`, the precision the ancestor sleeve is stored at.
    uint256 internal constant WAD = 1e18;

    /// @dev True when `x` fits the amount bound above.
    function _bounded(uint256 x) internal pure returns (bool) {
        return (x >> AMOUNT_BITS) == 0;
    }

    MockEdgeToken internal token;
    MockPoolManager internal pm;
    MockRound internal round;
    MockRegistry internal registry;
    MockPriorVault internal prior;
    MockKeeper internal keeper;
    MockFactory internal factory;
    FeeVault internal vault;

    Currency internal edge;

    function setUp() public {
        token = new MockEdgeToken();
        pm = new MockPoolManager();
        prior = new MockPriorVault();
        registry = new MockRegistry(address(prior));
        round = new MockRound(address(registry));
        keeper = new MockKeeper();
        // hook and locker only have to have code for the constructor's L7 checks
        factory =
            new MockFactory(address(pm), address(pm), address(round), address(pm), address(keeper), address(token));
        vault = new FeeVault(FamilyFactory(address(factory)), address(this), 4_000, 5_000, 5_000);
        edge = vault.EDGE();
        // canonical(0) is the edge token itself and this contract is its creator, so the creator
        // share has a real destination and `claimCreator` is reachable
        round.setCanonical(address(token));
        round.setCreator(address(this));
    }

    /// @dev The inductive form of FEE-11 / SUP-04, exactly as `certora/specs/FeeVault.spec`
    /// states it: the deployer credit is edge currency the vault still holds and has already
    /// taken out of `ledgerTotal`, so it has to be carved back out on the ledger side.
    function _solvent() internal view returns (bool) {
        return vault.ledgerTotal(edge) + vault.deployerCredit() <= vault.holdings(edge);
    }

    // -----------------------------------------------------------------------------------------
    // 1. the delivery guards on the two non-payable deposits
    // -----------------------------------------------------------------------------------------

    /// @notice FEE-11. `receiveForward` credits `ledgerTotal[EDGE]` on the caller's word and then
    /// re-checks it against what the vault actually holds. For ANY claimed amount and ANY amount
    /// really delivered, the call either reverts or leaves the vault solvent.
    function check_receiveForwardKeepsSolvencyWhenLive(uint256 attribution, uint256 amount, uint256 delivered) public {
        if (!_bounded(amount) || !_bounded(delivered)) return;
        token.mint(address(vault), delivered); // what actually arrived, which may be nothing
        prior.forward(vault, attribution, amount); // reverting paths are dropped, which is the claim
        assert(_solvent());
    }

    /// @notice FEE-11, the post-sunset branch of the same entrypoint: the fee is queued for the
    /// successor rather than booked, and the guard still has to hold.
    function check_receiveForwardKeepsSolvencyWhenSunset(uint256 attribution, uint256 amount, uint256 delivered)
        public
    {
        if (!_bounded(amount) || !_bounded(delivered)) return;
        round.setSunset(true);
        token.mint(address(vault), delivered);
        prior.forward(vault, attribution, amount);
        assert(_solvent());
        assert(vault.pendingForwardTotal() <= vault.ledgerTotal(edge));
    }

    /// @notice RND-11 / FEE-11. The same shape on `depositEdgeBidEarmark`: a forfeit that never
    /// arrived is refused at the door, which is what makes `RoundManager`'s try/catch meaningful.
    function check_depositEdgeBidEarmarkKeepsSolvency(uint256 amount, uint256 delivered) public {
        if (!_bounded(amount) || !_bounded(delivered)) return;
        token.mint(address(vault), delivered);
        round.deposit(vault, amount);
        assert(vault.edgeBidEarmark() == amount);
        assert(_solvent());
    }

    /// @notice The guard stated in the other direction: an amount that was NOT delivered can
    /// never be credited. If the ledger after the credit would exceed the holdings, the call has
    /// to revert.
    function check_undeliveredDepositAlwaysReverts(uint256 amount, uint256 delivered) public {
        if (!_bounded(amount) || !_bounded(delivered)) return;
        if (amount <= delivered) return; // only the shortfall case is the claim
        token.mint(address(vault), delivered);
        try round.deposit(vault, amount) {
            assert(false); // an undelivered forfeit was earmarked
        } catch {}
        assert(vault.edgeBidEarmark() == 0);
        assert(_solvent());
    }

    // -----------------------------------------------------------------------------------------
    // 2. donations
    // -----------------------------------------------------------------------------------------

    /// @notice SUP-04. Solvency is an INEQUALITY and the gap is reachable: anyone may transfer the
    /// edge currency straight to the vault. For any donation, on top of any booked state, every
    /// ledger reads exactly what it read before and the inequality still holds. Nothing in the
    /// contract turns a donation into a claim, and nothing sweeps it.
    function check_donationCreditsNoLedger(uint256 amount, uint256 donation) public {
        if (!_bounded(amount) || !_bounded(donation)) return;
        // a real, booked fee first, so the check is about a donation ON TOP OF live ledgers
        token.mint(address(vault), amount);
        prior.forward(vault, 0, amount);

        uint256 ledgerBefore = vault.ledgerTotal(edge);
        uint256 devBefore = vault.devBalance();
        uint256 creatorBefore = vault.creatorBalance(address(token));
        uint256 accruedBefore = vault.creatorAccrued(address(this));
        uint256 earmarkBefore = vault.edgeBidEarmark();
        uint256 reinforceBefore = vault.reinforcementEdge(0);
        uint256 claimableBefore = vault.claimableEdge(0);
        uint256 drawableBefore = vault.drawableEdge(0);
        uint256 pendingBefore = vault.pendingForwardTotal();

        token.mint(address(vault), donation); // an unsolicited transfer in, from anyone

        assert(vault.ledgerTotal(edge) == ledgerBefore);
        assert(vault.devBalance() == devBefore);
        assert(vault.creatorBalance(address(token)) == creatorBefore);
        assert(vault.creatorAccrued(address(this)) == accruedBefore);
        assert(vault.edgeBidEarmark() == earmarkBefore);
        assert(vault.reinforcementEdge(0) == reinforceBefore);
        assert(vault.claimableEdge(0) == claimableBefore);
        assert(vault.drawableEdge(0) == drawableBefore);
        assert(vault.pendingForwardTotal() == pendingBefore);
        assert(_solvent());
    }

    // -----------------------------------------------------------------------------------------
    // 3. the zero-address guard on every payout path
    // -----------------------------------------------------------------------------------------

    /// @notice `_sendToken` refuses `address(0)` on every payout path. Stated for a SYMBOLIC
    /// recipient, one payout path per check: a payout that went through proves its destination
    /// was not the zero address. The mock edge token happily accepts a transfer to `address(0)`
    /// (plenty of real ERC-20s do), so the guard under test is the vault's own, not the token's.
    ///
    /// @dev One path per check rather than all four in sequence. A symbolic recipient makes every
    /// token transfer a storage write at a symbolic key, and four of them in one function did not
    /// discharge inside ten minutes.
    function check_claimDevNeverReachesTheZeroAddress(address to, uint256 amount) public {
        if (amount == 0 || !_bounded(amount)) return;
        token.mint(address(vault), amount);
        prior.forward(vault, 0, amount);
        bool paid = true;
        try vault.claimDev(to) {} catch { paid = false; }
        if (paid) assert(to != address(0));
    }

    /// @notice The same, on the creator claim.
    function check_claimCreatorNeverReachesTheZeroAddress(address to, uint256 amount) public {
        if (amount == 0 || !_bounded(amount)) return;
        token.mint(address(vault), amount);
        prior.forward(vault, 0, amount);
        bool paid = true;
        try vault.claimCreator(address(token), to) {} catch { paid = false; }
        if (paid) assert(to != address(0));
    }

    /// @notice The same, on the accrued-creator claim, which is reached by transferring the
    /// creator right away first so that there is an accrued balance to claim.
    function check_claimCreatorAccruedNeverReachesTheZeroAddress(address to, uint256 amount) public {
        if (amount == 0 || !_bounded(amount)) return;
        token.mint(address(vault), amount);
        prior.forward(vault, 0, amount);
        vault.transferCreatorRecipient(address(token), address(prior)); // sweeps the balance here
        bool paid = true;
        try vault.claimCreatorAccrued(to) {} catch { paid = false; }
        if (paid) assert(to != address(0));
    }

    /// @notice The same, on the keeper payout: draw generation 0's sleeve, then pay it out.
    /// @dev THE FEE IS CONCRETE HERE and only the recipient is symbolic. The draw runs through
    /// `drawableEdge` and the drawdown bucket, which is two constant divisions on top of the
    /// sleeve's `/ WAD`; with a symbolic fee as well this check did not discharge in ten minutes.
    /// The claim is about the DESTINATION, and the destination is what stays symbolic.
    function check_payKeeperNeverReachesTheZeroAddress(address to) public {
        uint256 amount = 1_000e18;
        token.mint(address(vault), amount);
        prior.forward(vault, 0, amount);
        bool paid = true;
        try keeper.drawAndPay(vault, 0, to) {} catch { paid = false; }
        if (paid) assert(to != address(0));
    }

    /// @notice The same guard stated concretely, mirroring
    /// `noPayoutPathCanBurnTokensAtTheZeroAddress`: with a live balance on every ledger, all four
    /// payout entrypoints revert on `address(0)` rather than burning the claim.
    /// @dev Concrete fee, for the same reason as the keeper check above: four sequential
    /// payout attempts on a symbolic amount is 309 paths and does not discharge. Every one of the
    /// four destinations here is the concrete zero address, so there is nothing symbolic left for
    /// the amount to add.
    function check_zeroAddressPayoutsAlwaysRevert() public {
        uint256 amount = 1_000e18;
        token.mint(address(vault), amount);
        prior.forward(vault, 0, amount);

        bool reverted = false;
        try vault.claimDev(address(0)) {} catch { reverted = true; }
        assert(reverted);
        reverted = false;
        try vault.claimCreator(address(token), address(0)) {} catch { reverted = true; }
        assert(reverted);
        reverted = false;
        try vault.claimCreatorAccrued(address(0)) {} catch { reverted = true; }
        assert(reverted);
        reverted = false;
        try keeper.drawAndPay(vault, 0, address(0)) {} catch { reverted = true; }
        assert(reverted);
    }

    // -----------------------------------------------------------------------------------------
    // 4. flushForward conservation, two-sided
    // -----------------------------------------------------------------------------------------

    /// @notice CON-05. One flush either DELIVERS the amount to the successor's vault or, on the
    /// aged-evidence branch, books it on this version's ledgers. The honest statement is two
    /// sided: the queue falls by exactly what left it, `ledgerTotal` falls by exactly what was
    /// really delivered, and never by more.
    function check_flushForwardConservesTwoSided(uint256 attribution, uint256 amount, uint256 max, bool successorOk)
        public
    {
        if (amount == 0 || !_bounded(amount) || !_bounded(max)) return;
        round.setSunset(true);
        token.mint(address(vault), amount);
        prior.forward(vault, attribution, amount); // queued, not booked

        MockSuccessorVault sv = new MockSuccessorVault();
        sv.setAccepts(successorOk);
        round.setSuccessor(address(new MockSuccessor(address(new MockSuccessorFactory(address(sv))))));

        uint256 queueBefore = vault.pendingForward(attribution);
        uint256 ledgerBefore = vault.ledgerTotal(edge);
        uint256 heldBefore = token.balanceOf(address(sv));

        uint256 moved = vault.flushForward(attribution, max);

        uint256 deliveredOut = token.balanceOf(address(sv)) - heldBefore;
        uint256 queueDrop = queueBefore - vault.pendingForward(attribution);
        uint256 ledgerDrop = ledgerBefore - vault.ledgerTotal(edge);

        assert(moved <= max);
        assert(vault.pendingForward(attribution) <= queueBefore);
        assert(vault.ledgerTotal(edge) <= ledgerBefore);
        // the queue falls by exactly what the call reported moving
        assert(queueDrop == moved);
        // the ledger falls by exactly what really left the building, never by more
        assert(ledgerDrop == deliveredOut);
        assert(ledgerDrop <= moved);
        // either the whole amount was delivered, or none of it was and the branch that dequeued
        // it booked it here instead
        assert(deliveredOut == moved || deliveredOut == 0);
        assert(_solvent());
    }

    /// @notice CON-05. A flush that delivered nothing leaves the queue exactly as it was: a failed
    /// hop may never strand a successor's fee (the `_requeue` half of this property).
    function check_failedFlushLeavesTheQueueIntact(uint256 attribution, uint256 amount) public {
        if (amount == 0 || !_bounded(amount)) return;
        round.setSunset(true);
        token.mint(address(vault), amount);
        prior.forward(vault, attribution, amount);

        MockSuccessorVault sv = new MockSuccessorVault();
        sv.setAccepts(false);
        round.setSuccessor(address(new MockSuccessor(address(new MockSuccessorFactory(address(sv))))));

        uint256 ledgerBefore = vault.ledgerTotal(edge);
        uint256 moved = vault.flushForward(attribution, amount);

        assert(moved == 0);
        assert(vault.pendingForward(attribution) == amount);
        assert(vault.pendingForwardTotal() == amount);
        assert(vault.ledgerTotal(edge) == ledgerBefore);
        assert(token.balanceOf(address(sv)) == 0);
        assert(_solvent());
    }

    // -----------------------------------------------------------------------------------------
    // 5. the edge-ledger decomposition
    // -----------------------------------------------------------------------------------------

    /// @dev The enumerated edge-denominated ledgers of FEE-10, summed and WAD-SCALED.
    ///
    /// @dev The scaling is not cosmetic. The ancestor sleeve is held in the Fenwick trees at
    /// `WAD` precision and `claimableAncestor` divides it back down, so a sum that goes through
    /// `claimableEdge` asks the solver to invert a 256-bit division by `1e18` on top of the four
    /// constant divisions of the fee split. That did not discharge in ten minutes at any amount
    /// bound tried. Multiplying the whole relation by `WAD` instead leaves only multiplications,
    /// and it states a STRICTLY STRONGER claim: the raw point query is the UNFLOORED sleeve, so
    /// the right-hand side here is never smaller than the one the getters report.
    function _namedLedgersWad() internal view returns (uint256) {
        int256 q = vault.ancestorPointQueryWad(0);
        uint256 grossWad = q <= 0 ? 0 : uint256(q);
        uint256 claimedWad = vault.ancestorClaimed(0) * WAD;
        uint256 sleeveWad = grossWad > claimedWad ? grossWad - claimedWad : 0;
        uint256 flat = vault.devBalance() + vault.creatorBalance(address(token))
            + vault.creatorAccrued(address(this)) + vault.edgeBidEarmark() + vault.pendingForwardTotal()
            + vault.reinforcementEdge(0);
        return flat * WAD + sleeveWad;
    }

    /// @dev The booked starting state every decomposition check below acts on: one real fee,
    /// already split over dev / creator / sleeve / reinforcement.
    function _bookOneFee(uint256 amount) internal {
        token.mint(address(vault), amount);
        prior.forward(vault, 0, amount);
        _assertDecomposition();
    }

    /// @dev The claim itself: `ledgerTotal[EDGE]` still covers the sum of the named ledgers.
    /// `>=` and not `==` because the Fenwick residue stays in the vault forever and is
    /// deliberately not subtracted.
    function _assertDecomposition() internal view {
        assert((vault.ledgerTotal(edge) + vault.deployerCredit()) * WAD >= _namedLedgersWad());
        assert(_solvent());
    }

    /// @notice FEE-10, after a second forwarded fee is booked.
    /// @dev The five branches of this call set are five separate checks rather than one
    /// symbolic switch: as one function the solver had to carry every branch's state at once and
    /// the check did not discharge inside ten minutes.
    function check_decompositionAfterASecondFee(uint256 amount) public {
        if (amount == 0 || !_bounded(amount)) return;
        _bookOneFee(amount);
        token.mint(address(vault), amount);
        prior.forward(vault, 0, amount);
        _assertDecomposition();
    }

    /// @notice FEE-10, after a forfeit is deposited into the earmark.
    function check_decompositionAfterAForfeitDeposit(uint256 amount) public {
        if (amount == 0 || !_bounded(amount)) return;
        _bookOneFee(amount);
        token.mint(address(vault), amount);
        round.deposit(vault, amount);
        _assertDecomposition();
    }

    /// @notice FEE-10, after the developer share is claimed out.
    function check_decompositionAfterClaimDev(uint256 amount) public {
        if (amount == 0 || !_bounded(amount)) return;
        _bookOneFee(amount);
        vault.claimDev(address(this));
        _assertDecomposition();
    }

    /// @notice FEE-10, after the keeper draws generation 0 and is paid.
    ///
    /// @dev THE ONLY CHECK HERE WITH A CONCRETE FEE. The draw amount is
    /// `min(bucket, claimableEdge)` and `claimableEdge` is the Fenwick sleeve DIVIDED BY `WAD`,
    /// so the drawn figure itself is a division of a symbolic value and no WAD-scaled restatement
    /// can lift it out: the division is inside the contract's own control flow, not in the
    /// assertion. With a symbolic fee this check produced no verdict in ten minutes. The fee is
    /// therefore pinned and the coverage claimed is correspondingly narrower; the symbolic-fee
    /// statement of the same property is left to the fuzz and invariant suites.
    function check_decompositionAfterAKeeperDraw() public {
        _bookOneFee(1_000e18);
        keeper.drawAndPay(vault, 0, address(this));
        _assertDecomposition();
    }

    /// @notice FEE-10, after a post-sunset fee is queued rather than booked.
    function check_decompositionAfterAQueuedFee(uint256 amount) public {
        if (amount == 0 || !_bounded(amount)) return;
        _bookOneFee(amount);
        round.setSunset(true);
        token.mint(address(vault), amount);
        prior.forward(vault, 0, amount);
        _assertDecomposition();
    }

    /// @notice FEE-08 / FEE-10 at `M = 0`, where the Fenwick residue is zero by construction (the
    /// whole sleeve is stored at index 0 and read straight back): one booked fee decomposes into
    /// the named ledgers EXACTLY, with nothing created and nothing lost.
    function check_oneBookedFeeDecomposesExactly(uint256 amount) public {
        if (!_bounded(amount)) return;
        token.mint(address(vault), amount);
        prior.forward(vault, 0, amount);

        uint256 flat = vault.devBalance() + vault.creatorBalance(address(token)) + vault.reinforcementEdge(0);
        int256 q = vault.ancestorPointQueryWad(0);
        uint256 sleeveWad = q <= 0 ? 0 : uint256(q);
        // WAD-scaled, for the reason given on `_namedLedgersWad`: the sleeve is the only term
        // held at WAD precision, so scaling the whole equation is what removes the division. A
        // sleeve that came back negative fails this equality too, so the sign is covered.
        assert(flat * WAD + sleeveWad == amount * WAD);
        assert(vault.ledgerTotal(edge) == amount);
        assert(_solvent());
    }
}

// ---------------------------------------------------------------------------------------------
// the environment
// ---------------------------------------------------------------------------------------------

/// @notice The edge currency. Deliberately permissive: it accepts a transfer to `address(0)`, so
/// the zero-address checks above test the vault's guard and not the token's.
contract MockEdgeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice The v4 PoolManager, reduced to what the vault reads: the unlock flag and the vault's
/// own ERC-6909 claim balance, which is always zero here.
contract MockPoolManager {
    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice One link of the prior-version registry chain the vault walks in `_isPriorVault`.
contract MockRegistry {
    address public feeVault;

    constructor(address v) {
        feeVault = v;
    }

    function priorRegistry() external pure returns (address) {
        return address(0);
    }
}

/// @notice The RoundManager, reduced to the getters the vault calls, plus the one entrypoint the
/// RoundManager itself is the only permitted caller of.
contract MockRound {
    address public priorRegistry;
    address public successor;
    bool internal sunset;
    address internal canonicalToken;
    address internal creator;

    constructor(address reg) {
        priorRegistry = reg;
    }

    function setSunset(bool v) external {
        sunset = v;
    }

    function setSuccessor(address v) external {
        successor = v;
    }

    function setCanonical(address t) external {
        canonicalToken = t;
    }

    function setCreator(address c) external {
        creator = c;
    }

    function isSunset() external view returns (bool) {
        return sunset;
    }

    function headIndex() external pure returns (uint256) {
        return 0;
    }

    function candidateCount() external pure returns (uint256) {
        return 0;
    }

    function canonical(uint256) external view returns (address) {
        return canonicalToken;
    }

    function creatorOf(address) external view returns (address) {
        return creator;
    }

    function deposit(FeeVault v, uint256 amount) external {
        v.depositEdgeBidEarmark(amount);
    }
}

/// @notice The factory, reduced to the six addresses the vault's constructor reads off it.
contract MockFactory {
    address public poolManager;
    address public hook;
    address public roundManager;
    address public locker;
    address public bidDeployer;
    address internal genesis;

    constructor(address _pm, address _hook, address _round, address _locker, address _bid, address _genesis) {
        poolManager = _pm;
        hook = _hook;
        roundManager = _round;
        locker = _locker;
        bidDeployer = _bid;
        genesis = _genesis;
    }

    function genesisToken() external view returns (address) {
        return genesis;
    }
}

/// @notice A FeeVault of a version this one continues: the only caller `receiveForward` accepts.
contract MockPriorVault {
    function forward(FeeVault v, uint256 attribution, uint256 amount) external {
        v.receiveForward(attribution, amount);
    }
}

/// @notice The BidDeployer: the only caller of the keeper hooks.
contract MockKeeper {
    function drawAndPay(FeeVault v, uint256 j, address to) external {
        uint256 drawn = v.consumeAncestorClaim(j, v.drawableEdge(j));
        v.payKeeper(to, drawn);
    }

    function drawEarmark(FeeVault v, uint256 amount) external {
        v.consumeEdgeEarmark(amount);
    }
}

/// @notice The successor version's vault. `accepts` is the symbolic switch between a hop that
/// goes through and one that reverts.
contract MockSuccessorVault {
    bool internal accepts;

    function setAccepts(bool v) external {
        accepts = v;
    }

    function receiveForward(uint256, uint256) external view {
        if (!accepts) revert("successor refused");
    }
}

contract MockSuccessorFactory {
    address public feeVault;

    constructor(address v) {
        feeVault = v;
    }
}

contract MockSuccessor {
    address public factory;

    constructor(address f) {
        factory = f;
    }
}
