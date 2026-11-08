> Current status: the stream-size CI correction is independently **CLEAR** at
> `a3d3b540d4dcadc74ac855c6dc9c8eb73c407288`; see
> [incremental report](ELZ-011-size-clock-review.md). Fresh pinned `mix setup`
> and full default `mix check` on that code/test revision passed: 32 Ash + 642
> root tests, aggregate(44), all default individual consumers, ELZOO CHECK PASSED.
> [Review fixes](ELZ-011-review-fixes.md) records controlled before/after load
> reproductions, preserved size assertions, commands, timestamps and log hashes.
> The preceding full product CLEAR at `094eff1` carries forward. PR CI on the
> pushed head, coordinator queue/merge, merge-commit acceptance and cleanup remain.
> This is not merged acceptance.

# ELZ-011 production and acceptance record

Implementation source commit: `36384d4e90cf1487f17dfbb41322a06e59766ae0`.
Historical implementation validation below refers to source `36384d4`;
final fixed-source validation is recorded in ELZ-011-review-fixes.md. Independent review at `694fda8` was CONDITIONAL; see
[review](ELZ-011-final-review.md) and [fixes](ELZ-011-review-fixes.md).
Fixed source `087c1de` now passes fresh setup, full check (32 + 642 tests),
standalone export (221 tests, 114 hashes) and both isolated runtime checks.
[Fix evidence](ELZ-011-review-fixes.md) supersedes the historical counts below;
incremental review at `877357d` cleared the product fixes and requested only
T1 test synchronization. T1 and the export temp-directory issue are now fixed;
targeted 29, ten repeated rescued-job executions, and export 221 pass. See the
[record](ELZ-011-review-fixes.md); final narrow review and PR remain. This file is not an acceptance declaration and no merge is requested.

## Scope and approved Contract

Two new ready subsets on the task branch: core/effect and assembly/http-job.
Main acceptance still requires PR merge and its CI. No ready dependency source,
merged assertion, protected path or provider/toolchain pin is changed.
Root accepted D1–D5 (D3 A) in msg_18881a0d44c3 and R1 B/R2/R3 in
msg_98ca8e655f8f. The exact initial amendment was posted before body edit in
comment 6718026190, R1 before body edit in comment 6718187736 on #11.
Live/task bytes: 4391; SHA256
617508c89d83bdb197dd0dd77fca5b4dabf36092a5ddb950ac921824a63c8a9f.
Both approved patches and reviews remain in docs/work; no silent amendment.

ELZ-013 PR14 9999a3cf and ELZ-023 PR91 a5f0e63 are ancestors of this branch.
The other dependencies were checked at claim: ELZ004 PR32 81d7d21,
ELZ006 PR42 850abca, ELZ010 PR54 32aef4e. ELZ-023 main backend retry
42451768392/job128642319790 passed on macbook-ubuntu-elzoo-candidate with
32+613 tests, Gleam42450785134 passed; #37 is closed and its branch/worktree
removed. Final ELZ-023 report: issuecomment-6718089138 on #37.

## Resulting behavior

The declaration adds only capability, operation and classification around an
unchanged validated Envelope command. Admission requires integration/http,
publication, untrusted classification, command kind, schema elzoo/publication1,
explicit idempotency_key/deadline and exact binary JSON payload. Host tenant,
binding origin/id/operation and idempotency_key determine the stable key;
message_id never replaces the operation reference. Recovery-deadline overflow
is rejected before owner admission. The example executes admission without
implicit network, owner creation or queue registration.

Cure owns the pure runner action decision. The runner resolves an existing
owner, verifies key/active state, calls expiry, rereads state and makes one
owner-controlled dispatch/poll/rearm action. Confirmed finishes; Stranded and
quarantined Intended/Dispatched cancel; Definite disarm/quarantine and maximum
attempts cancel. Error replies and caller timeouts cannot create authority.
A timed-out queued owner call may still execute; later wakes reread it.

The fixed-origin Adapter uses Req with retry/redirect/automatic decode and
compression disabled. It sends exact validated bytes; string-key JSON duplicate,
byte, depth, node and schema checks also apply to responses. Truthful typed
preflight is the only rearm ground in this subset. No replay map or provider
no-effect/unknown-to-provider certificate is admitted. Every outer timer expiry
is unknown even during credential preparation. Authentication is host-supplied
and bounded; key/digest/MAC failures retain owner refusal evidence.

Every scheduled poll uses ceil(total_ms/1000)+1 ..30 seconds, finite grace and
ceil(grace/poll_ms)<=512. The ratio is explicitly not a bound on concurrent/
rescued wakes or the pre-deadline interval. Existing owner saturation fails
closed; host expiry/reconciliation remains required after job termination.
Separate finite task pools are a named construction Need, with task_spec/2 and
saturation tests. Observer fixed tags/elapsed time are bounded and contain no
payload, origin, key, header or raw exception. Cancellation reports an actual
job count plus unknown external outcome, never rollback or no-send.

## G1–G9 evidence map

| Gate | Implementation / executable evidence |
| --- | --- |
| G1 chronology, bounded transport | adapter.ex and call.ex; explicit typed pre-Req return only; hung credentials remain Dispatched; slow drip crosses per-read timeout while actual outer timer bounds it; real timer-source mutant violates elapsed bound |
| G2 origin binding | Binding macro stores origin in provider_account; configure and every send compare it; test altered context is permanent preflight refusal with no wire entry |
| G3 admission mapping | http_job.ex admission/2 and first test; explicit identity fields, command byte preservation, classification, schema and overflow refusal |
| G4 raw byte boundary | wire.ex request and response ordered-object duplicate validation, numeric/ack/UTF-8/control/depth/node/size checks, no key atomization; mutations of the actual normalizer detect retention/trust/ack/atom changes |
| G5 authenticated completion | real loopback HMAC key/digest/ack/kind/status; PostgreSQL Confirmed, retained forged key/digest/MAC refusals, duplicate completion and late contradictory completion quarantine |
| G6 rescue | real Oban worker lifecycle, live Engine rescue with simultaneous wake-ups, Lifeline plugin on explicit orphan executing row; host leadership is isolated in that fixture and no distributed election or new OS-kill proof is claimed |
| G7 caller capacity/unknown | finite caller-pool saturation, suspended-owner dispatch timeout then one wire request on resume/retry; observer throw/hang containment |
| G8 source mutations | actual runtime modules are temporarily compiled from mutated source then restored; retries/redirects yield extra wire requests; key mutation changes path; bypassing intent emits a forbidden extra PUT; raw-data properties and outer timer mutations also violate named assertions |
| G9 final validation | fresh setup/full check and standalone receipt/export execution recorded below; independent final diff review pending |

The tests use PostgreSQL for owners and Oban, not a Memory-only composition.
The fixture binds a per-test origin descriptor; the executable example exercises
the actual compile-time Binding macro. Request/response authentication remains
an external host/provider Need, not a locally proven cryptographic protocol.

## Grounding separation

Proof: no new quantified external-effect or arbitrary no-I/O proof is claimed.
Existing EffectIntent laws remain unchanged. Type/contract check: actual Cure
compilation of EffectDeclaration(a)/EnvelopeMessage(a) and HttpJobPolicy, strict
foreign-map/JSON checks, real Binding exhaustive failure-map compiler. Source
audits reject owned axioms, holes, unresolved/unaudited obligations and absurdity.
Tests: named ExUnit/PostgreSQL/Oban/loopback cases and actual-function mutations;
normalization idempotence is finite test evidence. Monitored behavior: observed
request counts/timings in those fixtures only. Upstream: Cure208248063,
Elixir1.20.4, OTP29.1.2, Req0.7.5, Jason1.4.5, Oban2.24.2 and unchanged Store/
PostgreSQL provider contracts. No dependencies were added or re-pinned.

## Commands and current validation

All Mix commands:

```sh
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'
export MIX_ENV=test
export ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:elzoo_elz024@localhost/elzoo_pieces_test
mix setup
mix check
mix run docs/work/ELZ-011-export-check.exs
```

Targeted iteration: `mix test pieces/core/effect/test pieces/assembly/http-job/test`
reported 24 passed before the final admission-overflow guard. The committed
source passed the standalone closure: `Result: 216 passed`, 114 matching receipt
hashes and `HTTP_JOB_NO_ROOT_APPLICATION`. The export includes its complete
selected dependency closure and the executable admission example. Full default
`mix check` exited 0 on the committed source: `Result: 32 passed` (Ash stage),
`Result: 637 passed` (root suite), and `ELZOO CHECK PASSED`. It completed at
2026-11-08T06:57:53Z, with root stage elapsed 973.2 seconds. The aggregate(44)
consumer completed its test and compiler-free runtime stages (254.4 seconds
total); all default individual consumer checks also passed.

The reproduction utility also contains a second VM runtime smoke excluding both
Cure and the root Elzoo paths. That new stage was executed separately against the
same already-built exported consumer using the utility's selected provider-path
closure: exit 0, `HTTP_JOB_COMPILER_FREE_RUNTIME_OK`. Neither Cure nor the root
Application is loaded or started; the admission example and actual Cure policy
execute. The whole utility was not rerun after adding this second stage; its
export/test stage and runtime stage have separate recorded executions.

Plain/live roadmap, ledger regeneration and ordinary working-tree diff checks
passed. Unified historical .patch files intentionally retain their context
spaces, so base-to-head git diff --check flags those patch context lines; no
production-source whitespace violation is being hidden. No workflow modification.

Failed experiments: initial declaration facade used binary instead of Cure's
nominal charlist String representation; corrected the measured ABI, no assertion
weakening. A source-mutation test initially had invalid Elixir sigil delimiters.
The Lifeline fixture initially cast database local now() into Oban's UTC
naive attempted_at column, making the attempt seven hours in the future; fixed
the raw SQL fixture to timezone('UTC',now()). This was a fixture error, not an
Oban runtime fix; the plugin and live rescue tests now pass. Prior proposal
probe failures are documented separately in ELZ-011-focused-probes.md.

## Limits and remaining work

No live vendor, TLS/DNS/proxy proof, physical cancellation, exactly-once external
commit, generic workflow engine, durable audit stream or hot reconfiguration.
The consumer owns Store durability, truthful adapter/credential observations,
stable origin/identity, MAC/credential policy, grants across restart, bounded
supervisor lifetime and fairness. Existing Jobs registration must be managed by
the host; unregistered queues retain the existing Jobs snooze behavior.
Lifeline is required for orphan executing rows and can rescue live executions.
Reconcile the existing job ID, not a new logical key or silently reset history.

Standalone and aggregate consumers reuse compiled upstream dependency artifacts
in new VMs and copy byte-identical source; this is not a cold dependency-fetch
or deployment test. Final independent review, claim removal, PR checks,
coordinator queue authorization/merge and main acceptance/cleanup remain.

## Completed committed-source standalone export

Exit 0: Result: 216 passed; 114 matching receipt hashes;
HTTP_JOB_NO_ROOT_APPLICATION. This includes the actual production source,
its entire exported dependency closure and the executable admission example.
Fresh setup and full check both exited 0 (32 + 637 passed). The standalone consumer
uses reused upstream BEAM artifacts, not an independent dependency download.

`/tmp/elz011-proposal/production-setup-final.log` SHA256 `78a904186dd01906e58f3e4ddcb367c4b44367f71bddf02fee236870bba7421d`.

`/tmp/elz011-proposal/standalone-export-final.log` SHA256 `2233b314db209c89b9e50e658e840a93742d0dbcc151744f77a295b89ed10ee5`.

`/tmp/elz011-proposal/compiler-free-runtime-selected.log` SHA256 `fe62f6d21b38997f9bbc16caf774fbe6c4e47ae07bbe21f7131dfb2d2c257c63`.

Runtime-stage scratch setup initially hit the exporter's correct overwrite
protection when re-planning into an existing consumer, then its missing-project
precondition on an empty destination; neither attempt executed the runtime stage.
The successful reproduction planned in a fresh minimal Mix directory and used
the previously built consumer unchanged.

`/tmp/elz011-proposal/production-full-check.log` SHA256 `c646ec1ea03a6ae55fe93bfa9439ba232fe98f7403e79c81d63e35b88d4d6c55`.

The checked source, tests, metadata and task body remain byte-identical to
`36384d4`; only this evidence report and the export reproduction utility were
updated after the full-check command began. Independent review will name the
final documentation head separately.
