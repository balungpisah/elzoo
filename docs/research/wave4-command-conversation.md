# Wave 4 command/conversation acceptance

## Scope

This is a root acceptance harness for the existing `CheckedCommand`,
`Conversation` and `RunEngine` boundaries. It adds no Piece or production
behavior. It does not establish the later HTTP event-to-answer flow or
outside-event waits.

The acceptance module is synchronous and uses the real `Conversation.prepare/3`
as the CheckedCommand descriptor preparer. Its host authority comes from a
separate pure prepare against the current public resource snapshot; the test
checks that preparing alone changes neither the resource, retained result nor
outbox, using the public `Outbox.pending/3` boundary for both stores. The
descriptor uses a fixed identity, the actual `PayloadSchema`
object port (required `message_id`, optional `text`), and the same-append
`conversation-notify` destination. Resource reads are tenant/actor/resource
scoped. Stream identifiers use the documented `cc1` form; no private Codec is
used as a public interface.
Policy content hashes are SHA-256 over deterministic serialization of each
declared artifact without its hash field, so ALLOW, DENY and ASK have distinct
immutable identities. Changed-policy replay uses the current, differently
identified artifact.

The bounded helper requires only the RunEngine test support file. PostgreSQL
fixtures use the existing SQL `PostgresHarness` and `TestMigration`, with a
test-local Repo so connection reopen does not disconnect the RunEngine fixture.
Each PostgreSQL fixture has its own schema. Memory fixtures provide the
volatile comparison.

## Host assumptions and limits

The harness assumes the host already authenticated the tenant, actor and
source, and issued scoped resource-read grants. It also assumes the host
allocates a globally appropriate stable Run ID. The conversation's
`completed` booleans and input/Run facts are supplied host facts; they do not
observe that these test Runs actually completed. The host must supply current
policy artifacts, exact own/parent/approver authority, revocation state and
time. Exact own writes derived from a pure proposal are only fixture allowance,
not authentication or authority issuance. Command-verifier provenance and
command/Run purpose separation are host responsibilities; distinct test
verifier IDs do not prove provenance.

Native duplicate evidence control is a bounded public duplicate error. The
already-retained evidence is revalidated on same-Run dispatcher restart via
startup release; this is distinct from the command's terminal receipt replay.
No production defect or complete Wave 4 claim follows from this harness. The
later HTTP event-to-answer flow and outside-event waits remain out of scope.

## Scenarios

- Memory and PostgreSQL: empty view; input; immutable Run association; answer
  gated on the matching completed-Run fact; handle reconstruction; another
  Run; and a second input associated to the same Run. Views, revisions,
  retained results, PostgreSQL record counts and same-append outbox counts are
  asserted exactly.
- Both stores: retained policy and gate denials across changed policy/gate;
  equal replay without writes; equal-text duplicate message IDs; immutable
  association; incomplete and mismatched answers; operation-identity reuse
  against another resource; independent tenant and actor receipt-scope
  mismatches; and missing resource grants.
- PostgreSQL CAS race: two independently identified requests start at one
  revision and meet at a preparer barrier that still calls
  `Conversation.prepare/3`. Exactly one input wins, the other retains stale;
  a known-stale retry uses a new identity/current revision, while the old
  identity remains terminal.
- PostgreSQL uncertainty: commit plus lost response and confirmation/readback
  outage remains unknown until the original identity is read after reopening
  the caller and Repo connection. The resource, result and outbox are counted
  without reappend. A separate pre-commit rollback leaves no mutation,
  terminal result or outbox entry. These are not database-server crash or
  failover claims.
- PostgreSQL approval: an actual pending answer follows an input and Run
  association. Ordinary refusal cases cover wrong purpose with an equal
  textual Run/action owner, wrong Run/input facts, changed exact writes,
  revoked evidence and insufficient current authority. Exact history, outbox
  and pending result snapshots remain unchanged; the same evidence then
  succeeds after reopening and repeated release returns the single terminal
  result. The released answer, full view, retained result and exact matching
  outbox notification are asserted. A second valid pending command reuses the
  same `{verifier, evidence_id}` bound to its own key and is refused without
  changing its pending state, history or outbox; fresh evidence then releases
  it. Permanent stale release is tested separately as ELZ-249's terminal
  stale conflict. Command- and Run-purpose evidence use distinct verifiers.
  The equal-owner wrong-purpose case uses a purpose-shaped fixture map only;
  it does not assert authentication or acceptance of genuine Run-purpose
  evidence.
- Native parity: real RunEngine start/input/control/status and CheckedCommand
  use matching tenant, principal, effect, policy, schema, payload and portable
  conversation replacement. The actual gate frames and contexts compare
  exactly. Captured Engine proposal, policy and authority inputs match the
  command's authorized own writes. Persisted decisions assert exact DENY
  (`:deny`, `{:rule, "conversation-policy"}`, action/policy identity, no
  permitted or escrowed writes) and ASK (`:ask`, exact action/policy, escrowed
  writes and requirement); gate-denied, invalid and raising paths persist no
  authorization event or input observation. ALLOW asserts the exact permitted
  writes against the command's stored conversation field. The allowed Engine
  observes `local_work` only after checks. Native ASK attempts
  insufficient-authority release on both paths with matching evidence timing
  and reviewer facts, and preserves both pending results. Restoring only exact
  own and approver authority allows command release; the Engine's identical
  evidence control returns the bounded duplicate reply, then same-Run
  dispatcher restart revalidates stored evidence at startup and dispatches
  once. Public status and retained CheckedCommand results are asserted.
- Bounded command-only allocation observation: before constructing the
  comparison Engine, the fixture's RunApprovalRelease status, Run-store rows
  and head, empty Unit-store rows, and Engine registry remain unchanged across
  the command call. This observes only those fixture-owned footprints; it is
  not global allocation tracing.

## Environment and checks

Toolchain: Elixir 1.20.4 / Erlang-OTP 29.1.2. The disposable test service
reported PostgreSQL 16.15 and pgvector 0.8.7 through the Ecto Repo fixture.

Focused commands:

```sh
mix format --check-formatted test/wave4_command_conversation_test.exs test/support/wave4_command_conversation_helper.exs
source .elzoo-services/env.sh && mix test test/wave4_command_conversation_test.exs
git diff --check
```

Focused result:

```text
Finished in 11.9 seconds (0.00s async, 11.9s sync)
Result: 8 passed
Exit code: 0
```

The listed formatter and diff checks also exited 0 without diagnostics.

Roadmap and claims checks:

```sh
python3 scripts/check-roadmap.py --live
python3 scripts/check-claims.py
```

```text
ROADMAP CHECK PASSED: 147 catalogue IDs; 2 separate candidates; 277 jobs; 13 products; acyclic and release-ordered; generated views agree; 581 local links checked; live Contracts match
No tracked claim metadata
```

The earlier affected gate reported 2,809 passed and 84 excluded on
`74aca22c2ae7d5a8e62ee10c8141e2dd7aa7518e`; it predates these review
corrections and is superseded. The final `mix check --affected origin/main`
completed on `7bd0b65e8d0243e60a721aff6c02fc391be6653e`:

```text
Finished in 2779.1 seconds (191.1s async, 2587.9s sync)
Result: 2809 passed, 84 excluded
ELZOO STAGE root_suite end utc=2026-11-17T07:33:35.834585Z elapsed=2791.9
ELZOO AFFECTED CHECK PASSED (not full consumer acceptance; see selected consumer scope)
Exit code: 0
```

## Harness negative controls

1. A temporary faulty descriptor preparer changed the prepared snapshot's
   association to `run-two` before calling the real `Conversation.prepare/3`.
   After the direct preparation comparison was moved below real execution,
   the faulty descriptor reached `CheckedCommand.execute`; the expected
   domain-conflict assertion failed because the fixture's exact authority
   blocked the proposed write:

   ```text
   Assertion with == failed
   code: assert mismatch == {:conflict, {:domain, "association_mismatch"}}
   left: {:denied, {:authorization, :authority_exceeded}}
   right: {:conflict, {:domain, "association_mismatch"}}
   Finished in 2.4 seconds (0.00s async, 2.4s sync)
   Result: 0/1 passed, 7 excluded
   Exit code: 2
   ```

   No inconsistent answer was committed. The helper was restored byte-for-byte
   (`sha256 a5014c292759805d96227c74bd8bbd22aebfdce2a5672caae113651d6b556bca`).

2. A temporary change to the actual RunEngine `principal` option let the
   Engine construct its own gate context. The context equality assertion
   failed on the changed proposer, rather than on a test-side captured frame:

   ```text
   Assertion with == failed
   code: assert engine_gate_context == command_gate_context
   left: %{
            tenant: "wave4-tenant",
            effect_class: "conversation.write",
            proposer: "parity-control-principal"
          }
   right: %{
             tenant: "wave4-tenant",
             effect_class: "conversation.write",
             proposer: "wave4-actor"
           }
   Finished in 2.6 seconds (0.00s async, 2.6s sync)
   Result: 0/1 passed, 7 excluded
   Exit code: 2
   ```

   The test was restored byte-for-byte to use `principal: Fixture.actor()`
   (`sha256 53771a4ec08d54852cb1930faeb3e2380b42f3f7ea5472c431b9d83c78e4c28f`).
