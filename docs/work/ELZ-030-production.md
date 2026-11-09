# ELZ-030 production implementation handoff

> Redacted before publication (ELZ-065): the password part of local test-database URLs (`ecto://user:…@localhost`) and role commands is replaced by an ellipsis; the recorded commands are otherwise exact.
> Redacted before publication (ELZ-070): local paths, session, dispatch, task and message ids, the test database name and role, and runner and machine names are replaced by placeholders or role words; hashes and byte-equality records in this file refer to the unredacted text.

Author: Orca <session id>, no helpers.
Active dispatch: <task id> / <dispatch id>.
Source commits: `134226178e1e25bb200d9bdd827383468d019f09` (production bundle)
and `167ce4939088d5caa8f8d14d294d50966479888b` (isolated upstream dependency closure).
This report's subsequent commit adds evidence only. This is the author implementation
stage, **not full acceptance, independent review, a PR or a merge**.

All work ran in `<worktrees>/elzoo-ELZ-030`, on
`task/ELZ-030`. Initial local/remote head matched
`4593b5d5a2afd6f47decd1b8aefc7165566911c4`; original coordinator claim is unchanged.
No existing test/assertion, protected CI/compiler/export file, pin, registry,
planning manifest or generated ledger was edited. The live task body is unchanged.

## Delivered source and behavior

The six files under `pieces/workflow/context-selection/` are `README.md`,
`piece.json`, `cure/elzoo/context_selection.cure`, `lib/elzoo/context_selection.ex`,
`test/elzoo/context_selection_test.exs`, and `examples/brief.exs`.
The [Piece README](../../pieces/workflow/context-selection/README.md) carries the
copyable interface, exact bounds/errors/precedence, Needs, proof limits and operations.

The facade validates exact schemas, trusted configuration, coherent clock bounds,
closed windows, reservations, candidate/node binding, hashes and actual bytes.
It rejects request authority overrides; retrieval denial/principal mismatch vetoes
selection, with an independent reconstruction post-check. Only metadata and actual
byte counts enter Cure. Enum rank preparation and reconstruction stay at the tested
Elixir translation boundary accepted in the specification.

Cure owns current access/freshness, supersession, raw reference resolution, bounded
dependency/cycle scheduling, memoized provenance, dedupe, packing and final guards.
The raw list remains in input order. Prepared edges are computed once and shared
through scheduling, charging and evaluation. Scheduling stores structural positions,
not copied node authority. The full supplied node/reference set is counted before
verdict construction; structural node/ref/fuel lists bound traversal. The 256-node
DAG constructs exactly 256 final verdicts through actual `node_verdict/5`; 4097
expansions cause zero verdict constructions. No runtime path enumeration or public
counter API was added.

R5 is explicit: distinct candidates and trusted nodes share one 256-identity
capacity, including missing candidate identities. This does not grant a second
ancestor store. Missing candidate nodes otherwise drop one occurrence, whereas
candidate/node disagreement and conflicting duplicates fail the whole call.

## Production proof connection and audit

The reduced layer-table probe is **not** the shipped evaluator. The final eight
manifest laws are:

1. `resolution_law`: native versioned first-match resolution followed by raw
   positional indexing equals independently written raw first-match lookup,
   including missing keys. No String permutation/reflection axiom.
2. `prepared_node_law`, `prepared_edges_law`, `prepared_position_law`: prepared
   entries retain raw nodes, every ordered reference and their structural position.
3. `raw_schedule_law`: scheduling over the immutable prepared array equals a
   separate raw-input traversal for readiness and cycle classification. The reference
   reads raw node references; the runtime reads prepared edges. It is not an assumed
   ordering/cycle flag. Structural position/list helpers, native comparisons and
   first-match resolution are shared, with resolution/preparation lemmas above.
4. `memo_lookup_corresponds`: actual cached verdict lookup equals separately
   written recursive raw-node evaluation over the preceding schedule suffix. It
   includes raw binding/freshness/supersession/derivation, failure reasons, declared
   source order, cache faults and maximum successful depth. It does not accept
   caller-provided safe flags or assumed cache correctness.
5. `selected_access_law`: the returned selection satisfies that reference access
   predicate instantiated with the **separate raw scheduler**. The runtime schedule
   is connected by `raw_schedule_law`; the actual internal cache by the memo lemma.
6. `selected_window`: returned selection satisfies the separately written estimate
   sum plus reservations window predicate.

The reference scheduler is a raw representation of the declared bounded algorithm,
not a theorem about arbitrary schedulers or an optimal ordering algorithm. Its
recursive permission evaluator has no memo cache; it is proof-side. The public
laws quantify over well-typed Cure inputs without safe-result/order/cache premises.
Validation/encoding is the supported facade precondition. Retrieval is explicitly
Elixir/test-grounded. These success-only laws do not prove progress, ranking,
candidate membership, external authority authenticity or estimator accuracy.
No M7 fallback or new Contract amendment was used.

Actual production compilation/audit is an assertion in the test suite:
`axioms`, `holes`, `opaque`, `unresolved`, `unaudited`, `not_proven_total` are all
empty; `absurd == 0`. Native Int arithmetic/comparison, String/binary equality,
structural list recursion and record erasure remain pinned upstream contracts.
The finite native-comparison corpus uses the actual String/digest encoding.

During integration, a fixed numeric depth literal in a rewrite goal normalized
differently from the typed Int proof argument; the helper now quantifies over
`depth: Int` and its caller supplies 1. Definitions were ordered so dependency
bodies are available to proof conversion. These are source-level proof adaptations;
no checker, pin, equality axiom or accepted requirement changed.

## Executable coverage and negative controls

`Result: 33 passed` covers production code, not reduced probes:

| Conditions | Evidence |
| --- | --- |
| B1/B4, R2 | retrieval allow/current deny, retrieval deny/current allow, retrieval and current principal mismatch, missing check, every context/policy override, mutated reconstruction post-check |
| B2 | separate ingress/selected caps, zero count/bytes, window → count → bytes precedence, skip/continue, large sums, exact fit/age, 8 MiB and +1, 256 and +1 |
| B3, R3–R6/R8 | missing/unchecked/denied/stale/tenant/superseded sources, declared failure order, candidate binding availability distinction, own-denied cycle, depth 16/17, arbitrary raw order/shared dependencies, exact DAG work count and secondary <5-second assertions |
| M1/M2 | malformed/overridden inputs make zero Cure calls; only supported facade entry used; local helpers observed as BEAM exports without privacy claim |
| M3 | all seven positive requirements; genuine production proof rejection controls; E2/E3/E4 scenario failures; fabricated selected item and transitive-denial bypass |
| M4/M5 | SHA-256 mismatch, bytes undercount, tenant/current binding, no raw content at the Cure call seam |
| M6/M7, R1 | clean totality audit, raw scheduler/preparation/memo/final laws, native Unicode/digest/number agreement; no closure fallback |
| Composition/copy | exact-write ELZ-024 read-marker fixture, envelope version distinction, byte-identical copied source, separate VM and renamed modules/record tags |
| Independent finite oracle | 8 three-node DAG edge subsets × 8 permission assignments × 3 raw orders, with expected selected membership from an Elixir traversal |

Seven production proof-negative mutations independently alter: reserved-window
accounting, final access guard, own-check evaluation, prepared edges, runtime cycle
classification, positional cache address, and raw resolution. Each must fail proof
conversion; its proof-erased executable still compiles, excluding parser/type-shape
failure as the explanation. E4 deliberately weakens both runtime and reference
freshness: its proofs still check, but its scenario admits stale data and fails the
expected result. This is recorded as a limit, not hidden as proof rejection.

The named DAG scenario is 16 layers × 16 nodes, 3840 declared edges, total 4096.
Both the complete valid call and 4097 rejection must take <5 seconds on this Mac
with four schedulers. Exact call-count assertions are primary; elapsed time is
machine-bound scenario evidence, not a universal latency guarantee.

## Commands, exits and reproducibility

Every command below ran from the assigned worktree. All Mix/Elixir commands used:

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'
```

| Command (after that environment prefix) | Exit and actual result | Log |
| --- | --- | --- |
| `ELZOO_TEST_DATABASE_URL=ecto://<test role>:…@localhost/<test database> mix setup` | 0; setup emits no `Result: N passed` | `/tmp/elz030-production/setup-production.log` |
| `mix test pieces/workflow/context-selection/test/elzoo/context_selection_test.exs` | 0; `Result: 33 passed` | `/tmp/elz030-production/test-delivery.log` |
| `MIX_ENV=test mix run /tmp/elz030-production/export.exs` (put `MIX_ENV=test` in `env`) | 0; `EXPORT_HASHES_OK: 21 files`, `Result: 73 passed`, `EXPORTED_CONSUMER_EXIT=0` | `/tmp/elz030-production/export3.log` |
| `mix format --check-formatted` | 0 | tool output, no Result line |
| `elixir -e ...System.version...OTP_VERSION...` | 0; Elixir 1.20.4, OTP 29.1.2 | tool output |

Also: `git diff --check` exited 0; live issue JSON/body comparison exited 0:
14,371 equal UTF-8 bytes, SHA-256
`a8354a552fff51569162cb738268e095dcba11efec87cd7c4c5fead31148994f`.
The scoped diff contains only the new bundle and work evidence. No database was
created/altered, service modified or CI manually dispatched.

The exported run exercises the actual `Elzoo.Export.plan!/write!` machinery with
an **in-memory** pending manifest row, not a persisted registry edit. It copies
`core/envelope`, `domain/authorization`, `workflow/context-selection`; verifies all
21 receipt hashes; then runs their tests in a fresh `:consumer` project with only
upstream code paths and no root Registry/Application. The receipt truthfully marks
uncommitted work at export time (the test-harness correction and work report).
This supplements, and does not replace, the post-integration aggregate export gate.
The exported context-selection suite itself launches a second VM for original and
renamed module/record-tag copies; its harness follows Cure's required application
closure, excluding optional uninstalled applications and excluding Elzoo/consumer.

Earlier copy-harness iterations failed because only Cure's ebin was passed
(`metastatic.app` absent), then because an optional `rustler` application was treated
as mandatory. Those failures were not accepted passes; the closure correction is
in `167ce49`, and both final targeted and actual exported suites pass. The initial
ad-hoc export command used Mix's default dev environment and compiled dependency
artifacts there; the final command explicitly used `MIX_ENV=test`. No dependency
source/pin or shared tool was changed.

Cure is **balungpisah/cure-lang
`208248063d64e621782cd26dd30698ee42850a89`**, verified from installed dependency Git.
PR #85/main merge `230cc5b211ef0599fe6a1980286c952111e5e0ae` is included via the
previous normal merge `4017b167162e5acca42c89e5f19aee34acc169ca`. A normal fetch at
this stage still found main at `230cc5b`; no further merge was needed.

**Full `mix check` has not run for this final bundle.** Coordinator-owned metadata
integration must first make its manifest/claims part of the catalogue and aggregate
consumer. Fresh setup already passed on the required pin; the coordinator must run
full public validation with the same environment and only the disposable test database before
final review. No targeted or in-memory export pass is represented as that acceptance.

## Exact metadata handoff

1. In `registry/catalogue.json`, reconcile only `workflow/context-selection`:
   `disposition: "own"`, `status: "ready"`,
   `manifest: "pieces/workflow/context-selection/piece.json"`, with an accurate
   bounded-access/provenance summary; retain demand-led phase. Remove its obsolete
   deferred reason as appropriate. Direct dependency closure is exactly
   `core/envelope` and `domain/authorization` (both accepted); no new task dependency.
2. Reconcile the canonical planning view for this row under coordinator policy;
   preserve task identity, dependencies and the unchanged issue-body SHA above.
   Do not mark issue acceptance/merge merely because a source manifest is prepared.
3. Run `mix elzoo.ledger` under the required environment to generate the ledger;
   the author has not hand-edited it. The manifest records 8 proof claims, a type
   claim, scenario/copy tests, Cure/Elixir/OTP upstream contracts and host Needs.
   Direct providers are `cure`, `elixir`, `otp`; required application is `crypto`.
4. Operational declarations: telemetry/control `not_applicable`; trusted per-call
   config `supported`, grounded by the bundled tests. No hot reconfiguration claim.
5. Run full setup/check, real persisted-registry export aggregate, independent
   final exact-diff review and the later PR/claim cleanup sequence. Existing generic
   aggregate consumer includes every ready Piece; **no protected harness/compiler/
   selector edit was needed**. There is no fixed per-ID consumer for this new ID;
   affected selection correctly uses aggregate coverage until independently extended.

No unresolved behavioral decision or known production failure remains in this
handoff. Full-check/integration/review remain real outstanding gates, not waived.
The author did not open a PR, merge, remove the claim or modify labels/Contract.
Progress comment: https://github.com/balungpisah/elzoo/issues/47#issuecomment-6714361642.

## Bundle hashes

These hashes describe the source bundle at `167ce49`; evidence-only commits do
not alter it. Export receipts generate their own hashes rather than accepting
hand-entered source hashes as validation.

| Relative file | SHA-256 |
| --- | --- |
| `README.md` | `b170f76438749578a93df9b6e2e37f2341300ffda74ebc46cf5950b08b80ed04` |
| `cure/elzoo/context_selection.cure` | `40e6b029271010d8f6a207468db6e44aea067c4e38411c11c48c96511712827a` |
| `examples/brief.exs` | `54297ef8e7fd9d6ae989a9f6fbe8f9b340d11116dbce1b064f8a5021efcc8f0f` |
| `lib/elzoo/context_selection.ex` | `31d7a3144d3785d53822efe9539439b416bd8ca722585b4d9abd97a1bbdf62fe` |
| `piece.json` | `81007ed4b12f6437e3ffa67f161f6401741aaf023b28d2db98454f5c43d74369` |
| `test/elzoo/context_selection_test.exs` | `dc3d02321ccdd71c83c56859d446735b9c3619d61e72fb1fd531d46b7ac4efc8` |
