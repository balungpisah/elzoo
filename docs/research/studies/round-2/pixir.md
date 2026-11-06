# Elzoo adopt-or-distill study: Pixir (supervised coding-agent runtime)

Reviewed 2026-11-06 against balungpisah/elzoo `main` at
`bf16422dbc741de5c3ff3d86f3af9b14d7eb19ef`. Bounded source/document study in the
shape of the Raxol rows in docs/research/orchestration-references.md: nothing was
executed, vendored or copied; observations motivate Contract text and design tests,
not available Elzoo behaviour. Links use the pinned revision. Same skepticism as
the Raxol study applies: model output is an untrusted proposal, tool discovery is not
authorization, a shared schema does not establish matching authority/durability/
delivery semantics, and agent orchestration is an Assembly, not a kernel.

## Summary table

| Package | Pinned SHA | License | Last commit | Verdict | One line |
| --- | --- | --- | --- | --- | --- |
| pixir (Hex 0.1.17) | [`7eb163da896a864fb69c848fe2c35567ee19e38f`](https://github.com/Ranvier-Technologies/pixir/tree/7eb163da896a864fb69c848fe2c35567ee19e38f) | MIT (`LICENSE`, © 2026 Bastian Venegas Arevalo) | 2026-09-08 (`main`; no Git tags) | **distill** | A 78 kLOC single-author harness whose safety/evidence boundaries (bounded-write non-escalation, deny-as-feedback, durable-vs-live capability honesty, cancel-drain, process-group kill, bounded host-command boundary) become Contract text and design tests for C6; the package itself is not an adoption candidate for any deferred handle. |

## Pinning and package facts (observed 2026-11-06)

- Hex `pixir` 0.1.17 was published 2026-09-09T17:27:42Z (checksum
  `bb255fe758e88549d1b70b695fb41bf5bed36fce35000ee92e68569897ec9fa0`); it is the
  latest and latest-stable release. The source repository has **no Git tags**; the
  release matches `main` HEAD `7eb163d…` ("Developer preview update: Pixir 0.1.17
  (#18)", 2026-09-08). Verified by extracting the Hex tarball and diffing `lib/`
  against the clone: identical except the per-directory `AGENTS.md`/`CLAUDE.md`
  files and `lib/mix/tasks/**`, which `mix.exs` excludes from the package
  ([mix.exs:165-167](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/mix.exs#L165-L167)).
- Declared dependencies ([mix.exs:126-133](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/mix.exs#L126-L133)):
  `finch == 0.23.0` (exact), `jason == 1.4.5` (exact), `just_bash ~> 0.3.0` (MIT; a
  simulated bash with an in-memory filesystem that itself requires req, earmark,
  nimble_parsec, nimble_options and telemetry), `elixir ~> 1.20`; `ex_doc` dev only.
  Elzoo's lockfile currently resolves `finch 0.24.0` under its `req == 0.7.5` pin, so
  pixir's exact `finch 0.23.0` pin would conflict with Elzoo's existing
  `integration/http` recipe. `jason 1.4.5` matches.
- Maintenance signal: 27 commits in the public repository, all squashed
  "Developer preview update"/sync merges from one author under two e-mail
  identities (`git shortlog`); the public repo is a mirror of private development.
  `lib/` is 138 files / 78,070 lines. Its own `AGENTS.md` states "Not included: stable
  public Elixir API … MCP support … production support promises"
  ([AGENTS.md:123](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/AGENTS.md#L123)).
  No bus-factor or correctness claim is made beyond these facts.
- License: MIT at the pinned revision; `THIRD_PARTY_NOTICES.md` covers only
  marketing-site logos (ISC/CC0). No copyleft or non-commercial terms found, so
  distilling ideas is unproblematic and a `balungpisah` fork would be permitted by
  docs/development/08-upstream-and-forks.md — but no fork is proposed (see verdict).
- Tests: 133 ExUnit files, with injected provider transports and scripted
  providers; e.g. `test/pixir/turn_cancel_drain_recovery_test.exs`,
  `session_lease_test.exs`, `permissions/`, `log_bounded_test.exs`. These are finite
  scenario tests, not proofs.

## Pixir: observations (dated 2026-11-06, pinned revision)

| Observed source | What it exposes | Elzoo design implication |
| --- | --- | --- |
| [bounded write policy](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/permissions/write_policy.ex#L134-L204) and [`ensure_rules_narrow`](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/permissions/write_policy.ex#L838-L853); [doc](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/docs/bounded-write-policy.md) | An operator-supplied, versioned, hashed allow/deny path policy is "never proposed, widened, or edited by a model"; `.pixir/**`, `.git/**`, `**/.env*`, `**/secrets/**` and the policy file itself are always denied; unknown top-level fields are rejected; a child's write set must be *syntactically contained* in the parent's allow rules or it is denied as `not_within_parent_allow`; a `spawn_agent` call that carries its own `write_policy` is denied (`child_policy_override_unsupported`); an unknown mutating tool is denied for being unknown; the narrowed child policy is re-hashed over durable fields so it verifies on cold resume | ELZ-024 `domain/authorization`: the bounding-authority rule ("permitted and escrowed writes ⊆ bounding authority") already exists; Pixir adds the concrete *mechanics* worth naming as design tests: containment is decided syntactically on typed rules, never on a model-proposed string; a proposal that carries its own policy is a denial, not an input; policy identity (id, hash, version) travels with every decision |
| [executor denial handling](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/tools/executor.ex#L541-L600) and its [moduledoc](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/tools/executor.ex#L12-L38) | A write-policy denial is returned to the model as the tool result ("feedback once"), the second denial in the same Turn is turn-fatal (N = 2, fixed), every denial is a canonical `permission_decision` Event regardless of recoverability, and every denial is "confessed" in the parent-facing envelope with a `disposition` of `recovered`/`fatal`/`unresolved`; `unresolved` is used when the denying Turn never reached a terminal event, and an unreadable child Log yields `status: unavailable` rather than `count: 0`, with unavailability propagating upward | `workflow/approval` + `state/audit-log` (ELZ-024 step 6): the denial *is* the retained record, and recoverability never shrinks it; the zero-vs-unavailable distinction is a C6 dangerous-failure case for `delivery/aggregation` ("a coordinator that sums counts cannot silently add a zero for evidence it never saw") |
| [`Pixir.Permissions.decide/3`](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/permissions.ex#L39-L76) and [ADR 0006](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/docs/adr/0006-permission-model-auto-by-default.md) | A pure `allow / deny / {:ask, reason}` decision per tool call, with mode `:auto` (everything allowed) as the *default*; the bash safe-list is "a heuristic (first token + no shell metacharacters)", confinement is enforced by path-token inspection described as "a conservative pre-exec tripwire, not a shell parser or sandbox" with a documented residual (`VAR=/outside cmd $VAR`) | Negative example for ELZ-024: allow-by-default and text heuristics are product choices Elzoo must not inherit; the ready Contract should gate on typed effect class (already stated in ELZ-024 step 5) and declare a fail-closed default. Positive: the residual is *written down*, which is the honesty Elzoo asks of Contracts |
| [Delegate owner service states](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/delegate/owner.ex#L1-L30) and [ADR 0034](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/docs/adr/0034-delegate-runtime-residency.md) | Durable identity (`parent_session_id`, the Log root) is separated from live capability; `status`/`attach`-snapshot work from the Log after restart, but streaming attach and *active cancellation* require a resident owner; when none exists the result is `snapshot_only`, `stale_handle` or `owner_unavailable` — "It must not claim that live work was cancelled … merely because durable evidence was readable" | `workflow/run` cancellation design test and `integration/agent-runner` Contract text for C6: a cancellation request against a run with no live owner returns a distinct *not-performed* result; "durable record says running" and "I interrupted it" are two facts. Complements the Raxol interrupt row (staged, OS-confirmed kill) |
| [child cancellation statement](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/subagents/manager.ex#L1171-L1205), [ADR 0026 terminal states](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/docs/adr/0026-runtime-terminal-state-and-replay-contract.md#L53-L80) and [`turn_cancel_drain_recovery_test`](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/test/pixir/turn_cancel_drain_recovery_test.exs#L1-L30) | On cancel the manager writes `cancelled_by_parent` into the *child's* Log so a reader of that Log alone distinguishes "cancelled by my parent" from "the process died mid-write"; a child Log that cannot be written degrades to parent-only evidence instead of failing the cancellation; `completed` is defined as "clean terminal evidence exists in the Log", explicitly *not* "a process exited, a Task returned, the Provider stream closed"; a cancelled mid-stream Turn must not poison the Session (orphan `tool_call`s are repaired with `ok: false` results) | `workflow/run` (C5/C6 design tests "cancelling an attempt does not automatically cancel the business request"; "model text saying done is not accepted as a receipt"): cancellation is a recorded fact on *both* sides of the parent/child edge, with an explicit degraded path; termination of the Host process is not an outcome. Also an ELZ-009 `state/event-log` test: a crash between paired records leaves a visible orphan that is repaired by a new record, never by rewriting |
| [Session writer lease](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/session_lease.ex#L228-L250) and [status classification](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/session_lease.ex#L325-L338); [`Log.append`](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/log.ex#L104-L148) | Exclusive-create of a lease file gives one cross-OS-process writer per Log; `append` refuses non-canonical events and consults the lease before writing; lease state is `active` / `stale` (no heartbeat within `stale_after_ms`) / `ambiguous` (heartbeat in the future); stale and ambiguous both *fail closed* until an operator forced release writes a diagnostic release record; the lease "is not History and never replaces the Log" | `state/lease` (deferred) and ELZ-009 `state/event-log`: a lease is live-capability evidence, not state; stale and ambiguous are distinct from free; forced release is an attributable record. Elzoo should keep the deferred-handle wording: this is a single-host filesystem lease, not a distributed lock |
| [`Log.fold` / decode](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/log.ex#L436-L478) and [`Pixir.Event` types](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/event.ex#L44-L78) | A fixed canonical type set is the decode whitelist ("never `to_existing_atom`, whose success depends on whether the atom happens to already exist in the VM"); `seq` orders replay with file order as backstop; ephemeral deltas (`text_delta`, `status`, `plan`, `context_pressure`) are never persisted and the durable `assistant_message` is the reconstructable completion | Already covered by the Raxol rows (event boundary: no atom minted from a wire string; durable vs reconstructable-ephemeral tiers) and ELZ-009 scope. One addition: a replay-ordering key *plus* an explicit backstop order when the key is absent is Contract text ELZ-009 should state, not infer |
| [`Pixir.Tools.Bash` process-group kill](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/tools/bash.ex#L177-L225) and [moduledoc](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/tools/bash.ex#L1-L35) | OS command runs via a `Port`; a wrapper makes the child a process-group leader; on timeout SIGTERM the group, wait a grace period, SIGKILL only if the group is still alive and report which signal ended it; an unlinked reaper repeats the cleanup if the collecting BEAM process is brutally killed; pending port messages are drained so repeated timeouts do not dirty the caller mailbox; "deliberately double-forked daemons that leave the process group are a residual out of scope" | `runtime/os-isolation` (planned): Contract text for the OS-process Adapter: group-scoped termination with staged escalation, an *observed* escalation outcome in the result, cleanup that survives the owning BEAM process dying, and named residuals. Confirms the Raxol interrupt row and ADR-0003's "a BEAM process is not security isolation" |
| [`Pixir.Tools.CommandBoundary`](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/tools/command_boundary.ex#L160-L240) and [ADR 0027](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/docs/adr/0027-command-boundary-doctrine.md) | A GenServer slot pool for *host* commands only: `max_concurrent` active, bounded `queue_limit`, `queue_timeout_ms`; `queue_full` and `queue_timeout` are structured backpressure errors; the boundary "only accounts for external process capacity" and leaves lifecycle/permissions/Events to the Executor; host-process fan-out is kept separate from BEAM-local subagent fan-out | `delivery/backpressure` (ELZ-006) and `runtime/os-isolation`: an admission bulkhead for scarce host processes with rejection *and* queue-timeout as distinct port-contract results, separate from retry policy and from in-BEAM concurrency limits. No new Piece: it is the ELZ-006 bounded receiver applied to an OS-process Adapter |
| [`Pixir.Delegate.CriticalPath`](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/lib/pixir/delegate/critical_path.ex#L1-L111) | A pure function estimates the fan-out's critical path from `ceil(tasks / max_threads)` waves × per-child budget (or per-wave max step budget for a DAG) and *fails admission closed* when the caller's wait horizon cannot cover it, returning a `suggested_timeout_ms` fixed point; retries, provider jitter and overhead are excluded by statement; the estimate is admitted to be conservative versus a work-conserving scheduler | `workflow/budget` (ELZ-022) second unit type and `workflow/dependency-graph`: time is a reservable unit with an admission check *before* spawning children; the pure estimate is a candidate design test (C6 "bounded fan-out/depth/cost"), not a new Piece |
| [ADR 0036](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/docs/adr/0036-idle-timeout-retry-and-resume.md#L42-L72) | After a provider idle timeout, write-capable work is never auto-resumed; four concepts are kept distinct (transport fallback, same-request retry, manual resume, automatic resume); an automatic retry is admissible only when "the interrupted request segment emitted no durable assistant output, tool call …" — i.e. a Log-observable predicate, not a claim that "the command is idempotent" | ELZ-023 `delivery/effect-intent`: this is the same rule as "a crash or deadline by itself never re-arms" applied to a *model* call rather than a provider payment; the re-arm premise must be durable evidence of non-dispatch, never a prose idempotency claim. Fold as a design test; no new state |
| [ADR 0033 typed checkpoint provenance](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/docs/adr/0033-typed-checkpoint-projections.md#L98-L114) and [ADR 0014](https://github.com/Ranvier-Technologies/pixir/blob/7eb163da896a864fb69c848fe2c35567ee19e38f/docs/adr/0014-workflow-checkpoint-bundles-and-partial-outcomes.md#L30-L60) | Every typed checkpoint payload declares provenance: `harness_projection`, `tool_result`, `artifact`, `workflow_event_fold` or `model_declared`; "`model_declared` payloads require stricter template contracts before they can unlock dependents"; a step has both a raw child lifecycle status and a derived `checkpoint_status` (`checkpoint_ready` / `partial` / …) and only `checkpoint_ready` unblocks dependents | `workflow/dependency-graph` readiness and `state/artifact` for C5/C6: dependency readiness is a *derived, provenance-tagged* judgement, not the child's exit status; a model-declared value cannot by itself make a dependant runnable. This is the concrete form of "generated text is not execution evidence" |

Not reviewed beyond classification: provider transport/WebSocket policy, prompt
caching, compaction prompts, ACP/stdio presenter, skills, OAuth, the `monitor/`
Phoenix app and the `site/`. `just_bash`'s virtual overlay was read only far enough
to confirm it is a simulated shell with an in-memory filesystem used for
read-set imports, not an isolation mechanism.

## Overlap check (per mechanism)

| Mechanism | Elzoo capability / task | Already covered by Elzoo? | Upstream reuse as-is? | Gap it fills |
| --- | --- | --- | --- | --- |
| Bounded-write non-escalation, policy identity, child containment | `domain/authorization`, `workflow/approval` — ELZ-024 | Partly: ELZ-024 step 2 states "permitted and escrowed writes are a subset of the bounding authority, so a child run's decision never exceeds its parent's"; step 5 lists "a generated tool argument or child run escalating authority" | No: the policy is a path-glob schema tied to Pixir's tool set and `Pixir.Tools.Executor`; MIT, but the module depends on the harness context map and `Pixir.Tool` errors | Named tests: proposal-carried policy is a denial; containment decided on typed rules; policy identity stamped on every decision |
| Deny-as-feedback, fixed second-strike, always-logged, confessed denials with `unresolved`/`unavailable` | `workflow/approval`, `state/audit-log`, `delivery/aggregation` — ELZ-024 step 6, C6 | Partly: ELZ-024 says "Approval decisions are retained records, not telemetry"; nothing about a denial being returned to the proposer or about aggregating child evidence | No (same coupling) | Contract sentences on denial-as-result and on zero-vs-unavailable aggregation |
| Durable identity vs live capability; cancel without owner is a distinct result | `workflow/run`, `integration/agent-runner` — C6 | Partly: Raxol row covers staged interrupt with OS confirmation; the "no live owner" case is absent | No: `Pixir.Delegate.Owner` is vocabulary over Pixir's Subagent Manager | Design test: cancellation of a run whose owner is gone returns not-performed, never success |
| Child-side cancellation record with degraded path; `completed` = Log evidence | `workflow/run`, ELZ-009 `state/event-log` — C5/C6 | Partly: C5 "cancelling an attempt does not automatically cancel the business request"; C6 "model text saying done is not accepted"; ELZ-009 scope has orphan handling only via torn-tail wording | No | Both-sides cancellation record; explicit degraded evidence outcome; orphan pair repair by new record |
| Filesystem writer lease with stale/ambiguous/forced-release | `state/lease` (deferred), ELZ-009 | No: `state/lease` is deferred with no Contract text | Possibly later as a *recipe* idea, but the module is tied to `Pixir.Paths` and the Session-id grammar; Elzoo's lease will more likely sit on the ELZ-009 storage provider | Contract wording for stale vs ambiguous vs free and attributable forced release |
| Canonical-type decode whitelist; seq + backstop order | ELZ-009, ELZ-011 | Yes (Raxol event-boundary and projection rows) | n/a | Only the explicit backstop-order sentence |
| Process-group kill with staged escalation and reaper | `runtime/os-isolation` (planned) | No Contract text yet beyond "OTP Port/OS process or service; BEAM process is not security isolation" | No: Perl wrapper + `kill`/`pkill` shell-outs are Pixir implementation; Elzoo would write its own Adapter | Adapter Contract text and tests for the OS-process boundary |
| Host-command slot pool with queue limit/timeout | `delivery/backpressure` (ELZ-006), `runtime/os-isolation` | Partly: ELZ-006 owns bounded admission; the OS-process bulkhead is not named | No (GenServer tied to Pixir presenter liveness) | One design test: host-process admission distinct from BEAM concurrency; `queue_full` vs `queue_timeout` |
| Pure critical-path admission against a wait horizon | `workflow/budget` (ELZ-022), `workflow/dependency-graph` | Partly: ELZ-022 carries unit-tagged cost including seconds; no pre-spawn time admission test | The function is pure and small, but Elzoo would author its own in Cure if an Assembly needs it | Second-unit (time) admission design test |
| No auto-resume; Log-observable retry predicate | `delivery/effect-intent` (ELZ-023) | Yes in substance ("a crash or deadline by itself never re-arms") | n/a | One design test about model/provider calls specifically |
| Provenance-tagged checkpoints; derived readiness | `workflow/dependency-graph`, `state/artifact` — C5/C6 | Partly: capability-model text "generated text is not execution evidence"; no readiness-provenance rule | No | Contract sentence: readiness is derived and provenance-tagged; `model_declared` never unblocks alone |

## Verdict: distill

Pixir is not named as an adoption candidate for any deferred or planned handle:

1. **Boundary fit.** It is a complete harness (Session → Turn → Provider → Tools)
   with its own Log format, permission model and tool set; its mechanisms take a
   Pixir `context` map and return `Pixir.Tool` errors. Taking any one of them means
   hosting Pixir, which docs/capability-model.md forbids ("Do not propose adopting a
   framework as a mandatory host"; agent orchestration is an Assembly). It sits on
   the same layer as Raxol's harness, not on the Ash/ADR-0005 layer.
2. **Dependency weight and pins.** Exact `finch 0.23.0` conflicts with Elzoo's
   resolved `finch 0.24.0`; `just_bash` drags in req/earmark/nimble_* for a feature
   Elzoo does not want (simulated shell).
3. **Maintenance signal.** One author, squashed mirror commits, no tags, and an
   upstream statement that there is no stable public Elixir API.
4. **Overlap.** Most of its safety ideas are already in ELZ-022/023/024 or the Raxol
   rows; what remains is Contract text and design tests, listed below.

License: MIT, no conflict. No `balungpisah` fork is justified (no concrete
modification is needed because nothing is consumed; 08-upstream-and-forks.md).

## Proposals (Elzoo authors these; no code is copied)

Each item names the handle, the coverage case and the proposed text. Items marked
*fold* go into an existing task body; one item proposes its own admission record.

### A. Fold into ELZ-024 (`domain/authorization`, `workflow/approval`) — C6, C1

Contract sentences:
- "A proposal that carries its own policy, bounding authority or approval is denied
  as a proposal, not evaluated as an input; the owning Run supplies authority from
  its own state." (Already implied by step 2; make it a dangerous-failure test.)
- "Containment of a child's authority in its parent's is decided on typed rules,
  never by comparing model-authored strings."
- "Every decision carries the policy identity (id, version, content hash) it was
  evaluated under; a decision without one is malformed."
- "A denial is itself a result delivered to the proposer and a retained
  `state/audit-log` record; returning it to the proposer never reduces the record."

Design tests to add to step 5:
- child write set not contained in parent → DENY with the containing rule absent
  named; proposal carrying `policy` key → DENY regardless of contents;
- the same action proposed twice after one DENY follows a *declared* repeat policy
  (Elzoo need not adopt N = 2; it must state and test the policy);
- aggregation over children distinguishes "no denials" from "denial record
  unreadable", and unreadability propagates to the aggregate (C6
  `delivery/aggregation`).

### B. Fold into `workflow/run` design tests (deferred; C5, C6)

Add to the `workflow/run` inventory reason / future task body:
- "A cancellation request against a Run whose live owner is unreachable returns a
  distinct not-performed result (`owner_unavailable` / `stale`); a readable durable
  record never substitutes for an interrupted process."
- "Cancellation is recorded on both the parent and the child side; if the child-side
  record cannot be written the outcome is cancelled-with-degraded-evidence, not
  failure of the cancellation and not silent success."
- "`completed` means clean terminal evidence exists in the durable log; Host
  process exit, Task return or stream close are not outcomes."
- Dangerous failure: a crash between a paired request record and its result record
  leaves a visible orphan; recovery appends a repair record with a failure outcome and
  never rewrites or deletes.

### C. Fold into ELZ-009 (`state/event-log`, `state/checkpoint`) and `state/lease`

- ELZ-009 Contract sentence: "Replay order is the record sequence; records without
  one follow append order, and that backstop is part of the Contract." (Raxol rows
  already give the duplicate/gap/torn-tail rules.)
- `state/lease` inventory reason (deferred, keep deferred): "A writer lease is
  live-capability evidence, not state. Lease status is one of free, active, stale
  (no heartbeat within the declared window) and ambiguous (heartbeat in the future or
  unreadable); stale and ambiguous fail closed, and release of either is an explicit,
  attributable record. A single-host filesystem lease is not a distributed lock."

### D. Fold into ELZ-023 (`delivery/effect-intent`) — C6, C9

Design test: "A model/provider call interrupted by idle timeout after a tool call or
assistant output was durably recorded is `dispatched`/unknown, never re-armed; a retry
is admissible only on a durable predicate that no output or side-effect record
exists for that segment, never on a prose idempotency claim." (Same law as the
existing no-re-arm rule; this names the agent-runner instance of it.)

### E. Fold into ELZ-022 (`workflow/budget`) and `workflow/dependency-graph` — C6

Design test (second unit type, time): "Before spawning N children with per-child
budget b under concurrency k, admission computes the critical path
(⌈N/k⌉·b, or the per-wave maximum for a DAG) and rejects when it exceeds the caller's
deadline, returning the least sufficient deadline; the estimate excludes retries and
overhead by statement." No new Piece: a pure Cure function inside the budget owner
or the graph scheduler when an Assembly needs it.

### F. Fold into `workflow/dependency-graph` / `state/artifact` reasons — C5, C6

"Dependency readiness is a derived judgement tagged with the provenance of its
evidence (harness-derived, tool result, artifact reference, event fold,
model-declared); a model-declared value never by itself makes a dependant runnable."

### G. Admission record candidate: `runtime/os-isolation` OS-process Adapter (planned handle; C6, C8)

Pixir's bash tool and command boundary together are the clearest reference for the
boundary Elzoo's planned `runtime/os-isolation` must own. Draft record per
docs/capability-model.md steps 1–6:

1. **Responsibility and caller.** Run one external OS command on behalf of a Run with
   bounded concurrency, a deadline, group-scoped termination and an observed
   termination outcome. Callers: C6 (agent tool execution) and C8 (background
   transform). A deterministic build step challenges generality.
2. **Interface and invariant.** Inputs: command spec, working directory,
   deadline, grace period, host-command limits `{max_concurrent, queue_limit,
   queue_timeout}`. Outputs: `completed{exit_code, output}` (a non-zero exit is a
   completed result, not an Adapter error), `rejected{queue_full | queue_timeout}`
   (not dispatched), `terminated{stage: term | kill, deadline}`, `unknown` when the
   process-group liveness check itself fails. Invariants: the spawned process is a
   process-group leader; termination signals the group, waits the grace period and
   escalates only if the group is still alive; the escalation stage reached is
   reported, never assumed; cleanup runs even if the owning BEAM process dies;
   a process that leaves its group is a declared residual. Non-goals: security
   isolation (a BEAM process and a process group are not a sandbox), shell parsing,
   path confinement (that is `domain/authorization`).
3. **Reuse check.** OTP `Port` and `System.cmd` supply spawning; no maintained
   library owns group-scoped termination with staged escalation on both BSD and
   procps `kill` (Pixir notes a procps-ng 4.x parsing difference). Elzoo owns the
   state machine and the result schema; the signalling itself is upstream OS
   behaviour.
4. **Split test.** Admission (slot pool) and termination (group kill) can be chosen
   independently — the slot pool is the ELZ-006 bounded receiver applied to host
   processes — but the *result schema* must be one interface so a caller cannot
   confuse `rejected` with `terminated`.
5. **Failure and evidence.** Dangerous paths: a timed-out command keeps running
   after the Adapter returns (orphaned group); the collecting process is killed and
   the OS process leaks; a double-forked daemon escapes; `kill` reports success
   without delivering. Tests: timeout → group dead; brutal kill of the collector →
   group dead; escalation stage reported correctly; `queue_full` vs `queue_timeout`;
   non-zero exit is `completed`. Upstream: POSIX signal semantics and OTP `Port`
   are named contracts; no proof is demanded.
6. **Composition record.** Depends on ELZ-006 admission results and `core/envelope`
   result schema; consumes a deadline from `delivery/retry-timeout`. Delivery of
   the termination request is at-most-once within a host; cross-host is out of
   scope. Data classification: command lines may contain secrets; redact in
   Telemetry.

This record is demand-led and not inserted into the P0–P3 chain; it waits for an
Assembly (C6 or C8) that actually spawns OS processes.

## Skipped mechanisms and why (2026-11-06)

- Permission mode `:auto` default and the bash safe-list heuristic: product choice
  contrary to Elzoo's fail-closed and typed-effect-class stance; cited only as a
  negative example.
- Virtual overlay / `just_bash` simulated shell and `virtual_diff` artifacts
  (ADR 0028–0030): a workspace strategy for a coding product; brings a shell
  emulator dependency; not an isolation mechanism.
- Session Log NDJSON format, compaction (ADR 0018/0040), prompt-cache keys,
  WebSocket transport policy, provider usage events: product/provider-specific;
  ELZ-009 already has the log Contract direction via Raxol rows, and `integration/
  ai-model` stays deferred.
- ACP stdio presenter, skills/workflow templates, PATCHMD, OAuth, `monitor/` Phoenix
  app, site assets: surfaces and process, out of scope.
- Evidence mirror (ADR 0035): the idea "write-capable execution requires an
  evidence copy outside the mutable workspace" is sound, but it is a storage-layout
  decision for a product; `state/audit-log` already carries "selected storage,
  retention and tamper requirements needed".
- Delegate handle encoding (`dlg1_…` reversible wrapper over the parent id): an
  implementation shortcut the authors themselves mark as provisional.

## Open questions

1. Should `state/lease` get a Contract sentence now (proposal C) or stay a bare
   deferred reason until ELZ-009 selects a storage provider? The lease wording is
   independent of provider but could prejudge a filesystem design.
2. Proposal A's "declared repeat policy" deliberately does not adopt Pixir's fixed
   N = 2. Does the owner want a *default* in the Contract (e.g. second DENY of the
   same effect class within one Run ends the Run) or leave it to the Assembly?
3. Proposal G adds a seventh admission record. It is justified by the planned
   `runtime/os-isolation` handle and two coverage callers (C6/C8), but no current
   Assembly spawns OS processes. Record it as a task body now (like ELZ-022..024) or
   keep it as a research row until an Assembly needs it?
4. Verification gap: I did not run Pixir's test suite or any of its smoke tasks;
   maintenance facts come from the public mirror's history only, and the private
   upstream's activity is unknown.
