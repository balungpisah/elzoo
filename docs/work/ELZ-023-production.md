# ELZ-023 production evidence and review handoff

> Redacted before publication (ELZ-065): the password part of local test-database URLs (`ecto://user:…@localhost`) and role commands is replaced by an ellipsis; the recorded commands are otherwise exact.
> Redacted before publication (ELZ-070): local paths, session, dispatch, task and message ids, the test database name and role, and runner and machine names are replaced by placeholders or role words; hashes and byte-equality records in this file refer to the unredacted text.

This records the initial implementation handoff. For the subsequent independent
F1/F2 findings, approved corrections and fresh 32 + 613-test full check, see
[ELZ-023-review-fixes.md](ELZ-023-review-fixes.md).

ELZ-023: production prepared; full check passed; independent actual-diff review pending.
Branch/PR: `task/ELZ-023`, production head `fed4026ce85c5df3dae5fbf8126f5529ee61389a`; [issue #37](https://github.com/balungpisah/elzoo/issues/37); no PR yet.
Checks: targeted production suite exit 0, `Result: 44 passed`; fresh pinned setup exit 0; full check exit 0, `Result: 32 passed`, `Result: 608 passed`, `ELZOO CHECK PASSED`; roadmap write/plain/live, claim and diff checks exit 0.
Grounding: selected production Cure step laws and clean audit; real proof/scenario mutation controls; Memory and real SQL finite recovery/settlement scenarios; isolated copied/renamed source execution; upstream compiler/native primitives/Store/provider contracts remain explicit.
Limits: no exactly-once, authentication, physical send fencing/cancellation, machine-crash durability or separately mechanized trace induction claim; independent review and merge acceptance remain pending.
Open work: ELZ-023 independent final review, any findings, PR/authorized queue, main acceptance and cleanup.

Updated 2026-11-08 10:42 WIB. Commands run in
`<worktrees>/elzoo-ELZ-023` with Cure
`208248063d64e621782cd26dd30698ee42850a89`, Elixir 1.20.4 and OTP 29.1.2.
`origin/main` is `0a423705784f2c0223ed67d6f75bfdb5412845ce`, already an ancestor;
no rebase/force push. Only ELZ-023 metadata rows were integrated; no protected
file, existing test/assertion or dependency pin was authored here. Original
claim `5f62e64f63641ded4e51ab776257f974ad782d10` remains in history; removal is
`8cc9384b7a81b32bf5ec49cc8ed13dcaef34726b`.

## Authorized scope

Root R-A–R-F and A1/G1–G9 decisions remain controlling. The
[focused review](ELZ-023-focused-review.md) and
[handoff](ELZ-023-focused-handoff.md) are retained, including the historical
replay-history counterexample. The A1 before/after comment
[6716149455](https://github.com/balungpisah/elzoo/issues/37#issuecomment-6716149455)
preceded the body edit. Live issue/task equality is 16,468 UTF-8 bytes,
SHA-256 `b3fae2e02e9ee8789320e76491568759f9e9f28693b8cf5561bb086ccffeee58`;
only the ELZ-023 issue hash changed. No clean-release path was added.

## Implementation and evidence map

The [README](../../pieces/delivery/effect-intent/README.md) owns the precise
supported API, callbacks, limits and copying contract; the adjacent manifest
owns source dependency closure and claim-specific evidence. The owner calls the
actual Cure policy through validated Model/Policy translation. It reuses the
existing Store and Checkpoint; it does not implement another storage/CAS engine.

| Gate | Production/evidence location |
| --- | --- |
| R-A, eight result pairs, unconditional rearm, initial/positive dispatch | Cure origin/action/ground/count laws; owner barrier, schema, result-matrix and task-death tests; native positive first-send scenario |
| G1 monotone replay dependence and possible-send history | Cure flags and step laws; policy horizon mutant; owner test sends twice then refuses the third after replay-safe → no-send → expired horizon |
| G2 revision | Cure all-no-send/history guard; Model revision data; owner/schema and policy revision tests |
| G3 old completion/contradiction | Cure raw attempt-history traversal/classifier and quarantine laws; both-order and mixed-history tests in pure, Memory and SQL forms |
| G4/G5 bound trusted host grant | Owner nonce/generation/revision/digest check and reload; StoreHost CAS activation marker; marker-without-intent, field mismatch, every-restart read-only and competing SQL activation tests |
| G6 deadline | Binding checked addition, Cure arm/rearm/recovery guards; admission/grace/overflow/horizon cases |
| G7 numeric codec/fold | Actual canonical ETF roundtrip and policy replay, priority/evidence/event saturation, max layouts and limit-plus-one tests; actual owner preflights before append |
| G8 storage | README distinguishes payload/canonical size, per-checkpoint cap, measured cumulative layout, hard-cap cumulative bound, no pruning and separate activation-log overhead |
| G9 effects/recovery/export | Memory/SQL unknown append/checkpoint and late commit; delayed old task; malicious hidden transport resend negative; separate-VM original/renamed module/record-tag copy test; full-check 42-Piece aggregate consumer passed |

The source was generated by:

```sh
python3 docs/work/ELZ-023-generate-policy.py
```

It uses the committed template and independent explicit projection cases in the
generator; regeneration must be byte-identical. The selected laws are unconditional
step projections over well-typed Cure inputs with actual guards substituted, plus
history/guard helper laws. Their reachable-trace argument is stated in the README;
this is not an independently mechanized trace induction or proof of the Elixir
owner. Expected-case specifications are structurally close to the implementation.
Mutation tests deliberately alter the production source, not a disconnected toy.

Production safety corrections during integration (before the reported suite):
no poll-only provider certificate can originate from `send_effect/1`; failed
initial admission leaves the absent-model owner read-only. Both have new tests.
The linked-init-error test traps exits without removing its startup-refusal checks.
A further integration probe found known-attempt malformed external results were
rejected without their reserved first-refusal evidence; the owner now records
only an untrusted refusal digest, never settlement authority, and distinguishes
retained/refused from explicit not-retained. The new 1022-refusal saturation
scenario then commits reserved settlement and contradiction and recovers them.
It also asserts the exact Empty initial state; all previous assertions remain.

## Exact validation commands

Each Mix command below uses this exact prefix (including the own database):

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://<test role>:…@localhost/<test database>
```

Append the command shown to that prefix; it is not a shell command by itself.

| Command | Exit/result |
| --- | --- |
| `mix test pieces/delivery/effect-intent/test/elzoo/` | 0; `Result: 44 passed`, 30.9 seconds; `/tmp/elz023-a1/all-piece-v6.log` |
| `mix setup` | 0; exact locked dependencies fetched, compile and Ash setup; `/tmp/elz023-a1/setup-reviewed.log` |
| `mix check` | 0 at `fed4026`; `Result: 32 passed`, `Result: 608 passed`, `ELZOO CHECK PASSED`; `/tmp/elz023-a1/check-reviewed.log`; 924.9 seconds total |
| `python3 scripts/check-roadmap.py --write` | 0 |
| `python3 scripts/check-roadmap.py` | 0, 137 local links |
| `python3 scripts/check-roadmap.py --live` | 0, live Contracts match |
| `python3 scripts/check-claims.py` | 0, no tracked claim metadata |
| `git diff --check` | 0 |

Measured production size fixture prints:

```text
Effect-intent production capacity: model=706230 checkpoint=870232 reserved=870758 delta=66376
Effect-intent production cumulative checkpoint bound: 3229007872 bytes, plus SQL/index/append/replica overhead
```

README additionally records the conservative hard-cap total 4096 × 1 MiB =
4,294,967,296 encoded checkpoint bytes, plus append and host-log overhead.
These are encoding measurements/bounds, not disk durability or a deployment quota.
The SQL fixtures use random schemas in the disposable test database, real transactions,
no Sandbox masquerading as committed storage. The reference Host's authority and
provider authentication are explicit doubles in tests, never real credentials or
local proofs of authenticity.

## Integration audit corrections

Two earlier full-check attempts were deliberately stopped (SIGTERM) to fix
reproduced authority/retention defects; neither is full acceptance, regardless
of a shell exit status. The first lacked first-refusal retention for malformed
external results attributable to a known attempt. The second exposed a public
`observe/2` tuple path into the internal mapped-result branch, bypassing normal
observation authentication. Production now admits maps only at the public
observation command, wraps raw Adapter values separately from translated typed
failures, and rejects internal-tag forgery both at the facade and GenServer
message boundary. Three new authority tests cover public forged tuples, raw
Adapter forged mapped values, and undeclared/malformed return values; all retain
unknown/refused state without authorizing rearm. No earlier assertion was removed.

The interrupted second aggregate export produced 238 receipt hashes and all 13
ELZ-023 source files matched their originals; that read-only hash audit passed,
but the consumer execution was intentionally stopped and is not a green export
run. Final aggregate execution passed in the uninterrupted full check above.
The receipt from that interrupted run is `/tmp/elz023-a1/aggregate-receipt.json`.

## Final full-run evidence (10:42 WIB)

The uninterrupted full check at production commit
`fed4026ce85c5df3dae5fbf8126f5529ee61389a` ended at
2026-11-08 10:42:19 WIB (03:42:19 UTC), exit 0. Its final lines are:

```text
Finished in 908.7 seconds (51.7s async, 856.9s sync)
Result: 608 passed
ELZOO STAGE root_suite end utc=2026-11-08T03:42:19.700330Z elapsed=924.9
ELZOO CHECK PASSED
```

The earlier Ash stage printed `Result: 32 passed`. Every fixed per-ID consumer
(26), the OTP-only consumer, and the aggregate(42) were selected. The aggregate
Mix tests completed in 233.9 seconds, its separate runtime VM in 0.8 seconds,
and the complete aggregate step in 235.0 seconds. The actual aggregate receipt
at `/tmp/elz023-a1/reviewed-aggregate-receipt.json` records `fed4026`, 42 Pieces
and 238 matching file hashes; all 13 ELZ-023 source files match the frozen source.
The receipt's uncommitted flag reflects these pending documentation notes;
production files were committed and unchanged throughout this uninterrupted run.
This is an export using compiled upstream artifacts, not a cold dependency fetch
or a production release-assembly test.

Exact final commands, each exit 0:

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://<test role>:…@localhost/<test database> mix setup
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://<test role>:…@localhost/<test database> mix check
```

Final code-only validations are complete. Subsequent handoff commits contain only
these evidence/proposal notes; independent review must inspect the actual complete
diff at its recorded head, including the Contract amendment and acceptance list.

`setup-reviewed.log` SHA-256: `7f1e26655d1900d5b9906da91625ce65aaf3ec27a897abd4e7ad3ae94a91fb45`.

`check-reviewed.log` SHA-256: `9fc00d3872ce5c061973b0329fb847cedd541af910ef70892ecaaf814199ffb7`.

`all-piece-v6.log` SHA-256: `12c88a8337970cb8df992bafc31485a646da3263114319cbd69288b7d30d0110`.

`reviewed-aggregate-receipt.json` SHA-256: `f51b81148cdf89cbbd9cfcbc0df310ccbcc6abb758b8d0b59ba7fe2cadcc86de`.
