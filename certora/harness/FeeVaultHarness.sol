// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "v4-core/src/types/Currency.sol";

import {FamilyFactory} from "../../contracts/FamilyFactory.sol";
import {FeeVault} from "../../contracts/FeeVault.sol";

/// @title FeeVaultHarness
/// @notice VERIFICATION ONLY. It is never deployed, never imported by `contracts/`, and nothing in
/// `script/` or `test/` refers to it.
///
/// @dev WHY IT EXISTS. There is a Prover-internal crash raised while
/// transforming `FeeVault.receiveForward`, inside the analysis that rewrites a CONSTANT-SIZE RETURN
/// BUFFER allocation. The only return buffers on that method's path are the two external balance
/// reads inside {FeeVault.holdings}: the edge token's `balanceOf` and the PoolManager's ERC-6909
/// `balanceOf`. Five workarounds have been measured against the crash and every one was refused.
/// The reads cannot be summarized
/// away in CVL, because `holdings` is `public` and the Prover's internal-function finders only reach
/// `internal` and `private` functions. A harness that OVERRIDES the function is what is left, and it
/// is the one form of the idea that changes no deployed code: `contracts/FeeVault.sol` gains the
/// `virtual` keyword and nothing else.
///
/// @dev WHAT IT CHANGES, STATED PLAINLY SO NO RULE IS READ AS MORE THAN IT IS. Under this harness
/// `holdings(c)` is a plain storage read of {verificationHoldings}, which NO code in this tree ever
/// writes: the Prover therefore treats it as an arbitrary value that is FIXED for the whole
/// transaction, which is a sound over-approximation of a consistent view read but is NOT a
/// measurement of the vault's real token balance. Two consequences, both recorded in
/// `certora/specs/FeeVault.spec` beside the rules they touch:
///   - the delivery guards, the booking rules, the queue conservation and the decomposition mirrors
///     keep their full meaning: they are claims about the LEDGERS and about the guard's comparison,
///     and an arbitrary-but-fixed right-hand side is exactly what makes the guard's claim general;
///   - any rule whose content is "a payout LOWERS what the vault holds" loses its meaning here,
///     because a transfer no longer moves this number. Those rules are DISABLED in the spec with a
///     comment, never left to pass vacuously.
///
/// @dev STATUS: BUILT, COMPILED, AND NOT YET WIRED INTO A CONF.
/// The harness itself compiles cleanly in the Prover's own build and
/// the whole of `certora/specs/FeeVault.spec` type-checks against it EXCEPT the two storage hooks on
/// `ledgerTotal`, whose key is the `Currency` user-defined value type. With a DERIVED contract as
/// the verified one, no spelling of that key is accepted: `FeeVaultHarness.Currency`,
/// `FeeVault.Currency` (with and without `contracts/FeeVault.sol` in the scene),
/// `CurrencyLibrary.Currency` and `FamilyHook.Currency` are all rejected with
/// "keys to FeeVaultHarness.ledgerTotal should have type Currency but c has type Currency", and bare
/// `Currency` with "not a valid EVM type". Those two hooks carry `ghostLedgerTotal`, which the
/// delivery guards, the decomposition invariant and the two-sided `flushForwardConserves` are all
/// stated over, so the conf and the spec are left at their current form rather than weakened to
/// fit the harness. Six local type-checks, no submission spent. The file is kept because the
/// measurement and the shape are the deliverable.
///
/// No external call is made anywhere in the override, which is the whole point.
contract FeeVaultHarness is FeeVault {
    /// @notice The verification-only backing store for {holdings}, keyed by `Currency.unwrap(c)`.
    /// @dev Nothing writes it. It is left for the Prover to choose, and rules constrain it with
    /// `require` where they need a relation to the ledgers.
    mapping(address => uint256) public verificationHoldings;

    constructor(
        FamilyFactory _factory,
        address _developer,
        uint256 _creatorBps,
        uint256 _ancestorBps,
        uint256 _reinforceBps
    ) FeeVault(_factory, _developer, _creatorBps, _ancestorBps, _reinforceBps) {}

    /// @inheritdoc FeeVault
    /// @dev The override the whole harness exists for: one storage read, no external call, no return
    /// buffer to decode.
    function holdings(Currency currency) public view override returns (uint256) {
        return verificationHoldings[Currency.unwrap(currency)];
    }
}
