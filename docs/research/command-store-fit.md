# ELZ-245 command-store fit experiment

## Outcome

The final PostgreSQL baseline passed 42/42 ExUnit tests against the disposable service for both candidate paths and both fixed callers. Under the task's decision rule, **prefer A, the existing PostgreSQL Store path**, for a later caller integration study because all required A cases passed. This is finite test evidence, not a proof of the Store contract or production readiness. It does not justify admitting a production Piece, API, or Store wrapper: neither fixed caller was integrated here, and no caller-specific store gap requiring a new boundary was demonstrated.

The experiment changes no production Piece. A candidate minimum boundary, if a later task establishes the need, would accept host-supplied tenant/actor/operation identity plus one of the two typed declarative requests, and offer execution and identity-scoped result lookup. It would retain the exact identity `(tenant, actor, operation_id)`, bind target kind/resource ID and the authorized write set into the request digest, and return the observed result families: applied, denied, approval-pending, identity/stale-revision conflict, unknown, and bounded refusal. For A, the concrete participants are a typed mutation event, retained receipt event, and optional same-stream outbox intent in one append. For B, the transaction writes the typed resource mutation, the same identity's receipt and encoded result, and optional outbox intent together. The shared tenant-stream expected revision fences the A fold-and-append boundary; folded resource revisions remain separate. Equal identity/digest replays the stored result; different digest conflicts. Known append conflicts can reread and replay; an indeterminate append is confirmed against its nonce and records, otherwise remains unknown. Receipts have no automatic expiry in this experiment.

The existing authorization decision is exercised with host context, but this is not an integration of the real no-Run caller flows. ASK is retained as `approval_pending`; restart/reconstruction, evidence consumption, and revalidation through the approval reducer remain untested. No dispatch, remote effect, outbox relay, failover, or all-database-failure-mode guarantee is established. The recorded outbox intent remains pending; no exactly-once external effect is claimed.

## Finite coverage and observations

The fixture set is bounded to two tenants, two actor IDs, two operation IDs, and, for each tenant, two trigger-binding IDs, two conversation IDs, and two message IDs. The test schema is disposable; resource fixtures are fixed.

| Boundary | Test observations |
|---|---|
| Canonical request and identity | Both typed tuples use the declared versioned field order with `:erlang.term_to_binary/1`; reversed map insertion order retained identical bytes and SHA-256. Changed identity, target/resource, revision, or authorized write-set fields changed the bytes/digest; extra fields, atoms, and unlisted targets were refused. Expected revisions 0 through 9,223,372,036,854,775,806 (`2^63-2`) are within the spike bound; signed BIGINT max (9,223,372,036,854,775,807) and larger values are uniformly rejected as bounded `invalid_request` before SQL or domain, receipt, or outbox writes in either scheme. This is OTP-version-local encoding evidence, not a cross-version codec guarantee. |
| Authorized writes and retained decisions | The matrix covers Store/SQL × trigger binding/conversation message × allow/deny/ask. Allow wrote only typed fixture participants. DENY and ASK were read back from retained receipts and replayed under a changed current verdict without changing the stored result or domain/outbox state; ASK remained `approval_pending`, not completed. |
| Revision fences and append semantics | A used one actual Store stream per tenant for both caller types and all fixtures; resource revisions remained separate from the shared stream revision. B checked the SQL resource row revision in its transaction. Message IDs are append-only: successive distinct IDs advance the conversation resource; reusing an ID under a new operation at the valid next revision retains `{:conflict, :message_exists}` without changing prior bytes, revision, or outbox. Resource revision is checked before message existence; a stale revision does not become success. |
| Operation identity | Deterministic concurrent same-identity/different-byte races across distinct trigger resources, distinct conversation resources, and both cross-caller directions returned exactly one apply and one identity conflict for A and B. Equal concurrent requests recovered one retained result. Sequential cross-resource/caller identity reuse conflicted despite valid individual resource revisions; different identities contending on one resource produced stale CAS rather than a lost update. |
| Atomicity and uncertainty | Injected rollback left no mutation, receipt, or outbox participant in either scheme. A and B participant observations retained all participants together. Post-commit lost responses were resolved from stored results. During a real paused PostgreSQL transaction, `resolve_b/4` queried actual receipt readback and returned `{:unknown, :unresolved}` while the row was absent; the same absent-readback result remained after caller death, with no inferred success/refusal or abort/retry. A known Store stream conflict can reread/replay; indeterminate confirmation remains unknown. |
| Access, bounds, retention, effects | Actor-only and tenant-only mismatches were tested independently against the same retained identity for both schemes and caller kinds; mismatched reads returned `:not_found` while the original context retained the result. Identity strings are limited to 1–64 valid UTF-8 bytes, other text fields to 1–256, message bytes to 1–1,024, and the canonical tuple to at most 4,096 bytes. Invalid inputs return bounded, redacted `invalid_request` without writes. No TTL/expiry column or automatic receipt collection was modeled. Outbox items remained pending intents; the relay and external-effect behavior were not exercised. |

The source path exercised by A is the repository's `Elzoo.DurableLog.Postgres` adapter (`pieces/integration/sql/lib/elzoo/durable_log/postgres.ex`), with Store read/replay/confirmation APIs from `pieces/state/event-log/lib/elzoo/durable_log.ex`. The existing Store implementation and its refusal of writes in a caller-owned transaction were not changed. B used the root Mix project's pinned Ecto SQL 3.14.0 and Postgrex 0.22.4 transaction dependencies. No root dependency, pin, or shared configuration changed.

### Negative controls

Each control was a temporary edit under the spike directory and was restored afterward. The expected failing assertion is the evidence; the failure is not a baseline defect.

| Temporary fault | Observed failing test/assertion |
|---|---|
| Split A: omit the receipt participant from A's append batch while retaining the mutation and optional outbox participant. | `participant observations are all absent or atomically retained after failure` failed with `A exposed an orphan mutation, result or outbox item`; 14/42 passed, 28 failed. Other receipt-dependent cases also failed under this intentionally broad split. |
| Split B: omit B's receipt-result update while leaving its mutation/outbox transaction active. | `failure readback observes all atomic participants for both caller kinds` failed at `assert b_receipt == {:applied, kind, 1}`; readback was `{:unknown, :readback}`. 25/42 passed, 17 failed. |
| Bypass A receipt replay while preserving stream and resource CAS fences. | `concurrent equal requests return one retained result for both callers and schemes` failed its equality assertion: observed results included applied and `{:conflict, :stale_revision}` (25/42 passed, 17 failed). `same identity conflicts across trigger-binding resources with valid CAS revisions` also returned applied instead of `{:conflict, :identity}`. |
| Remove B's unique identity receipt fence while retaining per-resource CAS. | `same identity conflicts across trigger-binding resources with valid CAS revisions` and the conversation-resource identity case returned `{:applied, ...}` instead of `{:conflict, :identity}`; both cross-caller identity tests also observed applied. 34/42 passed, 8 failed. The four deterministic database-wait race cases also failed because the removed fence no longer exposed the expected uniqueness wait; the sequential assertion failures independently confirm the missing identity conflict, not an SQL exception. |

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
| `MIX_ENV=test mix run spikes/command-store-fit/run.exs` | 0 | 42 passed. |
| `mix format --check-formatted spikes/command-store-fit/run.exs spikes/command-store-fit/test/command_store_fit_test.exs` | 0 | Formatted. |
| `python3 scripts/check-roadmap.py` | 0 | Roadmap check passed; no index files were changed. |
| `python3 scripts/check-claims.py` | 0 | No tracked claim metadata. |
| `git diff --check` | 0 | No whitespace errors. |

No full root gate was run. No production source, Store code, dependency pin, issue, PR, comment, or label was changed by this spike.
