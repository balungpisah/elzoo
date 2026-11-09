# First-wave preflights

This note records interface decisions and evidence, not a second status/dependency
board. [release-plan.json](release-plan.json) owns planning dependencies and
selection gates; live [#36](https://github.com/balungpisah/elzoo/issues/36),
[#38](https://github.com/balungpisah/elzoo/issues/38) and
[#43](https://github.com/balungpisah/elzoo/issues/43) remain complete task Contracts.
The original task files are unchanged. Adoption and each task's preflight must
pass before implementation dispatch. The parent coordinator owns the decisions
below and records acknowledgments in each concrete assignment.

## Accepted prerequisite evidence

The following exact merge SHAs are ancestors of the inspected baseline main;
GitHub merge-commit checks, independent review and acceptance records were read.
They are historical evidence, not inferred from issue closure and not fresh
reruns at those historical revisions. Machine-readable links are in the manifest.

| Prerequisite / consumers | Merge and acceptance | Scoped grounding |
| --- | --- | --- |
| ELZ-003 / all three | [PR #30](https://github.com/balungpisah/elzoo/pull/30), `7ce6b9616289d7fba09253163d43c53a88586b90`; [acceptance](https://github.com/balungpisah/elzoo/issues/3#issuecomment-6667213363), [exact-head review](https://github.com/balungpisah/elzoo/pull/30#issuecomment-6666918033) | Cure type/ABI checks, finite Envelope/Edge/Wiring and copied-consumer checks; no new universal proof. Merge backend job 127472315549 and Gleam 127472315486 succeeded on machine A; acceptance records 19 Ash + 82 root checks. |
| ELZ-004 / ELZ-022 | [PR #32](https://github.com/balungpisah/elzoo/pull/32), `81d7d21d8c0a86aae8d47ce9b0e0389b15ca865d`; [acceptance](https://github.com/balungpisah/elzoo/issues/4#issuecomment-6669895410), [review](https://github.com/balungpisah/elzoo/pull/32#issuecomment-6669698776) | Finite Unit/Adapter/host/JSON and consumer scenarios, OTP contracts; merge backend job 127537028186 and Gleam 127537030094 succeeded on symbolic. Acceptance records 19 + 143 checks; volatile partial-failure limits remain. |
| ELZ-015 / ELZ-024 | [PR #18](https://github.com/balungpisah/elzoo/pull/18), `a8b3a099397bff5e90d9a3f010797243d768edd0`; [acceptance](https://github.com/balungpisah/elzoo/issues/17#issuecomment-6659498380), [review](https://github.com/balungpisah/elzoo/pull/18#issuecomment-6658950881) | Nine isolated Ash tests plus 34 baseline checks; historical Linux merge run 42036106498 succeeded. This predates the owner-machine-only migration and is **not** machine A evidence. Trusted actor maps, volatile ETS, sequential actions; no authentication, durable approvals or production concurrent-update guarantee. |

At initial capture, remote task claims were ELZ-010 and this ELZ-033; no
`task/ELZ-022`, `task/ELZ-024` or `task/ELZ-026` existed. This observation never
reserves them. Main subsequently merged ELZ-010 at `32aef4e`; its owner
reported cleanup while retaining merge acceptance. The manifest records the
latest fetched refs; the capacity rule still counts any active implementation
worker, independent of branch visibility. At dispatch fetch/prune and check their exact refs, current live
bodies, prerequisite ancestry and acceptance again. A new branch requires the
first-push claim; an existing branch requires recorded handoff, never force.

## Frozen shared boundary

Consume [core/envelope](../../pieces/core/envelope/README.md),
[core/port](../../pieces/core/port/README.md) and the existing
[Unit owner pattern](../../pieces/runtime/unit/README.md) unchanged. The manifest
records ready file hashes; source inspection included `Elzoo.Unit.step/2`'s
serialized call to the supplied pure transition.

- Envelope v1 is the exact neutral map with opaque payload; no metadata bag.
  Caller IDs are nonempty UTF-8, exact equality without normalization; they do
  not prove uniqueness, authenticity, authority or business completion.
- Port descriptors have exactly id, direction, schema_id, schema_version;
  compatibility is exact output-to-input identity/version. A matching descriptor
  does not validate a payload. New Piece payload/result schemas live behind new
  schema IDs and explicit codecs; never extend ready Envelope/Port fields.
- Shared DeliveryResult keeps its outcome × dispatch matrix. `completed` means
  completion at the named boundary, not business acceptance. Timeout or loss
  after possible dispatch is unknown, never authorization to retry. Request
  message/correlation/attempt identity is echoed under the existing Contract.
- Envelope deadline is absolute Unix milliseconds. Pure policies receive time
  as input and perform no clock I/O; OTP timers remain execution concerns.
  Do not put a monotonic timestamp into an Envelope wall-clock field or reuse a
  process-local timestamp across owner restarts. No implicit shared time/schema
  extension is authorized.
- No shared Work Item, Run, principal, durable approval or multi-head storage
  schema is introduced. Future integration must explicitly translate each
  task-local schema, and use a new Piece ID if ready behavior needs changing.

## ELZ-022: bounded report and child-run admission

Product aims: P05/C2 report budgets and P07/C6 bounded agent delegation; P06/C7
and C9's other unit challenge reuse. Own one pure reserve/settle/release policy
and one volatile OTP owner per budget identity, not quota or financial posting.
Published prerequisites remain ELZ-003 and ELZ-004.

Local decisions allocated to the ELZ-022 owner, to state in its Contract and
obtain early independent review:

- Identity uses nonempty UTF-8 text with exact equality for a caller-scoped
  budget identifier and stable `cost_ref` within that budget. Retries keep that reference. Reset/generation and reuse rules
  must prevent a late settlement from mutating a replacement budget; a Run
  string is a reference supplied by the caller, not a new workflow/run capability.
- Amounts carry an explicit unit. Seal cap/unit per identity, reject changed
  limits, preserve observed overage, clamp only reported remaining budget to
  zero, and stop admission in overage or unreadable state. Check-and-reserve is
  one serialized transition; no read-then-increment window.
- Use explicit Unix-millisecond expiry and `now` inputs in the pure transition;
  expiry is reached when `now >= expiry`. The owner translates its clock to
  that domain and documents clock-skew assumptions; elapsed timers remain
  process-local. The owner must document idempotent release/settle and reset
  behavior and test restart with
  outstanding reservations. Volatile restart loses state; it cannot establish
  that an external call was free or that forgotten settlements are safe.
- Preserve the task's rejection of non-positive/non-finite amounts; do not
  silently relax it for a zero-cost case. If zero actuals or reset semantics
  conflict with a required caller, report the Contract finding to the coordinator
  before implementation rather than weakening acceptance.
- Critical-path time admission takes explicit `N`, `k`, bound and deadline:
  test `ceil(N/k) * b` (or per-wave maximum for DAG input), least sufficient
  deadline, invalid inputs and the declared exclusion of retries. This adds no
  scheduler and no clock read to Cure.

Release evidence remains every acceptance item in #36: selected admission-cap
and idempotence laws through real Cure, concurrent last-unit test, expiry and
restart, overage, changed limits, unreadable-owner fail-closed and operational
applicability. Admission bounds spending permission; a strict total charge
requires a provider-enforced maximum. No provider/lockfile adoption is needed
for the scoped pure policy and OTP owner.

## ELZ-024: exact-action human consent under bounded authority

Product aims: P03/C5 human review, P07/C6 publication, with C3 refund and C1
invitation as distinct design challenges. Published prerequisites remain
ELZ-003 and ELZ-015. Two Pieces stay separate: `domain/authorization` and
`workflow/approval`; no duplicate Ash resource policy engine.

The coordinator selects the following task-local boundaries for independent
review in ELZ-033. They resolve B24.1–B24.3 without changing the live issue or
any ready shared schema. ELZ-024 may start only after this decision review and
adoption acceptance; its worker must acknowledge these choices, record the
concrete Cure/Elixir API in its Contract, and obtain early independent review
before implementing that API. A representation that cannot support the named
laws is a blocker to report, not permission to weaken them.

### B24.1 — Structural exact-action binding

Use structural equality of validated typed values, not a JSON or BEAM term hash,
for approval binding. The task-local action record contains proposer identity,
tenant, resource, stable action identity, typed effect class and payload. The
write set is a finite set of typed `(target, field, value)` entries. Entry
order has no meaning: validate first, coalesce structurally identical entries,
then sort by the UTF-8 byte order of `(target, field)` for a stable presentation.
Different values for one target/field are a conflict, never last-write-wins.
Authority sets use exactly the same validation and normalization. Bind and
compare these normalized sets; reordering or identical duplication does not
change the authorized action.
The initial portable value domain is null, booleans, integers, valid UTF-8 text,
byte strings, ordered lists and records with unique UTF-8 field names. Types
remain distinct; records compare by field name independently of input order;
lists compare in order. Accept record fields as a duplicate-preserving list of
pairs at the validation boundary; reject duplicate names before building maps.
External decoders must likewise reject duplicates before lossy JSON/map
conversion. A pre-collapsed map cannot establish that duplicate input was
rejected. Reject duplicate fields, floats, process/function
values, malformed data and unknown control fields. Do not normalize text or
coerce integers, strings and booleans into one another. The implementation
Contract must declare finite input size/depth bounds and reject exceeded bounds
before evaluation; it must not silently truncate values. This is a new local
schema, not an extension of Envelope's opaque payload Contract.

Bind consent to the complete validated action, exact proposed writes and policy
identity `(id, version, content hash)`. Policy identity/content comes from trusted
configuration outside the proposal; the host supplies its SHA-256 digest of
its immutable versioned policy artifact. The pure Piece compares and carries
that identity; it does not authenticate the host or prove the digest's origin.
Compare current policy identity and the current reducer result at release;
a reused id/version must not bypass a changed content hash. Preserve structural
binding data for replay; a digest alone is not the payload equality check.
Reject a proposal carrying policy, bounding authority or approval as control
fields. Payload business data never supplies those controls. Conflicting writes
to the same `(target, field)` fail closed; identical duplicates are coalesced.
No arbitrary executable policy DSL or cryptographic protocol is introduced.

### B24.2 — Host-verified evidence and explicit time/scope

Pass a validated evidence record separately from the proposal: configured
verifier identity, reviewer identity, exact request tuple
`(Run, action id, requirement name, requirement version, revision)`, decision,
issued-at time and stable evidence identity. Only the trusted host's configured
verifier path may produce this input. The pure boundary additionally checks the
verifier allowlist and exact requirement/request match. Self-asserted verifier
names in proposals, tool arguments or model text are rejected; the pure input
record alone does not establish authentication. Real authentication and verifier
transport remain explicit Needs of the consumer, and tests use trusted fixtures.

Use explicit nonnegative Unix-millisecond `now` and `issued_at`, positive
`max_age`, and a required explicit finite consent expiry greater than its
issue time. Missing expiry fails closed; there is no implicit unbounded consent.
Reject future-issued evidence and evidence with `now - issued_at >= max_age`; consent expires at
`now >= expiry`. Revocation wins over retained consent. Recheck freshness,
revocation, current requirement and authority when releasing or restoring.
A stale request revision changes nothing; a changed requirement supersedes the
old request and creates revision + 1. Preserve reviewer and verifier attribution.

Trusted caller context supplies the current Run, its root and ancestry;
identifiers alone prove no relationship. Once-scope is consumed by one release
of its exact request; replay of that same release event is idempotent and emits
no second write. Run-scope permits only the named Run. Root-scope permits only
that root and Runs whose supplied ancestry includes it. Scope never broadens
the bound actor/resource/action/payload/policy or grants authority; every use
must still match that exact binding and current request requirements. The
release transition records completion keyed by the full request tuple, with
evidence identity, bound action and released writes as data. Successful release
updates that record and emits writes in one pure transition; once-scope also
marks `(verifier identity, evidence identity)` consumed. A repeated release for
that request emits no writes, even with a new evidence identity. Reuse of an
evidence identity with different binding is rejected, never overwritten.
Rejected/failed release emits no writes and adds neither a release record nor
a once-consumption marker; expiry, revocation and supersession still invalidate
the consent as above. Replay folds these recorded transitions to rebuild state;
it does not re-emit past writes. The concrete local API must preserve this
state/result distinction. This establishes no durable storage or cross-owner
exactly-once guarantee.

### B24.3 — Current authority outside proposals

The trusted owning caller supplies current proposer authority, approver authority
and, for a child, current parent effective authority, separately from the
proposal. Represent each as a finite set of permitted typed writes; compare
sets structurally over the B24.1 schema. Child effective authority is bounded
by the intersection of its own and its parent's sets. Before the initial
ALLOW or ASK decision, both proposed permitted writes and proposed escrowed
writes must be subsets of that current effective authority. A violation rejects
the whole proposal with no newly permitted or escrowed writes; do not silently
trim the action to fit. Apply the same containment test at release and restore.
Missing, invalid or
unavailable required authority/policy/verifier context fails closed with an
explicit reason and no permitted or released writes; it is not an empty ALLOW.
A malformed policy or conflicting writes also fails closed. Preserve the
reason distinction between policy DENY, invalid input and unavailable context.

Re-evaluate the ordered policy reducer against current context at release and
restore. DENY or evaluation failure wins over old consent; ASK cannot be
resolved by model text. Check the approver can perform the exact proposed
writes and is not the proposer of the ASK. Approval can release only escrowed
writes still bounded by current effective authority. Decisions carry the
policy identity, permitted/escrowed writes and attributable result/reason data;
retention is caller-owned and is not optional telemetry. No principal service,
policy engine provider, authentication guarantee or shared Run schema is added.

These choices are proposed technical decisions pending exact-SHA independent
review, not executed evidence. A necessary change to a ready shared Contract
or a new provider remains a separately admitted prerequisite. Module names and
fixture IDs stay with the worker; the current issue's acceptance is unchanged.

Required evidence stays #38's precedence, escrow and non-escalation laws,
payload/policy drift, release DENY, stale revision, self/under-authorized approval,
model-text refusal, scope and replay scenarios, plus configured-verifier/age
behavior. Compare the existing Ash spike; do not add Ash to pure bundles just
for comparison. Deferred principal/audit/Run handles do not block isolated pure
policy tests and do not supply authenticated identity or durable approval
storage. Retained decision data may be supplied to a future storage owner;
telemetry is not that owner. Durable persistence is not claimed here.

## ELZ-026: readiness from attributable facts

Product aims: P03/C5 human/automated prerequisites and P07/C6 child work;
C7 external time/trigger facts challenge generality. Published prerequisite
remains ELZ-003. Work Item IDs/lifecycle tags in input fixtures represent a
caller-owned model, not a durable Work Item implementation.

Local decisions allocated to the ELZ-026 owner for early Contract review:

- State the edge orientation in every API/example: a proposed directed
  blocking `from -> to` creates a cycle iff `to` already reaches `from`.
  Explicitly map this direction to the dependency explanation's target; no
  implicit reversal between readiness and admission. Only blocking edges
  participate; informational/hierarchy edges do not block.
- Freeze task-local lifecycle mapping distinguishing accepted completion from
  cancellation or closure without completion. Unknown/expired facts cannot
  satisfy a prerequisite. Provide `now` explicitly with declared time units,
  expiry at `now >= expiry` and explicit caller-selected deferral/order rules;
  use Unix milliseconds for fact expiry and `now`, with no clock read in the
  reducer. Stable item/source IDs use nonempty UTF-8 exact equality; tags and
  ID shape establish no authority.
- Keep `tool result`, `artifact reference`, `event fold`, `model-declared`
  provenance tags plus source/expiry. A model-declared value alone cannot
  make work runnable. Host-supplied provenance does not authenticate itself;
  ingestion verification is outside this pure Piece. Explanation and readiness
  must use the same predicates, with duplicate node/unknown dependency/cycle
  reported separately and every unplaceable node named.
- Concurrent admission test uses a volatile owner/test-double store that
  revalidates the current **whole blocking graph** and commits in one serialized
  operation. Test two individually plausible racing edges that together form
  a cycle. Two separate endpoint checks without joint commit are insufficient.
  This demonstrates the listed in-process scenario only, never a durable
  multi-head transaction or distributed agreement.
- Compare libgraph at its reachability/topological-sort boundary. No pin change
  is authorized here: use a focused isolated evaluation or ordinary graph
  mechanics if sufficient. If actual library adoption is necessary, block that
  implementation on separately admitted dependency ownership; do not quietly
  change `mix.exs`/lockfiles. No scheduler/claim/lease service is added.

Selected acyclicity and fact-satisfaction laws must check the actual pure
admission/satisfaction decisions. A supplied boolean or a vacuous fixture is
not a substitute for the issue's quantified claim. If the pinned Cure cannot
check the required law, report the exact limitation for deliberate Contract
review, never relabel finite tests as proof. Preserve #43's concurrent-cycle,
closed-vs-completed, expiry and model-declared negative scenarios and operational
applicability.

## Dispatch, resources and handoff

The canonical job selection gates reference this note. Local unspecified behaviors above and B24's selected boundaries must be
concretely recorded and reviewed before dependent implementation. Missing essential decisions block
only their task; a complete independent wave need not wait for V2/V3 providers.
The coordinator resolves shared-interface prerequisites; workers cannot widen
the accepted shared records. Early independent review is required for these
pure Contracts/proofs, authority and typed-boundary claims.

Candidate order and capacity are in [roadmap.md](roadmap.md): ELZ-022 and
ELZ-026 first, then ELZ-024 when B24 and a slot clear, always counting ELZ-010
inside the three-worker ceiling. One independent review slot and coordinator
capacity remain reserved; no worker delegates. Each assignment records exact
claim/workspace/base/session identity and named owned directories; none are
invented in this preflight. The coordinator serializes metadata/ledger merges,
provider ownership and the existing machine A backend queue. Workers use
isolated databases/ports and their own checkout's Cure build cache.

The parent receives final SHA, exact commands/results, source/Contract limits
and outstanding decisions, then arranges exact-SHA independent review and
GitHub merge acceptance. A passing planning check, accepted prerequisite, or
published issue is not itself implementation readiness or acceptance.
