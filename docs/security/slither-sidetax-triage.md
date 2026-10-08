# Slither triage, side tax (commit 191fce6, 2026-09-29)

**Replaced by the venue lock (commit b4e42e0, 2026-10-01).** The per-transfer side-tax charge
this triage covers no longer exists: a chain coin now either trades on its canonical pool or
the transfer reverts (`NonCanonicalVenue`), and the fee is collected by the hook on the
parent/$DOLL side of a canonical-pool swap only. This file is kept as the historical record of
that review; see `docs/spec/PROTOCOL_SPEC.md` and `docs/spec/PROPERTIES.md` for the current
venue-lock behavior and `docs/security/PROPERTY_RESULTS.md` for the renamed Medusa properties.

Per-contract runs on FamilyToken, FamilyHook, FamilyFactory; delta against the accepted baseline and the morning's V2 runs. One low-severity hardening item (return-bomb in the hook's acceptCanonicalHook call), fixed in the follow-up commit; everything else false positive or by design.

# Slither delta review — side-tax commit (191fce6)

Scope: findings new since both the accepted baseline (`internal/docs/security/slither.json`)
and this morning's per-contract runs, whose first source element is in FamilyToken.sol,
FamilyHook.sol, or FamilyFactory.sol. All items below were confirmed via `git diff df8f9a8
191fce6` to sit inside the actual side-tax diff (creditCanonical, acceptCanonicalHook, the
successor walk, the credit-mask logic in registerPool, `_acceptsCredit`/`_credit`,
`sideTaxPpmFor`). The pre-existing `reentrancy-benign`/`reentrancy-events` finding on
`FamilyFactory.registerCandidate` was excluded: comparing full descriptions shows it already
existed this morning — the only text change is the new `sideTaxPpmFor(depth)` argument in the
`initialize` call, which is an internal view call, not a new external-call vector.

## Actionable / non-informational findings

1. **uninitialized-local**, Medium/Medium — `FamilyHook.sol:292`, `registerPool(...).mask`
   declared without an initializer, then conditionally set/`|=`.
   **Verdict: false positive.** Solidity always zero-initializes local `uint8`s; the logic
   (`mask = CREDIT_CHILD` then `mask |= CREDIT_PARENT`) relies on and gets that default. No bug.

2. **reentrancy-benign** / **reentrancy-events**, Low/Medium — `FamilyHook.sol:256`,
   `registerPool` calls out to `_acceptsCredit` (external call to each pool currency) before
   writing `creditMask[id]` and emitting `PoolRegistered`.
   **Verdict: true positive, benign as classified.** `p.registered = true` is written *before*
   the external calls, so a reentrant call into `registerPool` for the same pool id reverts with
   `PoolAlreadyRegistered` — the ordering slither flags can't be exploited to double-register or
   corrupt `creditMask`. No fix required.

3. **return-bomb**, Low/Medium — `FamilyHook.sol:306`, `_acceptsCredit` does
   `t.call{gas: g}(abi.encodeCall(ICanonicalCredit.acceptCanonicalHook, ()))` on an
   attacker-influenced currency address (a candidate's "parent" token, supplied via
   `FamilyFactory.registerCandidate`) and lets Solidity copy the full return data into memory.
   **Verdict: true positive, low severity.** The gas cap on the call doesn't cap the memory-
   expansion cost of copying an oversized return value back to the caller; a malicious token
   could grief `registerPool`'s gas cost. No funds at risk (call site only reads `ret.length`
   and a `bool`), but worth hardening to the same `staticcall` + bounded `returndatacopy` pattern
   already used in `_staticAddress`/`_staticBool` (FamilyHook.sol:669-687).

4. **timestamp**, Low/Medium — `FamilyHook.sol:316`, `_credit`: `delta != 0`.
   **Verdict: false positive.** `delta` is the signed v4 settlement delta (int256), not a
   timestamp; the heuristic misfires on the nonzero-comparison shape.

5. **events-maths**, Low/Medium — `FamilyToken.sol:154`, `initialize` sets `sideTaxPpm` with no
   matching event.
   **Verdict: true positive, informational.** `sideTaxPpm` is a public state variable readable
   on-chain immediately after init, so there's no integrity gap — only an off-chain indexing
   convenience (an indexer has to read state rather than an event to learn a token's side tax).

6. **missing-zero-check** ×5, Low/Medium — `FamilyToken.sol:138-139`, constructor params
   `factory_`, `poolManager_`, `hook_`, `locker_`, `feeVault_`.
   **Verdict: false positive by design.** Per the contract's own doc comment, these are all
   CREATE2-predicted addresses that `FamilyFactory`'s constructor cross-verifies against its own
   predictions; a zero address here would fail that independent check elsewhere in the wiring,
   not silently brick the token.

## Informational / optimization — summarized by detector

- **assembly** (7): `FamilyToken.sol` — `creditCanonical`, `canonicalNet`, `_staticAddress`,
  `_update`, `_consume`, `_probe` (6, lines 178/196/250/268/308/333); `FamilyHook.sol` —
  `_acceptsCredit` (1, line 306). Expected: transient-storage counter + gas-capped static probes,
  matching the assembly style already accepted elsewhere in this codebase.
- **naming-convention** (6): `FamilyToken.sol` — `POOL_MANAGER`, `HOOK`, `LOCKER`, `FEE_VAULT`
  (lines 71/73/76/76); `FamilyFactory.sol` — `VENUE_TOLL_PPM`, `HOP_FEE_PPM` (lines 170/172).
  Deliberate ALL_CAPS immutable convention, consistent with the rest of the codebase.
- **low-level-calls** (1): `FamilyHook.sol:306`, same call as the return-bomb finding above —
  already covered there.
- **missing-inheritance** (1): `FamilyToken.sol:63` — suggests `FamilyToken` formally inherit
  `ICanonicalCredit` (it already implements `creditCanonical`/`acceptCanonicalHook`/
  `canonicalNet`/`isCanonicalHook`, just called through the interface from `FamilyHook` without
  declaring conformance). Style-only, no behavior change.

## Bottom line

No new high/critical findings. One real (if low-severity) hardening item: #3, the return-bomb
in `_acceptsCredit`, worth aligning with the existing bounded-staticcall helpers before the next
audit pass. Everything else is either a slither heuristic misfire (#1, #4, #6) or accepted by
design/style (#2, #5, informational section).
