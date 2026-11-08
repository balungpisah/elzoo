# ELZ-029 independent focused early re-review

Reviewer: Codex, Orca session `orca_session_id:f6cfa678-7d34-442f-8b4d-cfcd1c2e55b5`, task `task_852e0f157f46`, dispatch `ctx_de31ac0605cc`. Reviewed `64acad7c437f21db149a78776e3d27d81e6201ba`, proposal only, against live issue #46 and the ELZ-050 decision record. This review is independent of the first reviewer; it is not implementation or process-test evidence. No Mix command was run. The working tree had a pre-existing untracked `.reticle-setup-crash.log`; it was not touched.

## Blocking observations

1. **Port ownership and failure handoff remain incorrect.** Proposal lines 257–273 say `Port.connect(port, collector)` while asserting the reaper remains owner, and that collectors are not linked to the Port. OTP's [`port_connect/2` documentation](https://www.erlang.org/docs/28/apps/erts/erlang.html#port_connect/2) says it makes the new process the port owner and links it to the port, while retaining the old link. Thus the stated collector-death and reaper-death matrix cannot be justified by this handoff: killing the new owner can close the Port and a port exit can affect its linked collector. Explicitly design and test the actual port owner and link/monitor behavior on the pinned OTP, including failure after `Port.open` but before registration, collector/reaper/adapter concurrent death, and port close. Registration after opening is not atomic with BEAM process death. Reaper state 'before signal' also cannot show whether a signal actually happened: a worker may die between recording and sending, or between sending and recording, so the claimed at-most-once handoff and resumed stage need a concrete accounting protocol and race tests.
2. **Unsafe identity and escalation remain unresolved.** Lines 89–105 assume a positive `pgrep` result is the original group merely because no empty result was observed. The original group may disappear and its ID be reused between observations, including during a long-running or blocked run; absence of an observation of emptiness is not continuous ownership. The check-to-signal race also remains. Lines 219–234 send TERM and KILL after two failed observations: in particular KILL without observing a live group conflicts directly with the live invariant that escalation occurs only if the group is still alive, and risks signaling a reused unrelated group. A declaration of accepted risk does not satisfy G2. Rework using a bounded, justified ownership/lifetime mechanism and preserve the live invariant, or stop for a reviewed Contract/design decision; do not infer safety from timing or process-table exit status.
3. **Stage is still assumed on failed signal.** Lines 223–225 treat `:sent` and `:failed` identically; lines 227–236 then label the stage TERM or KILL if the group becomes empty. A failed signal followed by natural exit or another actor's signal is not evidence that the named escalation occurred; signal utility exit zero also does not prove delivery. Define the observed fact carried by the stage and preserve the live 'reported from observation, not assumed' acceptance; injection tests must cover failed TERM/KILL and independent natural exit.
4. **Failure cleanup and bounded lifetime are not established.** A6's honest `unknown` result is useful, but proposal lines 238–240 and 331–333 return after a still-live group or repeated observation failure without specifying a continuing owner for cleanup. This leaves the record's bounded-child/no-orphan condition unestablished, and cannot be represented as satisfying the accepted cleanup guarantee merely because `unknown` is honest. Reconcile the stated terminal behavior with issue invariants and exact finite acceptance tests; seek deliberate review if they cannot be met. Whole-VM death and escaped descendants are separately disclosed limits, not an answer to BEAM owner death.

## First review findings

| Finding | Disposition |
| --- | --- |
| 1 scope, BLOCKING | Addressed for this dispatch: user explicitly authorizes the selected catalogue row, release-plan entry and regenerated ledger/roadmap views, in addition to Piece and `docs/work/ELZ-029*`. G3 accommodates explicit scope authorization. Claim marker is protocol metadata and must be removed before PR. |
| 2 cleanup, BLOCKING | **Not addressed**: revised grace logic is an improvement, but Port ownership, spawn-to-registration, concurrent failure, signal handoff and terminal `unknown` cleanup remain unresolved (observations 1 and 4). |
| 3 observation and identity, BLOCKING | **Not addressed**: separates `pgrep` from `kill` and includes fake-success failure control, but PGID identity is not retained by absence of a negative observation, unsafe check-to-signal and blind KILL remain, and stage remains inferred after failed signaling (observations 2–3). Verify `pgrep` semantics on actual symbolic OS; failure is not empty. |
| 4 result mismatch, BLOCKING | **Partially addressed**: A1–A5 propose sidecar, explicit pre-dispatch cases and cancellation mapping; no decision in live issue yet. An honest stage still needs observation 3 resolved. Amendment text must be reviewed as below; do not change ready Envelope. |
| 5 Needs, BLOCKING | **Partially addressed**: default-empty environment allowlist and explicit host tools are proposed; A7's CLI version routing and direct-dependency composition await coordinator disposition. Executable and utility versions/semantics must be declared and tested at the actual owning boundary. |
| 6 deadline/grace, REQUIRED | **Partially addressed**: admission monotonic target, queue deadline precedence, late timer generation and full grace are specified; A4 must be decided. Clarify the `max_run_ms`-only case when target is absent, bounds for all timers including queue/grace/reap, and actually test races. G2's no-blind-escalation issue remains. |
| 7 evidence, REQUIRED | **Partially addressed**: tests for many earlier gaps are planned, not performed. Escape test is explicitly skipped if Perl absent, so cannot satisfy G6 without a reliable available fixture or a failed/blocked result; it needs robust cleanup even on assertion failure. Add deterministic spawn/registration, transfer/owner, simultaneous death, handoff-before/after-signal, failed TERM/KILL with natural exit, reused identity and observation race cases; ensure the actual early-exit test proves no premature KILL while a group remains alive. No-output-leak test must address all actual observation channels, not just captured logs. |
| 8 operational/dependencies, REQUIRED | **Partially addressed**: proposed statuses, cancel semantics, secret exclusion and explicit caller-side dependencies are present; coordinator disposition and in-bundle evidence remain. Clarify implementation behavior under crashes and whether Config tests cover all fields; do not treat counter proofs as FIFO proofs. |
| 9 completion/Q4, LOW | **Partially addressed**: cases and stderr/stdin/truncation limits are explicit; coordinator still must accept completion consequences, and collector death/closed-pipe behavior needs pinned-OTP evidence. Do not present empirical EOF ordering or 128+signal as an unconditional upstream API contract. |

## Amendment recommendations

The issue source uses hard line wraps; A1, A4 and A5 quote normalized or elided text rather than byte-exact before snippets. The exact replacements below preserve the live text's line breaks. Recommendations do not grant implementation clearance; the main coordinator decides the Contract and its local copy.

| Amendment | Verdict | Reason |
| --- | --- | --- |
| A1 | **REWORD** | The requested set is a scoped pre-dispatch clarification, but quote the byte-exact before text and apply the after below. A genuine spawn failure may be called not-dispatched only when dispatch did not occur. |
| A2 | **ACCEPTABLE** | Exact before exists in the issue. Pairing the adapter sidecar preserves the ready Envelope result shape and retains stage reporting, subject to proving what was observed. |
| A3 | **ACCEPTABLE** | The added mapping covers explicit cancellation and failure of the collector without changing the ready Envelope; caller death can drop delivery, so mapping applies when a result is deliverable. Definitive termination still requires observation; partial effects remain possible. |
| A4 | **REWORD** | Its `rejected{…}` before text is a placeholder and is not an exact source substring. Use the exact post-A1 replacement below; distinguish deadline expiry from queue timeout and keep no dispatch. |
| A5 | **REWORD** | Exact before contains a newline. `none` is a truthful no-signal observation only when the original group is reliably identified as absent; it cannot establish that an escaped process was killed. Use wording below and resolve identity first. |
| A6 | **REWORD** | An honest unknown for an observed surviving group is useful, but as written does not map the added case to `unknown/dispatched` and must not be read as a release from cleanup or evidence requirements. Exact words below preserve those requirements; this does not solve the design failure in observation 4. |
| A7 | **REWORD** | Adding Needs is appropriate, but assigning the unresolved owner decision on exact CLI versions to a not-yet-decided task as a settled fact is premature. Use the exact anchor and wording below; the coordinator must record where versions are selected. |

### Exact suggested wording

A1, replace this exact issue substring:

```text
`rejected{queue_full |
   queue_timeout}` (not dispatched)
```

with:

```text
`rejected{queue_full | queue_timeout | spawn_failed | cancelled}` (not dispatched; `spawn_failed` only where no command was dispatched; `cancelled` only where a queued command was not dispatched)
```

A4, after A1, replace this exact substring:

```text
`rejected{queue_full | queue_timeout | spawn_failed | cancelled}` (not dispatched; `spawn_failed` only where no command was dispatched; `cancelled` only where a queued command was not dispatched)
```

with:

```text
`rejected{queue_full | queue_timeout | spawn_failed | cancelled}` (not dispatched; `spawn_failed` only where no command was dispatched; `cancelled` only where a queued command was not dispatched), `expired{deadline}` when the declared deadline passed before dispatch (not dispatched)
```

And replace this exact substring:

```text
`rejected{…}` → `rejected/not_dispatched`,
```

with:

```text
`rejected{…}` → `rejected/not_dispatched`, `expired` → `timed_out/not_dispatched`,
```

A5, replace this exact issue substring:

```text
`terminated{stage: term | kill,
   deadline}`
```

with:

```text
`terminated{stage: none | term | kill, deadline}` (`none` only when a reliable observation establishes that the original group is empty before any termination signal; `none` does not claim signal delivery)
```

A6, replace this exact issue substring:

```text
`unknown` when the liveness check itself fails
```

with:

```text
`unknown` when the liveness check itself fails or the group is still observed alive after the kill stage and the bounded reap wait; `unknown` does not establish cleanup or relax the termination invariant or acceptance criteria
```

Also replace:

```text
liveness-check failure → `unknown/dispatched`
```

with:

```text
`unknown` → `unknown/dispatched`
```

A7, insert after the exact issue anchor:

```text
   confinement (domain/authorization).
```

this text:

```text
   Needs: an executable path and declared executable version, a working directory, an explicit environment allowlist (names inherited from the host plus names set per call; everything else is unset for the child), and declared host `kill` and `pgrep` utilities for signalling and group observation. The coordinator records the owning task and decision for the exact Claude Code CLI and Codex CLI versions.
```

## Gates, scope and evidence

G1–G8 in the revised proposal are **byte-identical** to the first review's binding gates, including the conditional registry authorization in G3. G1 and G2 remain unsatisfied: coordinator must decide reviewed issue amendments and Needs/dependency disposition, and the actual safe ownership, observation, signal accounting and cleanup design must be established before implementation. G3 now permits precisely the user-authorized row/entry/derived views, Piece paths, `docs/work/ELZ-029*`, and claim-marker removal; any task-copy edit needs separate assignment. G4–G8 remain execution/verification gates, including the symbolic tests, in-bundle operational declarations, pinned `mix setup`, generated ledger, full `mix check`, assigned disposable database where required, independent implementation review and required CI. Completion semantics and test reliability require explicit coordinator decisions as noted above.

`git diff --name-only origin/main 64acad7` contains only `.claims/ELZ-029.md` and the three proposal/review files under `docs/work/ELZ-029*`; no implementation is committed in the reviewed diff. The retained review copy is byte-equal to the first report. This scope check is against the observed local `origin/main` ref, SHA `665d3e07c58fb9a3e7818a037a6910132535fa53`.

## Commands and exit codes

- `cat /Users/laptopdp/.agents/skills/orchestration/SKILL.md` — 0; `orca skills get orchestration` via the unresolved `/usr/local/bin/orca` printed an application-path error; resolved executable from `ORCA_CLI_COMMAND`, `/Applications/Orca.app/Contents/Resources/bin/orca skills get orchestration` — 0.
- `cat /tmp/elz029-early-review-3ed21163-fd79-4e9b-bf56-10ef0a0d35e7.md` — 0; `git diff 75fc2ef 64acad7` — 0; `git diff --stat 75fc2ef 64acad7` — 0.
- `git show 64acad7:docs/work/ELZ-029.md` and targeted `sed`/`nl`/`rg` reads — 0; `git show 64acad7:docs/work/ELZ-029-contract-proposed.md` — 0.
- `git show 64acad7:docs/work/ELZ-029-early-review.md | cmp - /tmp/elz029-early-review-3ed21163-fd79-4e9b-bf56-10ef0a0d35e7.md` — 0 (equal).
- Python exact extraction/compare of G1–G8 from original and `git show` — 0 (`G1-G8 byte-identical: True`).
- `gh issue view 46 -R balungpisah/elzoo --json body` and `--jq .body` — 0; `git show origin/task/ELZ-050:docs/plans/catalogue-dispositions.md` and targeted runtime/os-isolation extraction — 0.
- `git diff --name-only origin/main 64acad7` — 0; `git log --format='%h %s' origin/main..64acad7` — 0; `git status --short; git rev-parse HEAD origin/main origin/task/ELZ-029` — 0.
- `cat CONTEXT.md GOAL.md docs/development/01-workflow.md` — 0. User-supplied AGENTS.md instructions supplied the applicable Contract/evidence/scope requirements.
- Web search of primary OTP documentation returned the linked `port_connect/2` reference. A separate `curl --max-time 8` to OTP source timed out (curl 28; piped command exit 1); no source claim relies on that attempt.

**Verdict: NOT CLEAR** — amendment decisions alone cannot clear implementation; resolve the four blocking observations and G1–G2, revise the proposal, and obtain review of the revised design.
