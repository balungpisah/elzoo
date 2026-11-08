# ELZ-011 independent early Contract review

> Redacted before publication (ELZ-065): the password part of local test-database URLs (`ecto://user:…@localhost`) and role commands is replaced by an ellipsis; the recorded commands are otherwise exact.

Reviewer: Orca session 0f974e4c-75e1-4daf-9a19-7720ad2b1633 (task_a659ec353b6d, dispatch ctx_4a3fb5dd7ad9).
Reviewed head: `0716e36865782847a9a786aa9d4ac28c7b1c5766` on `task/ELZ-011`
(worktree `/Users/laptopdp/orca/workspaces/elzoo/elzoo-ELZ-011`, base `a5f0e630f61e93893f1a2c706268226681ca593a`, claim `2a9efcd`).
This is early review permission only. It is not production acceptance.
No tracked file, issue, metadata, branch, pin or test was changed. The worktree stayed clean (`git status --short` empty before and after each probe).

## Verdict

**NOT CLEAR as written. CLEAR after the owner decisions and proposal amendments below.**

- D1: CLEAR with a small amendment.
- D2: CLEAR with amended text.
- D3: OWNER DECISION needed (two options, recommendation given).
- D4: NOT CLEAR. Four high findings and several medium findings must be frozen in the proposal first.
- D5: CLEAR with added acceptance text.

## Evidence I collected

| Item | Command or source | Result |
| --- | --- | --- |
| Probe reproduction | `env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test mix run docs/work/ELZ-011-probes/boundary.exs` | exit 0, `Result: 14 passed`, log `/tmp/elz011-probe.log` |
| Probe file hashes | `shasum -a 256 docs/work/ELZ-011-probes/*` | `boundary.exs` `80d075c5…e0b4`, `hex-metadata.json` `b56b2446…5c43`. Both match the proposal. |
| Owner seam probe (mine) | `/tmp/elz011-review-probes/intent_seams.exs`, log `intent_seams.log` | exit 0. Results in H2, H3, M1. |
| Req timing probe (mine) | `/tmp/elz011-review-probes/slow_drip.exs` | exit 0. Results in H4 and M9. |
| Sources read | `effect_intent.ex`, `binding.ex`, `policy.ex`, Cure guards (`effect_intent.cure` lines 40-330), effect-intent README, `jobs.ex`, Jobs worker (first 120 lines), Envelope README, task body, catalogue and release-plan rows | see findings |
| Oban behavior | Context7 `/oban-bg/oban` (docs, not source) | snooze, cancel and uniqueness facts used below |

The probe is sound for what it claims: one wire request for PUT 200/503/307, body limit at limit and limit+1, lost acknowledgement, receive timeout, caller kill, normalization. Req and Finch both pass.
Its limits:
- The two "negative controls" (`retain_mutant`, `trust_mutant`) build a hand-made wrong map and assert it differs. They do not run a wrong implementation. They cannot fail if the real `normalize/1` is changed.
- No case shows that the default Req retry setting would send twice. Req's default retry mode does not retry PUT, so the probe would also pass without `retry: false`.
- The probe starts from a decoded map. It does not test raw bytes through the JSON decoder (atoms, duplicate keys, depth).

## Findings (most severe first)

### HIGH

**H1. The wire protocol contradicts itself about no-effect evidence.**
Proposal line 140-141 says "Only attested pre-transport typed failure or final authenticated no-effect poll evidence may yield the existing intent's grounds." Lines 172-179 exclude final no-effect and replay.
There is a second, worse consequence in the ready owner. In `effect_intent.cure`, a `ProviderUnknown` event with no replay moves a Dispatched intent to **Stranded** at once. A poll that returns `{:unknown_to_provider, _}` and passes `authenticate/2` would therefore strand the intent on the first 404.
Required: the binding's `authenticate/2` returns `:error` for `:no_effect` and `:unknown_to_provider`. `poll/1` returns only `{:pending, _}` or `{:unavailable, _}`. A 404 is always `{:unavailable, _}`. Add a negative control that fails if a 404 becomes `:unknown_to_provider` or `:no_effect`. Delete the quoted sentence.

**H2. The job action table is not total and not implementable as written.**
My probe on the real owner (Memory store) shows:
- Intended past the admission deadline: `advance(:expire)` returns `{:ok, :Stop}` and changes nothing. `advance(:dispatch)` returns `{:error, :not_dispatchable}`. Status is unchanged (`{:Intended, :Fresh, 0}`). `status/1` has no deadline, so the row "before deadline" cannot be tested by the runner.
- Definite after `PermanentNoSend`: `flags.disarmed` is `true`. `advance(:rearm)` returns `{:error, :not_rearmable}` every time. The proposed row "Definite ... `advance(:rearm)`" would loop forever.
- Oban docs: a snooze rolls the attempt back, so snoozing never exhausts `max_attempts`. Every row that snoozes is unbounded unless the intent itself reaches a terminal phase.
- Jobs uses `unique: [keys: [:queue, :job_key], period: :infinity, states: :all]`. A cancelled or discarded job for a key blocks a new insert of that key until the Oban Pruner removes it. The proposal does not say how a host wakes an operation after reconciliation.
The proposal also does not give the Oban return value for any row, nor the handling of owner error replies (`:not_dispatchable`, `:not_rearmable`, `:task_start`, `:read_only`, `:schema`, `:clock_or_deadline`, exits).
Required: freeze the total table in "Proposed frozen job table" below. Add tests for every row, including the two loops above.

**H3. A poll during the send is not safe, and the runner cannot see it.**
`status/1` has no "task in flight" field. My probe: dispatch with a slow send, then `advance(:poll)` with a supervisor of `max_children: 1` returns `{:error, :task_start}`. The owner appends a counted `Lost` event (revision advanced from 3 to 4 across the call). This costs one of the 4096 events each time.
The proposal allows a polling delay of 1 s and a total request time of 3 s. So an early poll will collide with the send.
Required: after `{:ok, :dispatched}` the first wake-up is at least `ceil(total_ms/1000) + 1` seconds. `{:error, :task_start}` is a retryable wait. It is never a no-send. Add a construction check: `recovery_grace_ms / poll_delay_ms` must be at most 512, so polls cannot fill the 1024 routine allowance or the 4096 event bound.

**H4. The "total" request time limit does not exist unless the Adapter builds it.**
Probe: server sends one byte every 50 ms; Req has `receive_timeout: 200`. The request ran **3100 ms** before it ended. Req and Finch time out per read, not per request. The owner never times out its task (it only uses `brutal_kill` at shutdown). A stalled Adapter keeps the only `max_children: 1` slot, so every later poll returns `:task_start`.
Required: the Adapter runs the request in an inner task with `Task.yield/2` then `Task.shutdown(:brutal_kill)` at the total limit, and returns the timeout tag. Add a slow-drip test and a negative control that removes the inner limit and fails. State that the kill does not retract a request already on the wire.

### MEDIUM

**M1. The only automatic rearm path is thin and unnamed.**
The owner validates the schema before it reserves an attempt. So a "local preflight failure" can occur only in a step the Adapter runs after the reservation (credential or config lookup, request build). The proposal names no tag. My probe confirms the path works: a typed `not_dispatched` tag gives `{:Definite, :AdapterNoSend, 1}`, `advance(:rearm)` gives `{:Intended, {:After, :AdapterNoSend}, 1}`, and a second dispatch runs.
Required: name the tags (see the failure map below). The attestation is true only if the tag is returned before `Req.request/1` is called. An exception or exit after that call is unknown (the owner records `Lost` from the task `:DOWN`). Add a negative control that injects a failure after the call starts and must not give no-send.

**M2. The row-to-result table has gaps.** Missing: PUT 2xx with `ack=false`; 2xx with an invalid, oversize or unauthenticated receipt; 202; 409/422 for a same-key changed body; `Content-Encoding` not identity (the probe shows Req with `compressed: false, raw: true` passes the header and bytes through, so the Adapter must check the header); 401/403/429. The mismatch row ("refused observation") is reachable only if the Adapter returns the Envelope and lets `validate_result/authenticate` refuse it. Freeze one choice (see the frozen table).

**M3. Binding digest does not cover origin or credentials.** The digest covers adapter, id, provider_account, operation, clock, failures, attestations, grace, replay, revision. Origin and credentials travel in `adapter_context`, which the digest ignores. A changed origin after restart is invisible. Required: put the fixed origin identity into `provider_account` (part of the identity and the digest) so a different endpoint gives a different key. State that the host keeps it stable. Also: the owner key is a 64-hex SHA-256. The job key must be that key, and the PUT path segment must be only that key (never the host logical reference, which can hold `/`).

**M4. Authentication is named but not defined.** "Authenticated receipt" has no mechanism. Required: a host-supplied authenticator in `adapter_context` (for the fixture, HMAC over key, digest, status). Tests must include a forged receipt and a receipt with a correct key but bad MAC. TLS and DNS stay Needs.

**M5. Control calls can wedge the Oban worker.** `advance/2` uses `:infinity`. A stuck Store write blocks the job process. A dead pid makes `GenServer.call` exit. Required: the runner catches exits, wraps each control call in a bounded caller task (`Task.yield` then shutdown), and treats a timeout as unknown (never a retry of the send). Oban `cancel_all_jobs` kills an executing job (Oban docs), which is harmless only because the job process is a control caller.

**M6. Observer.** Required: call the observer only in the job process, never inside the Adapter task, with exceptions caught. Test a throwing and a hanging observer. Hanging latency is a named Need unless isolated with a bounded task.

**M7. Normalization needs a byte-level test.** Start from raw response bytes: size check before decode, string keys only (no atom keys option), duplicate JSON keys (`{"ack":false,"ack":true}` — the decoder's rule must be stated and tested; reject is safest), integers versus floats, depth and node bounds on the decoded term. Production negative controls must run mutants of the real function (retain unknown fields, upgrade trust, atomize keys, guess `ack`), not hand-built maps.

**M8. Stranding needs a caller.** `Stranded` happens only when something calls `advance(:expire)`. If the Oban job ends first, a Dispatched intent stays Dispatched. State this as a host Need and test "job exhausted while Dispatched".

**M9. `core/effect` overlaps Envelope.** See D3.

### LOW

- L1. The Hex metadata file is a dated maintenance snapshot. The proposal says so. No action.
- L2. The 120 ms duplicate window is finite. The proposal says so. Keep the production audit of the retry option.
- L3. `cancel/3` returns the Oban count. `{:ok, 0}` means nothing was cancelled. Do not report it as success or no-send.
- L4. ELZ-013 (`integration/http`) is reused as a recipe but is not listed in Dependencies.

## Proposed frozen failure map (for the binding)

| Tag | Result triple (outcome, dispatch, class) | Attested no-send | Owner event |
| --- | --- | --- | --- |
| `:preflight_unavailable` | timed_out, not_dispatched, unavailable | yes | NoSend, then rearm allowed |
| `:request_rejected` | rejected, not_dispatched, permanent | yes | PermanentNoSend, disarmed |
| `:http_4xx` | failed, dispatched, permanent | no | Failed, then poll |
| `:http_5xx` | failed, dispatched, retryable | no | Failed, then poll |
| `:http_redirect` | failed, dispatched, unclassified | no | Failed, then poll |
| `:not_acknowledged` (2xx, `ack=false`) | unknown, dispatched, unclassified | no | Lost, then poll |
| `:receipt_invalid` (2xx, bad bytes/encoding/oversize) | unknown, dispatched, unclassified | no | Lost, then poll |
| `:transport_timeout` | timed_out, unknown, retryable | no | TimedOut, then poll |
| `:transport_error` (reset, refused, inner task killed) | unknown, unknown, unavailable | no | Lost, then poll |

A valid 2xx receipt with `ack=true` returns the completed Envelope. A receipt with a wrong key or digest, or a bad MAC, also returns an Envelope; `validate_result/authenticate` refuse it and the owner retains a bounded `Refused` summary. Poll results: 2xx `ack=true` is a completed Envelope; `ack=false` is `{:pending, _}`; 404, 5xx and transport errors are `{:unavailable, _}`.

## Proposed frozen job table (runner `perform/1`)

Pre-step on every wake-up: resolve owner; check `status.key` equals the job key; check `status.active`; call `advance(:expire)`; reread status.

| Condition | Action | Oban return |
| --- | --- | --- |
| Resolver error, exit, key mismatch, `active: false` (read-only or halted) | no send | `{:error, :owner_unavailable}` (uses an attempt and `backoff/1`, so it is bounded) |
| Phase Intended | `advance(:dispatch)`: `{:ok, :dispatched}` | `{:snooze, first_poll_delay}` (at least total + 1 s) |
| Phase Intended and `{:error, :not_dispatchable}` | none | `{:cancel, :not_dispatchable}` |
| Phase Dispatched | `advance(:poll)`: `{:ok, :polling}` | `{:snooze, poll_delay}` |
| Phase Dispatched and `{:error, :task_start}` | none | `{:snooze, poll_delay}` |
| Phase Definite, `flags.disarmed` or `quarantined` | none | `{:cancel, :operator_required}` |
| Phase Definite, persisted attempts below host maximum | `advance(:rearm)`: `{:ok, :Stop}` | `{:snooze, 1}` |
| Phase Definite and `{:error, :not_rearmable}`, or attempts at maximum | none | `{:cancel, :exhausted}` |
| Phase Confirmed | none | `:ok` |
| Phase Stranded | none | `{:cancel, :operator_required}` |
| Any other control error or timeout | none, never a send | `{:error, tag}` |

Host re-wake after reconciliation uses the existing job (for example `Oban.retry_job/2`). I did not verify which Oban states `retry_job` accepts. The implementer must test it with real Oban, because the unique rule blocks a second insert of the same key.

## Decision dispositions and exact text for root

### D1 — CLEAR with amendment
Add ELZ-023 (required) and ELZ-013 (the task already requires reuse of its recipe).
Before: `- Dependencies: ELZ-004, ELZ-006, ELZ-010`
After: `- Dependencies: ELZ-004, ELZ-006, ELZ-010, ELZ-013, ELZ-023`

### D2 — CLEAR with amended text
Append to Outcome, after `not another HTTP client.`:
`The selected Effect publishes one bounded JSON object under an immutable logical key at a consumer-controlled HTTP endpoint. Reuse delivery/effect-intent and integration/jobs; never call HTTP through assembly/durable-job's pure handler. Job retries inspect or poll the existing intent; only its durable permitted ground can authorize a later dispatch. This subset records only attested typed local no-send as a ground; final provider no-effect and provider replay are excluded. Every recovered intent remains read-only until the bound host grant required by its ready Contract. Cancellation stops future job wake-ups only and never retracts a dispatched request. Evidence is loopback/provider-double and real PostgreSQL/Oban composition, not a live vendor integration.`
The two added sentences (grounds excluded; cancellation) are my additions to the proposal text.

### D3 — OWNER DECISION (choose one; I recommend A)
Finding: of the eight proposed `EffectRequest` fields, five duplicate Envelope fields (`operation_id` = `message_id`/`idempotency_key`; `payload_schema_id`/`payload_schema_version` = `schema_id`/`schema_version`; `payload`; `version`). Only `capability_id`, `operation` and `classification` are new. `declared?/2` is a list membership check. A second Envelope would be redundant and would add a second validator.
- **Option A (recommended):** keep `core/effect` as a thin data declaration that carries an Envelope command. It adds only `capability_id`, `operation`, `classification` and reuses `Elzoo.Envelope.validate/1` for the rest. `assembly/http-job` must consume it at admission (derive identity and arguments from it), or it is an orphan. Add to Scope: `- core/effect is a data-only declaration (capability_id, operation, classification) carried in an Envelope command. It reuses Envelope identity, schema and payload fields. It adds no executor, dispatcher or authorization.`
- **Option B:** defer `core/effect` (it stays planned). Amend the Catalogue IDs line and acceptance 1 to say the no-I/O evidence is a test of the Operator output type. This is smaller but leaves the catalogue ID unbuilt.

### D4 — NOT CLEAR until frozen
Apply H1-H4, M1-M8 and the two frozen tables above to `docs/work/ELZ-011.md` (the proposal), then root accepts. The sentence at proposal lines 140-141 must be deleted. Persisted attempt counting (by `status.attempts`) is supported by the ready facade. The key-resolver restart Need is supported: a recovered owner is `active: false` until the host grant, so a job can never recreate it.

### D5 — CLEAR with added acceptance
Add after the existing sixth acceptance bullet:
```
- [ ] Every HTTP and transport outcome maps to a frozen Envelope or typed failure row;
      cancellation is job-control only and is never reported as no-send.
- [ ] No second dispatch occurs without a durable permitted ground; HTTP is never
      called from assembly/durable-job's handler.
- [ ] The total request time, response size bound and slow-drip stall are executable
      with negative controls; redirect, retry, atom-minting, trust-upgrade,
      field-retention and ack-guessing mutants of the real code fail.
- [ ] Read-only recovery, job exhaustion while Dispatched and the unique-key re-wake
      path are exercised with real PostgreSQL and Oban.
```
Before: the Acceptance list ends with the bullet that starts `Listed malformed inputs are rejected`.

## Limitations of this review

- I did not run `mix check`. It has not been run for this delta, and I do not claim it.
- I did not read in full: `assembly/durable-job`, `integration/http` tests, `runtime/adapter`, `delivery/retry-timeout`, `integration/json` source, the effect-intent test files for this task, or the Jobs worker beyond its first 120 lines.
- My owner probes used the volatile Memory store, not PostgreSQL, and a fake Adapter. They prove owner behavior at that boundary only.
- Oban facts come from Context7 documentation, not from the pinned 2.24.2 source. `Oban.retry_job/2` state coverage is unverified.
- The slow-drip probe shows one server pattern on loopback. It does not cover TLS, DNS or proxies.
- Scratch probes remain in `/tmp/elz011-review-probes/` so the report can be reproduced. Delete them after root reads the report.
