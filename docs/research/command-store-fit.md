# ELZ-245 command-store fit experiment

## Outcome

The final baseline run listed 25/25 ExUnit tests passing against the disposable PostgreSQL service. Both candidate paths passed the finite cases for the fixed trigger-binding and conversation-message callers. Applying the task's decision rule, **prefer A, the existing PostgreSQL Store path**, for any later caller integration study. This result is finite test evidence, not a proof of the Store contract or production readiness. It does not justify a production Piece or API task: neither fixed caller was integrated here, and no caller-specific store gap requiring a new boundary was demonstrated.

The experiment changes no production Piece. A candidate minimum boundary, if a later task establishes the need, would accept host-supplied tenant/actor/operation identity plus one of the two typed declarative requests, and offer execution and identity-scoped result lookup. It would retain the exact identity `(tenant, actor, operation_id)`, bind target kind/resource ID and the authorized write set into the request digest, and return the observed result families: applied, denied, approval-pending, identity/stale-revision conflict, unknown, and bounded refusal. For A, the concrete participants are a typed mutation event, retained receipt event, and optional same-stream outbox intent in one append. The shared tenant-stream expected revision fences the fold-and-append boundary; folded resource revisions remain separate. Equal identity/digest replays the stored result; different digest conflicts. Known append conflicts can reread and replay; an indeterminate append is confirmed against its nonce and records, otherwise remains unknown. Receipts have no automatic expiry in this experiment.

The existing authorization decision is exercised with host context, but this is not an integration of the real no-Run caller flows. ASK is retained as `approval_pending`; restart/reconstruction, evidence consumption, and revalidation through the approval reducer remain untested. No dispatch, remote effect, outbox relay, failover, or all-database-failure-mode guarantee is established. The recorded outbox intent remains pending; no exactly-once external effect is claimed.

## Finite coverage and observations

The fixture set is bounded to two tenants, two actor IDs, two operation IDs, and, for each tenant, two trigger-binding IDs, two conversation IDs, and two message IDs. The test schema is disposable; resource fixtures are fixed.

| Boundary | Test observations |
|---|---|
| Canonical request and identity | Both typed tuples use the declared versioned field order with `:erlang.term_to_binary/1`; reversed map insertion order retained identical bytes and SHA-256. Changed identity, target/resource, revision, or authorized write-set fields changed the bytes/digest; extra fields, atoms, and unlisted targets were refused. This is OTP-version-local encoding evidence, not a cross-version codec guarantee. |
| Authorized writes and retained decisions | The matrix covers Store/SQL × trigger binding/conversation message × allow/deny/ask. Allow wrote only the typed fixture participants. Deny and ask retained their results without resource/outbox mutation; ask was not reported as completed. |
| Revision fences | A used one actual Store stream per tenant for both caller types and all fixtures; after one trigger and one conversation mutation, each resource revision was 1 while the shared stream head was 4. B checked the corresponding SQL resource row revision in its transaction. Stale per-resource CAS did not become success. |
| Operation identity | Equal concurrent requests returned the retained result for both callers and both schemes. Reusing an identity with changed bytes against another resource of the same caller type or against the other caller type conflicted despite each target's valid initial revision. Different operation identities contending on one resource produced a stale-CAS outcome rather than a lost update. |
| Atomicity and uncertainty | Injected rollback left no mutation or success receipt in either scheme. Lost replies were recovered from retained results; while a real PostgreSQL transaction was paused before commit, absent readback remained unknown. A known Store stream conflict reread/replayed; unresolved confirmation remained unknown. |
| Access, bounds, retention, effects | Tenant/actor mismatch did not reveal a result. Oversize/malformed requests were refused without echoing supplied values. No TTL/expiry column or automatic receipt collection was modeled. Outbox items remained pending intents; the relay and external-effect behavior were not exercised. |

The source path exercised by A is the repository's `Elzoo.DurableLog.Postgres` adapter (`pieces/integration/sql/lib/elzoo/durable_log/postgres.ex`), with Store read/replay/confirmation APIs from `pieces/state/event-log/lib/elzoo/durable_log.ex`. The existing Store implementation and its refusal of writes in a caller-owned transaction were not changed. B used the root Mix project's pinned Ecto SQL 3.14.0 and Postgrex 0.22.4 transaction dependencies. No root dependency, pin, or shared configuration changed.

### Negative controls

Each control was a temporary edit under the spike directory and was restored afterward. The expected failing assertion is the evidence; the failure is not a baseline defect.

| Temporary fault | Observed failing test/assertion |
|---|---|
| A appended the mutation without the receipt/outbox participant under the injected reply-loss path. | `participant observations are all absent or atomically retained after failure` failed with `A exposed an orphan mutation, result or outbox item` (24/25 passed). |
| B committed the typed mutation/outbox separately from the receipt/result. | The same test failed with `B exposed an orphan mutation, result or outbox item` (24/25 passed). |
| A bypassed the shared fold's retained-operation lookup while preserving stream and resource revision fences. | `concurrent equal requests return one retained result for both callers and schemes` failed its recorded-result equality assertion: the observed results were applied and stale-revision conflict (19/25 passed). No duplicate-mutation assertion was required. Cross-resource identity assertions also failed, as expected. |
| B's unique `(tenant, actor, operation_id)` receipt fence was removed while per-resource CAS remained. | The trigger-resource, conversation-resource, and both cross-caller identity-conflict tests failed: the second distinct target returned `applied` instead of identity conflict (20/25 passed). Each target's individual CAS was valid. The equal-concurrency assertion also failed. |

## Limits of the recommendation

A serializes all command appends for a tenant through one stream and replays retained history for fold/readback. This bounded experiment did not measure tenant contention, long-history replay cost, throughput, or scale; it is not evidence of production scalability. It tested one PostgreSQL 16.15 instance with pgvector 0.8.7 and finite fixed data. It cannot establish behavior under failover, replication, every connection-loss timing, or every database failure mode. A's tuple encoding is not asserted stable across OTP versions. Database reset is disposable-test cleanup, not receipt GC semantics. These limits and the missing caller/approval/relay integration remain prerequisites for any production decision.

## Commands and environment

The repository's per-worktree service instructions are in `.agents/setup` and the Verify section of `docs/development/01-workflow.md`. For a new task worktree the documented setup is `python3 scripts/worker-services.py up`; the helper provisions a worktree-scoped PostgreSQL service and its usual MinIO service. In a Mix shell, load the ignored per-worktree environment without displaying it:

```sh
set -a
source .elzoo-services/env.sh
set +a
python3 scripts/worker-services.py status
MIX_ENV=test mix run spikes/command-store-fit/run.exs
```

The private environment file supplies `ELZOO_TEST_DATABASE_URL` and is Git-ignored; this report records no URL, database name, host, port, or credential. The status command reported both worktree service roles running. The runner connected to PostgreSQL 16.15 and observed pgvector 0.8.7. MinIO is started by the normal helper, but this spike did not exercise S3.

| Check | Exit | Result |
|---|---:|---|
| `MIX_ENV=test mix run spikes/command-store-fit/run.exs` | 0 | 25 passed. |
| `mix format --check-formatted spikes/command-store-fit/run.exs spikes/command-store-fit/test/command_store_fit_test.exs` | 0 | Formatted. |
| `python3 scripts/check-roadmap.py` | 0 | Roadmap check passed; no index files were changed. |
| `git diff --check` | 0 | No whitespace errors. |

No full root gate was run. No production source, Store code, dependency pin, issue, PR, comment, or label was changed by this spike.
