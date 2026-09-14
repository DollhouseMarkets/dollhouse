# Independent design review — 2026-09-10

**Verdict: reject v1 as an implementable specification.** It permits arbitrary winner selection, near-total protocol-fee avoidance, and incorrect ancestor payouts. Several promised mechanisms contradict their accounting requirements.

I read all six files in the requested order. No files were written. Findings below concern the specification; they are not claims of demonstrated exploits against deployed code.

1. **The first submitted candidate can steal succession — critical. Q3**

   **Scenario:** Candidate A’s final score is 100; B’s is 1,000; both exceed the threshold. Submissions become permissible only after `T_end + 300`. At that timestamp, A’s supporter executes `submitScore(A); finalize()` atomically. B is never considered. The supposed challenge window afforded no opportunity to submit or challenge anything.

   **Wrong outcome:** An inferior candidate becomes the immutable canonical head through transaction ordering.

   **Smallest fix:** Permit submissions during `[T_end, T_end + 300)`, then finalize the accumulated maximum. Specify boundary timestamps, immutable score snapshots, and deterministic tie comparison. A permissionless submitter must be able to submit B without B’s creator cooperating.

2. **The transaction-wide fee exemption is universally exploitable — critical. Q2/Q7**

   **Scenario:** A router first swaps `10^-9 ETH` in a family pool, then executes a 100 ETH family trade. The first-input rule charges `10^-11 ETH` instead of approximately 1 ETH. Repeat the dust prefix in every transaction. Independently enforced per-hop and snipe charges remain.

   This is an individual trader’s bypass, not merely the disclosed batching concession.

   Deferring collection does not repair it: the hook receives no transaction-end callback and cannot authenticate a router’s “last leg” declaration. In `ETH → GENESIS → #1 → #2`, the last pool does not even contain the original ETH fee currency. Its return delta cannot debit arbitrary ETH.

   **Largest-leg verdict:** Also exploitable. Split 100 ETH into 100 one-ETH legs: the largest-leg fee is 0.01 ETH rather than 1 ETH. Execution-price conversion additionally imports manipulable ancestor prices.

   **Smallest fix:** No fix retaining unrestricted router execution plus transaction-wide exemptions inferred by the hook. Charge independently per swap, or introduce a permissionless immutable executor that validates an explicit route, its funding, and settlement. That changes the “no privileged router” decision.

3. **Global birth snapshots do not implement ancestor entitlements — critical. Q2/Q6**

   **Scenario:** Head is #10; someone trades #2. Only genesis and #1 are its ancestors. The proposed global accumulators nevertheless credit already-born generations #2–#10.

   Keeping the current-head normalizer conserves the total but pays incorrect beneficiaries. Merely changing the normalizer to the traded pool’s ancestry can instead create insolvency. Using the polynomial proposed below, a distribution normalized for ancestors `j=0,1` has `Z=3`; applying it to all existing `j=0…10` produces **429 times the funded entitlement**.

   Separately, `A` is not one fungible quantity: ETH fees and #100-token fees cannot share monetary accumulators without conversion. A birth snapshot resolves neither eligibility nor currency.

   **Smallest fix:** Maintain currency-specific liabilities and ancestry-bounded updates, such as prefix updates with point claims in `O(log N)`. Persist each pool’s eligible ancestor endpoint. The stated constant-number global accumulators cannot express these restricted payouts for permanently tradable historical pools.

4. **“Buy the beneficiary, then provide a bid” uses the wrong asset — high. Q6**

   **Scenario:** The vault buys 100 beneficiary tokens X. It then attempts to place those X as single-sided bids below X’s current parent-denominated price.

   **Wrong outcome:** Such bids require **parent tokens**, not X. Purchased X can fund an ask above spot or be held/burned; it cannot fund the specified bid. This follows from concentrated-liquidity inventory conversion. [Uniswap concentrated liquidity](https://developers.uniswap.org/docs/get-started/concepts/liquidity-providers/concentrated-liquidity)

   Fees collected in descendant tokens also cannot start an ETH-funded upward route without someone selling or exchanging those tokens. External conversion relocates the sale; it does not eliminate it.

   Finally, with pool fee zero, hook fees do not automatically compound into liquidity merely because assets remain inside PoolManager.

   **Smallest fix:** Separate parent-funded bid deposits from beneficiary purchases. Define conversion routes explicitly, permit necessary sales, and specify actual Locker liquidity additions. Delete the simultaneous promises of “buy beneficiary,” “bid below spot,” and “never sell down-chain.”

5. **A refundable capital rental purchases the canonical slot — high. Q1**

   First repair the threshold’s units as described in finding 7. Let the round duration be `D`, and its required average absorption be `H`.

   **Illustrative inputs:** One constant-liquidity range has `s=1`, `Fa=1,000`, `Fb=1,000,000`, all in parent units:

   \[
   C_{\max}=s\sqrt{F_aF_b}=31{,}622.78.
   \]

   Set `H = 25% Cmax = 7,905.69`. Buy with 8,000 parent tokens immediately after the three-second snipe period. For any `D∈[600,780]`:

   \[
   \frac{\mathrm{Score}}D=8{,}000(1-3/D)\ge7{,}960>H.
   \]

   The time median is 8,000; the cap does nothing. Sell immediately after the scoring endpoint, **before finalization**. The selected winner can already have zero remaining attacker absorption when announced.

   Approximate cost: 160 parent tokens in protocol fees, plus 8–48 in one-hop round-trip fees, the winning bond, gas, and financing. Owning the creator entitlement rebates 30–50% of the protocol component. Finding 2 removes almost that entire component.

   The general bound `cost(T) ≤ T × fraction sold below T` also prevents treating impressive FDV endpoints as equivalent capital commitments. Reversibility prevents treating purchase expenditure as a sunk selection cost.

   **Smallest fix:** No fix without changing refundable, immediately transferable succession. Otherwise describe the competition as a capital-rental auction. This attack requires capital across time; an atomic flash loan alone cannot hold the baseline through the round.

6. **A contract cannot secretly know its scoring deadline — high. Q4**

   **Scenario:** At trading start, the hook can compute `T_end` and clamp scores. An observer reproduces that computation or reads its inputs. A commitment conceals nothing that ordinary public execution already knows.

   If only the commitment exists and nobody reveals its preimage, the hook cannot perform the specified clamp.

   Standard Arbitrum documentation says `prevrandao` returns **1**, and warns that its block hashes are insecure randomness. Robinhood’s precise deployed ArbOS behavior still requires verification. [Arbitrum Solidity support](https://docs.arbitrum.io/arbitrum-essentials/arbitrum-vs-ethereum/solidity-support)

   **Smallest fix:** Use a public fixed endpoint. Alternatively, select an endpoint retrospectively using subsequently available randomness and retain sufficient history to reconstruct the score; that changes both storage and trust assumptions. Commit-at-open plus blockhash-at-close does not provide a secret, pre-known clamp and retains sequencing/withholding risks.

7. **Thresholds mix units, unavailable history, and unreachable liquidity — high. Q1/Q5**

   **Scenario A:** Score is measured in parent-seconds; threshold is measured in parent tokens. Comparing them literally lets approximately 0.84 parent held for 597 seconds clear a 500-parent threshold.

   **Scenario B:** #1 becomes head roughly 18–21 minutes after registration. Its one-hour oracle history does not exist. The next round cannot obtain the stipulated conversion.

   **Scenario C:** A parent crash reduces its genesis price 100-fold. The genesis floor expressed in parent tokens rises 100-fold, potentially exceeding achievable candidate absorption. Deployment-time checks do not prevent this.

   Moreover, mathematical absorption at enormous tail prices may exceed the parent’s entire available supply. `H ≤ 25% Ccurve` alone does not prove reachability.

   **Smallest fix:** Compare `Score/D` with `H`; define bootstrap history and stale-oracle behavior; prove attainable thresholds under parent inventory constraints. Clipping the genesis floor sacrifices that floor. Waiting an hour sacrifices immediate succession.

   Failed-round decay is attackable too: 22 cheap failed rounds reduce the unfloored component to approximately 9.85%. A fixed fraction of parent supply is not a stable $20–50 bond.

8. **Unrestricted pool initialization can permanently obstruct launches — high. Q2**

   **Scenario:** The factory’s next token address and PoolKey are predictable. An attacker initializes that key before token deployment, choosing an incompatible price. The factory later deploys the token and calls `initialize`, which reverts because the pool already exists.

   If the reverted deployment leaves the same next token address, repeated registration attempts hit the same poisoned pool.

   **Smallest fix:** Enable `beforeInitialize`; require the factory as the forwarded caller; authenticate the exact pending PoolKey and initial price. Every subsequent hook entry must reject unregistered pools. Deployment-plus-initialization atomicity alone does not prevent preinitializing a predictable address. [PoolManager initialization](https://raw.githubusercontent.com/Uniswap/v4-core/main/src/PoolManager.sol)

9. **Permissionless deployment sells treasury execution to sandwichers — high. Q2**

   **Scenario:** Consider a constant-product segment with virtual reserves `(100 parent, 100 child)`, with ticks covering these movements. The vault will buy using 100 parent.

   Attacker buys with 100 parent, receiving 50 child. Vault then receives only 16.67 child. Attacker sells its 50 child back and receives 180 parent: **80 parent gross profit**, before fees. This extracts value from the vault’s purchase without removing locked LP.

   **Smallest fix:** Enforce execution bounds independent of contemporaneous manipulated spot, bounded deployment sizes, and controlled tick placement. Require fresh observations or use a specified auction mechanism. Caller-supplied `minOut` is no protection when the caller is the attacker. Pay the bounty only on completed, verified deployment.

10. **The median cap still permits decisive spikes — medium. Q3**

    **Scenario:** Over 600 seconds, absorption is 1 parent except for one second at 301 parent. The true median remains 1:

    \[
    \mathrm{Score}=599+301=900
    =1.5\times600\times1.
    \]

    It beats an honest candidate maintaining 1.4 parent throughout, whose score is 840. Assume the curve accommodates 301 parent.

    This requires elapsed timestamp time; a same-timestamp flash round trip contributes zero under correct integration. The median cap nevertheless allows a **50% decisive uplift**.

    **Smallest fix:** Remove the claimed spike-immunity invariant. Specify duration-weighted histogram buckets, conservative quantile bounds, and the zero bucket. Tail extension must integrate the previous state only to `T_end`, update the histogram consistently, and freeze idempotently.

    Late registration grants copying/entry optionality, not extra scoring time if gates are correct. “Earliest attainment” needs a mathematical definition; selectable deployment addresses make hash-based ties grindable.

The remaining **Q2 execution constraints** are mandatory. Nested `unlock` calls revert; sequential unlocks in one transaction and reentrant pool actions during an existing unlock are distinct cases. Unsettled deltas revert the unlock. [Uniswap unlock accounting](https://developers.uniswap.org/docs/protocols/v4/guides/unlock-callback-and-deltas)

Native-ETH transfers require checks-effects-interactions and reentrancy protection around claims and frame mutation. Authenticate PoolManager and the forwarded calling contract; neither `hookData` nor an asserted EOA identifies an authorized frame.

Exact-input and exact-output swaps have different specified currencies; `afterSwap` return deltas address the unspecified currency. Partial fills require actual executed amounts. Reverted subcalls roll back their transient writes; splitting across transactions resets frames and is not independently an exemption. [Uniswap hook implementation](https://raw.githubusercontent.com/Uniswap/v4-core/main/src/libraries/Hooks.sol)

`beforeDonate` does not block direct transfers or `sync`. Those must never become score or pool-specific fee credits. Locker restrictions must authenticate the forwarded Locker caller, reject negative liquidity changes, and expose no generic execution or position-transfer escape hatch.

**The five required items:** Strongest economic attack: refundable slot rental, amplified by creator rebates and fee avoidance. Strongest architecture attack: the unenforceable transaction fee frame. Strongest score-selection manipulation: atomic submit-and-finalize exclusion. Weakest assumption: a publicly executing hook can know a secret endpoint. Most likely catastrophic edge: **generation #1**, where the proposed accumulator expressions encounter `N=0`; literal evaluation divides by zero before later depth problems matter.

For **Q5**, these are the depth-specific failure boundaries:

| Generation | Concrete failure or exposure |
|---|---|
| **1** | Current head is genesis, index zero: `j/N` and `A/(N^k Z)` require an explicit singleton case. Missing it can revert initial fee-bearing swaps. |
| **10** | Short oracle history already threatens earlier succession. ETH→#10 incurs **0.55–3.25%** per-hop loss before protocol fees and price impact. |
| **100** | Corresponding loss is **4.93–26.17%**. A multiplicative chain of 2% aligned price errors produces a **7.24×** conversion error. |
| **1000** | Loss reaches **39.38–95.06%**. Thousand-pool routing/oracle work needs measured gas bounds; no fit can be asserted. Individual ancestor claims become uneconomic to deploy. |

These fee figures use `N+1` pools and `1−(1−f)^(N+1)`. At 1,000, the quadratic accumulator denominator below is approximately `8.35×10^8`. Precision failure is not inevitable at that depth: scaling, multiplication order, signed arithmetic, and remainder handling determine it.

**Q6 verdict: as specified, a genesis tax funnel with an ancestor subsidy attached.** Upward routing spends existing fee assets; counting buy pressure at several links does not multiply their value.

For a bounded relative-rank subsidy, I would accept:

\[
w(r)=2-5r+4r^2,
\qquad
Z(M)=\sum_{j=0}^{M}w(j/M)
=\frac{(M+1)(5M+4)}{6M},\quad M\ge1.
\]

Here `M` is the traded token’s immediate-parent index, not the current head. Define the genesis-only beneficiary case separately.

This gives `w(0)=2`, `w(1)=1`, and minimum `7/16` at `r=5/8`. It is positive and normalized, but does not fix finding 3. With signed coefficients, arithmetic must avoid intermediate unsigned underflow.

I would accept it **without a fixed extra genesis floor**, with currency segregation and correct eligibility. At large depth, genesis’s polynomial share is approximately `2.4/M`; the newest ancestor’s is `1.2/M`. A hypothetical 10% fixed genesis floor makes genesis receive approximately **95 times** the newest ancestor’s all-ancestor-sleeve allocation at `M=1000`.

No fixed bounded polynomial eliminates that floor’s asymptotic dominance. Separate immediate-parent reinforcement can preserve a local subsidy; it does not validate the all-ancestor accounting or create sustainable returns.

**Q8 — delete:** Secret-end commitments; transaction-wide first/largest-leg exemptions; the fixed genesis floor; the chained genesis-TWAP threshold; optional creator buy-and-burn in v1; automatic-compounding language without an actual deposit mechanism; and the claim that the median cap prevents decisive short manipulation. Keep fixed supply, canonical competition, permanent positions, and transparent fees.

**Claims verified**

- The supplied closed forms imply cheap high-FDV traversal and reversible principal expenditure.
- The timing, unit, eligibility, and inventory contradictions above follow from the brief.
- Upstream v4 confirms the cited initialization, delta, and unlock constraints.
- The numerical examples and depth-fee calculations were calculated directly.

**Claims assumed**

- Research deployment addresses, competitor observations, and Robinhood configuration are accurate; this audit did not independently re-audit those deployments.
- Example curves are illustrative; v1 supplies no final standard-curve parameters.
- Honest demand, parent liquidity, keeper profitability, and market judgment provide no established security guarantee.
- Proposed contracts actually implement the promised immutable access restrictions.

**Irreversible actions and their guards**

- **Genesis creation:** Bind intended metadata, economics, and initialization atomically; prevent one-time genesis squatting.
- **Pool initialization and supply lock:** Factory authentication, exact keys/prices, tick-validity checks, exact inventory reconciliation, immutable Locker ownership.
- **Winner assignment and bond disposition:** Closed submission interval, correct head/round binding, normalized scores, one-time finalization, explicit bond accounting.
- **Fee allocation and claims:** Currency-specific solvency, bounded eligibility, remainder accounting, claim debit before transfer.
- **Buy-and-lock deployment:** Enforced execution bounds, correct inventory side, constrained ticks, funded claims, verified bounty payment.

**Unknowns and how to close each**

- **Actual curves and attainable thresholds:** Publish parameters; evaluate closed forms against available parent inventory and adversarial price paths.
- **Fee/execution specification:** Define route boundaries, fee currencies, exact-output behavior, partial fills, and whether snipe tax replaces or stacks with ordinary fees.
- **Runtime semantics:** Pin deployed PoolManager bytecode and ArbOS version; verify opcode, timestamp, and sequencing behavior.
- **Score implementation:** Differential-test duration histograms and frozen tails against exact integration, including negative net swap absorption where added liquidity funds withdrawals.
- **Accounting precision and scale:** Prove currency solvency and eligibility; benchmark adversarial histories at generations 1, 10, 100, and 1,000.
- **Immutable deployment safety:** Implement and adversarially test these guards before locking supply. Simulation cannot repair the specification contradictions.
