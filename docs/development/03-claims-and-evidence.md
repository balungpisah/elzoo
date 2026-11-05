# Claims and evidence

Each task and PR states the claim and the grounding that supports it. Use the
architecture labels consistently; evidence and assumptions remain distinct:

| Grounding | Can support | Cannot silently support |
| --- | --- | --- |
| Proof (`P`) | A named quantified or exhaustive Cure law checked by Cure | All behavior, an unmentioned law or external implementation |
| Type/contract check (`T`) | The interface or schema checked by the named tool | All behavior; an unchecked Elixir typespec is documentation |
| Test (`X`) | Named executable scenarios and negative controls | A universal property or untested failure mode |
| Monitored behavior (`M`) | An observation in a named runtime/environment | A proof of future executions |
| Upstream contract (`U`) | A pinned Cure/Elixir/OTP/library behavior we rely on | Ownership or proof of the external implementation |

An explicit assumption (`A`) records an unverified precondition or trust
boundary. It does not itself establish the claim; keep it visible alongside
the evidence and limits.

Use a table like this in reports:

    Claim: duplicate input inside the configured window emits at most once.
    Proof: selected Cure law window_duplicate_idempotence, command: ...
    Test: same key, boundary key and out-of-window key, command: ...
    Monitor: none in this task.
    Upstream: OTP ordering for one sender, OTP 29.1.2.
    Limit: no cross-sender ordering or replicated-storage claim.

Do not use verified as a blanket badge. Say selected law passes, listed
scenarios pass, or relies on OTP's documented contract. Better prose does not
upgrade an existing result.

## Proof selection

Task bodies name the laws that matter to the boundary: composition identity,
window behavior, replay, deterministic selection or an error invariant. The
runtime harness checks those selected proofs. Proof is optional when a claim
belongs to an external library or the task records another grounding. Every
operation does not need a law.

## Negative controls

Where named, keep negative controls executable and intentional: an incompatible
typed connection is rejected, a false law fixture does not pass, and a bounded
queue reports the stated overflow result. A negative control demonstrates that
the fixture detects that failure; it does not prove every failure is detected.

## External assumptions

Record exact versions and contracts for Cure, Elixir, OTP and maintained
libraries. Test this repository's translation and failure handling at the
Adapter boundary. An undocumented/version-sensitive behavior is an assumption,
not a local law by repetition.
