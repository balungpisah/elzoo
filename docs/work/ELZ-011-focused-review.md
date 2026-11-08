# ELZ-011 focused independent re-review

Reviewer: Orca session 0f974e4c-75e1-4daf-9a19-7720ad2b1633 (task_084cfc62f54f, dispatch ctx_4b5c11a942ed).
Reviewed head: `7766446c40a88ad2be60ee51aaef59deb8e76c06` on `task/ELZ-011`
(`/Users/laptopdp/orca/workspaces/elzoo/elzoo-ELZ-011`, base `a5f0e630f61e93893f1a2c706268226681ca593a`).
Earlier review: `/tmp/elz011-early-review-report-0f974e4c.md` (head `0716e36`, NOT CLEAR).
This is permission for implementation only. It is not production acceptance.
No tracked file, issue, branch, pin or test was changed. `git status --short` was empty after every command, and HEAD stayed `7766446`.

## Verdict

**NOT YET CLEAR. Three small root decisions remain (R1, R2, R3). After root accepts them, implementation can start.**
Everything else from D1-D5 and H1-H4 is closed, or it is a production gate that the implementer must meet. I found no blocker in the dependencies, the live issue text, the PostgreSQL probes or the pinned Oban source.

- R1 (placement wording, text only): the Scope sentence says "carried in an Envelope command". The proposal builds a wrapper that holds the command. Root must confirm the wrapper reading.
- R2 (job table, one new row): a quarantined Dispatched intent never strands. The frozen job table has no row for it, so a job would poll for ever.
- R3 (poll delay): only the first poll delay is bounded below by the request time. Later polls can overlap the previous task.

## Evidence

| Check | Command or source | Result |
| --- | --- | --- |
| Head and tree | `git rev-parse HEAD`; `git status --short` | `7766446c…`; empty |
| Live issue equals task | `gh issue view 11 -R balungpisah/elzoo --json body`, first 4359 bytes, `cmp` with task file | equal; SHA-256 `4d811943c4d3ce87289f6dd24619b9862174876490d40d165b7f70a23c105183` (the `gh` output adds one newline: 4360 bytes) |
| Posted patch reproduces task | `patch` of `docs/work/ELZ-011-contract-proposed.patch` on the base task file (`d75ae31c…`), then `cmp` | identical to the task file |
| Task diff | `git diff a5f0e63 HEAD -- tasks/…` | only the approved dependency, Outcome, Scope and acceptance text. Matches comment 6718026190. |
| Ancestry | `git merge-base --is-ancestor` on `origin/main` (`a5f0e63`) | ELZ-013 `9999a3cf…` and ELZ-023 `a5f0e630…` are both ancestors |
| Roadmap | `python3 scripts/check-roadmap.py` and `--live` | both exit 0 (97 IDs, 76 jobs, views agree, live Contracts match) |
| Probe 1 | `mix run docs/work/ELZ-011-probes/composition.exs` (own DB, locale prefix as dispatched) | exit 0, `Result: 8 passed` (`/tmp/elz011-rereview/composition.log`) |
| Probe 2 | `mix run docs/work/ELZ-011-probes/timing-json.exs` | exit 0, `Result: 21 passed` |
| Probe 3 | `python3 docs/work/ELZ-011-probes/mutate-composition.py` | exit 0. The mutant run exits 2 with the expected failing test. |
| Probe hashes | `shasum -a 256 docs/work/ELZ-011-probes/*` | all five match `ELZ-011-focused-probes.md` and the earlier proposal |
| Pinned Oban | `deps/oban` is 2.24.2 in `mix.lock`; SHA-256 of `oban.ex` and `engines/basic.ex` | both match comment 6718031813. `retry_all_jobs` excludes `available` and `executing`, sets `max_attempts = GREATEST(max_attempts, attempt + 1)`, and `retry_job` returns `:ok` without checking rows. |
| My quarantine probe | `/tmp/elz011-rereview/quarantine.exs` (log `quarantine.log`) | exit 0. Shows R2. |
| My Jason probe | `/tmp/elz011-rereview/jason_edges.exs` | exit 0. Jason 1.4.5. See G4. |
| Early review copy | `diff` of my report against `docs/work/ELZ-011-early-review.md` | no difference |

`git diff --check a5f0e63 HEAD` exits 2 only because the `.patch` file holds context lines that end in a space. That text is correct for a patch. Check that CI does not run this range check on `docs/work/`.

## Disposition of D1-D5

- **D1 CLOSED.** Dependencies line is `ELZ-004, ELZ-006, ELZ-010, ELZ-013, ELZ-023` in the task, the live issue, `release-plan.json`, `dependencies.mmd` and `views.md`. Both ancestors are on `origin/main`. The view change also moves the ELZ-023 row, which is the generator's order only.
- **D2 CLOSED.** The Outcome paragraph is the approved text. It states the grounds exclusion, read-only recovery and job-control-only cancellation. Cosmetic only: the new Scope bullet and the four acceptance bullets sit after a blank line, so Markdown renders them as separate lists. Do not edit the approved bytes; a later task-body amendment can tidy this.
- **D3 OPEN, R1.** See "core/effect placement".
- **D4 CLOSED except R2 and R3.** See "H1-H4 and medium dispositions".
- **D5 CLOSED.** The four acceptance bullets are present and match the approved text. The proposal's production gates cover each bullet. Gaps in the reduced probes are listed under G1-G9.

## core/effect placement

What the proposal says: a Cure declaration with `capability_id`, `operation`, `classification` plus a `command` field that holds the unchanged, validated Envelope. It repeats no identity, schema or payload field, reuses `Elzoo.Envelope.validate/1`, adds no executor, and the assembly derives identity and arguments from the command at admission.

This realizes the approved Scope on every point except one word. The approved sentence says the declaration is "carried in an Envelope command". A wrapper does the opposite: the declaration carries the command. The two readings differ in a real way:
- Wrapper (proposal): the Envelope stays unchanged and its payload stays the publication bytes. The declaration is an ordinary Operator output. It cannot cross a Unit port that expects an Envelope unless the host unwraps it.
- Payload-embedded: the declaration would sit inside the opaque Envelope payload. That conflicts with the Envelope Contract (payload opaque, never validated) and with the HTTP payload, which must be the exact bytes of the PUT body.

I recommend the wrapper. I did not reinterpret the scope; root must say which reading is intended.

**R1 options (choose one; I recommend A):**
- A: keep the text, and record in the proposal "carried in" means the declaration wraps the command.
- B: amend the Scope sentence.
  Before: `- core/effect is a data-only declaration (capability_id, operation, classification) carried in an Envelope command.`
  After: `- core/effect is a data-only declaration (capability_id, operation, classification) that wraps an unchanged, separately validated Envelope command.`

Admission mapping that the first slice must freeze before code (G3): the Envelope has no tenant; `message_id`, `idempotency_key` and the optional `deadline_unix_ms` each could feed the intent's logical reference or deadline. State exactly: which field is the logical reference (the fifth identity field), where tenant comes from (host configuration), which source sets the intent `deadline`, that `kind` must be `command`, that `payload` must be a binary equal to the PUT body (so the digest is over the bytes sent), and that `operation` and `capability_id` must equal the binding's fixed values. A `classification` of `trusted` must be refused or downgraded to untrusted, never used.

## H1-H4 and medium dispositions

| Finding | Status | Evidence |
| --- | --- | --- |
| H1 no-effect sentence and 404 strand | CLOSED | Sentence removed (`ELZ-011.md` lines 139-141). `authenticate/2` rejects `no_effect` and `unknown_to_provider`. The mutant (404 becomes `unknown_to_provider` and is authenticated) fails two named tests and the state becomes Stranded (`mutate.log`). |
| H2 total job table | OPEN, R2 | Table is total for the phases it lists. Gap below. |
| H3 poll during send | OPEN, R3 | Collision costs a revision and gives no ground (composition test 3). Only the first delay is constrained. |
| H4 total request time | CLOSED for the proposal | Slow-drip request lasts at least 800 ms, the 250 ms outer timer returns `total_timeout`, the child list is empty, and removing the timer fails the elapsed bound. Caller kill also kills the linked child. Production must wire the timer (G1). |
| M1 typed tags | CLOSED | All nine tags compile with the real Binding checker (composition test 1). Rearm after typed preflight works on PostgreSQL (test 4). Chronology caveat in G1. |
| M2 row table | CLOSED | Frozen in the decision packet; clarification 1 covers 202, 401/403/409/422/429, encoding, mismatch. |
| M3 origin and key | CLOSED with gate G2 | Owner enforces `account == provider_account`, `adapter == id`, `operation == operation` (`model.ex` lines 84-87), and the probe fixture failed once for wrong order. Context origin is not checked by the owner (G2). |
| M4 authentication | OPEN as a production gate | No probe uses a real MAC. The probe Adapter's `validate_result` returns `:error`, so no probe reaches Confirmed (G5). |
| M5 bounded control call | CLOSED | Timed-out dispatch still runs after resume; dead owner gives a fixed error (composition test 8). |
| M6 observer | CLOSED for the wrapper | Throw, raise and hang return unknown or timeout. Production must call the real observer through it. |
| M7 raw JSON | CLOSED for responses, G4 for requests | Duplicates (plain, escaped, nested) rejected before map conversion; type, depth, node and byte limits tested; four real-function mutants fail their properties. |
| M8 stranding needs a caller | CLOSED | Job discarded while read-only, re-wake by the existing job ID, later host `expire` gives Stranded (composition test 7). Quarantine exception: R2. |
| M9 overlap with Envelope | see D3 | R1 |

## New findings

### R2 (HIGH for the job table): quarantined Dispatched intents never strand

The frozen table checks `quarantined` only for Definite. In the Cure policy a quarantined state keeps every event, including `Expired`, `Completed` and poll results. My probe on the real owner:
1. Attempt 1 returns a typed attested no-send and becomes `{:Definite, :AdapterNoSend, 1}`.
2. `advance(:rearm)` and `advance(:dispatch)` start attempt 2.
3. A late authenticated completed result for attempt 1 contradicts the no-send. Result: `{:ok, :retained}`; flags `quarantined: true, disarmed: true`; phase stays `{:Dispatched, {:After, :AdapterNoSend}, 2}`.
4. After the grace time, `advance(:expire)` returns `{:ok, :Stop}` and the phase does not change. `advance(:poll)` still returns `{:ok, :polling}`.
The runner would then poll every poll delay for ever. Oban snoozes do not use up attempts, so nothing ends the job. Clarification 2 says only "check quarantined before any dispatch/rearm".

**R2 amendment** to the decision packet's job table (add one row at the top of the phase rows; it applies before every other Intended or Dispatched row):
- Before: no row.
- After: `| Phase Intended or Dispatched, flags.quarantined | none (no dispatch, no poll) | {:cancel, :operator_required} |`

Required test: reach this state with `observe/2` as above and show one cancel, no Adapter entry and no poll task.

### R3 (MEDIUM): every poll delay, not only the first

Clarification 3 bounds only the first delay. The range "polling delay 1..30 s" allows a 1 s delay while one poll can take up to 3 s. A poll that starts while the previous one runs returns `{:error, :task_start}` and appends a counted `Lost` event (composition test 3 shows the revision advance).

**R3 amendment** (clarification 3 and the proposal's timing line):
- Before: `First scheduled poll delay is at least ceil(total_ms/1000)+1 seconds;` and `polling delay 1..30 s`
- After: `Every scheduled poll delay, first and later, is at least ceil(total_ms/1000)+1 seconds;` and `polling delay ceil(total_ms/1000)+1 .. 30 s`

The `ceil(recovery_grace_ms/poll_delay_ms) <= 512` check stays. As the packet says, it does not bound polls before the admission deadline. I accept the "saturation must fail closed" wording. A tighter option for the first slice is a host maximum for `deadline - admission time`, so `(window + grace) / delay` can be checked at construction. This is optional.

## Challenge areas

- **Total job table and error handling.** Rows are exact for phases Intended, Dispatched, Definite, Confirmed, Stranded. Gaps: R2. `{:error, :schema}` from dispatch falls into "any other error" and burns Oban attempts; a `{:cancel, …}` is better but it is bounded, so it is not a blocker.
- **No-send chronology.** Verified on PostgreSQL: the dispatched checkpoint (sequence 2) exists when the Adapter is entered (test 5); a typed no-send then gives Definite and rearm (test 4). Open point G1: a single timer around "preparation, transport and receipt authentication" cannot tell whether Req was entered when it fires. Rule for the implementer: either every timer expiry maps to `transport_timeout` (unknown), or preparation runs in a separate, earlier step with its own timer, and only that step may return `preflight_unavailable`.
- **Task cap and caller timeout.** The owner's `max_children: 1` slot is held by the Adapter process. The timed inner task must use a different Task.Supervisor, or its start fails. Timed-out control calls leave the queued action running (test 8); the retry wake must show exactly one Adapter entry (G7).
- **Real-Oban states.** Pinned source and a PostgreSQL matrix agree: `scheduled`, `retryable`, `completed`, `discarded`, `cancelled` become `available` with the same ID; `available` and `executing` are ignored; `max_attempts` rises to attempt+1; an absent ID returns `:ok`. The matrix forces states by SQL `UPDATE`, and the probe Oban runs with `plugins: false`. An `executing` row left by a dead node is ignored by `retry_job`; only the Lifeline plugin frees it. Name this as a host Need and test it (G6).
- **Origins and identity.** The origin is part of the compile-time Binding (`provider_account`), so each origin needs its own binding module. The proposal's phrase "construction-time fixed origin/binding" is only true for the context. The runtime origin is in `adapter_context`, outside the digest (G2).
- **Rejected 404, no-effect, replay.** The failure map has no such tag, `replay: :none`, and the mutant shows what a 404 ground would do. CLOSED. Keep a negative control that fails if a binding with a replay map is built.
- **Raw JSON boundary.** Jason 1.4.5 with `objects: :ordered_objects` keeps duplicates. My probe: lone surrogate, trailing bytes, BOM and `1e999` give errors; a 5000-digit integer gives an error; a NUL byte in a string is accepted (the opaque `kind` and `key` then hold control characters); a top-level scalar decodes and must be refused by the next step (it is).

## Production gates the implementer must meet (no root decision needed)

- G1. Freeze preflight versus Req chronology as above; separate supervisor for the inner task; a hung preparation must not give `preflight_unavailable` unless it is the separate earlier step.
- G2. Adapter checks that the context's origin identity equals the binding's `provider_account` at construction and on every send; a mismatch is a typed pre-Req failure. Negative control: changed origin with the same binding.
- G3. Admission mapping from Envelope command to identity, deadline, arguments and classification, as listed under "core/effect placement".
- G4. Apply the same duplicate-key, depth, node and byte checks to the request body. Reject control characters in the receipt `key` and `kind` strings, or state that opaque kinds are never logged.
- G5. Exercise the success path through the owner on PostgreSQL: valid HMAC receipt gives Confirmed; forged key, digest and MAC are refused with retained summaries; duplicate and late completions; `validate_result` must not be a stub.
- G6. Lifeline and orphan-`executing` handling; live rescue of a running job; duplicate wake while the Adapter task runs.
- G7. Cap the runner's own caller tasks; show one Adapter entry for timed-out dispatch followed by a retry wake.
- G8. Keep the mutation list on real source: redirect on, retry on (note: Req's default retry does not retry PUT, so the PUT mutant must set a retrying mode such as `:transient`), atom keys, trust upgrade, field retention, ack guessing, changed identity, job retry bypassing the intent.
- G9. Run fresh `mix setup` and full `mix check`, standalone copy and aggregate export, and independent actual-diff review. None of these has been run for this delta.

## Limits of this review

- No full `mix check` was run for this proposal-only delta, and none is claimed.
- The probes are reduced fixtures. They use a controlled clock, a stub Adapter, a stub Jobs worker, loopback HTTP and no real MAC. They do not show a whole HTTP, intent and Oban pipeline.
- I read the changed task, plan files, the decision packet, the revised proposal, the focused-probe document, all three probe sources and the dependency sources named above. I did not read `assembly/durable-job`, `runtime/adapter`, `delivery/retry-timeout` or `integration/json` source in full.
- My quarantine probe used the Memory store (the policy path does not depend on the store). The PostgreSQL probes were run only through the author's composition script.
- Loopback timing tolerances are broad. TLS, DNS, proxies and real provider behavior are not covered.
- Scratch files are in `/tmp/elz011-rereview/` and `/tmp/elz011-review-probes/`. Delete them after root reads this report.
