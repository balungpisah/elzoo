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

The bounded helper requires only the RunEngine test support file. PostgreSQL
fixtures use the existing SQL `PostgresHarness` and `TestMigration`, with a
test-local Repo so connection reopen does not disconnect the RunEngine fixture.
Each PostgreSQL fixture has its own schema. Memory fixtures provide the
volatile comparison.

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
  result. Permanent stale release is tested separately as ELZ-249's terminal
  stale conflict. Command- and Run-purpose evidence use distinct verifiers.
  The equal-owner wrong-purpose case uses a purpose-shaped fixture map only;
  it does not assert authentication or acceptance of genuine Run-purpose
  evidence.
- Native parity: real RunEngine start/input/control/status and CheckedCommand
  use matching tenant, principal, effect, policy, schema, payload and portable
  conversation replacement. The actual gate frames and contexts compare
  exactly. Captured Engine proposal, policy and authority inputs match the
  command's authorized own writes; the Engine's persisted authorization
  decision has `verdict: :allow` and the exact same permitted writes as the
  command's stored conversation field. The allowed Engine observes
  `local_work` only after checks. Native ASK attempts insufficient-authority
  release on both command and Engine paths with matching evidence timing and
  reviewer facts, and preserves both pending results. Denial, gate denial,
  invalid/raising gates and refused Engine approval do not dispatch local work.
  Public status and retained CheckedCommand results are asserted.
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
Finished in 4.2 seconds (0.00s async, 4.2s sync)
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

The required `mix check --affected origin/main` is pending and will be recorded
after its single run.

## Harness negative controls

1. A temporary faulty descriptor preparer changed the prepared snapshot's
   association to `run-two` before calling the real `Conversation.prepare/3`.
   The composition assertion rejected its otherwise-successful answer, which
   carried both the `run-two` association and answer:

   ```text
   Assertion with == failed
   code: assert Fixture.descriptor().prepare.(mismatch_snapshot, mismatch_request, host_facts) == pure_preparation
   right: {:refused, "association_mismatch"}
   Result: 0/1 passed, 7 excluded
   Exit code: 2
   ```

   The observed left-hand preparation was `{:ok, writes, response}` with
   `run_id: "run-two"` in both the association and answer. The helper was
   restored to `prepare: &Conversation.prepare/3` before final focused
   validation.

2. A temporary change to the actual RunEngine `principal` option let the
   Engine construct its own gate context. The context equality assertion
   failed on the changed proposer, rather than on a test-side captured frame:

   ```text
   Assertion with == failed
   code: assert engine_gate_context == command_gate_context
   left: %{tenant: "wave4-tenant", effect_class: "conversation.write", proposer: "parity-control-principal"}
   right: %{tenant: "wave4-tenant", effect_class: "conversation.write", proposer: "wave4-actor"}
   Result: 0/1 passed, 7 excluded
   Exit code: 2
   ```

   The test was restored to use `principal: Fixture.actor()` before final
   focused validation.
