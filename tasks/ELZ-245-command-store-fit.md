# ELZ-245 — Compare transactional command-store fits

- Dependencies: ELZ-033, ELZ-009, ELZ-010, ELZ-032, ELZ-024, ELZ-127
- Release: V1B
- Output: none; executable spike only
- Change class: spike-only

## Scope

Build one bounded, runnable experiment that determines whether the existing Store can uphold a no-Run command's mutation-and-result invariant, or whether a separate direct Ecto/PostgreSQL command store is required. This is a spike, not a Piece, production wrapper, or implementation of either future caller.

Use exactly two fixed caller fixtures:

1. A versioned trigger-binding mutation with an expected binding revision.
2. A conversation-message append with an expected conversation revision.

Both fixtures use tenant, actor, operation identity, a canonical declarative request, and an exact authorized write set. Model concrete typed changes and records; do not invent callbacks or arbitrary code that joins a transaction. These fixtures do not depend on the not-yet-implemented ELZ-246 or ELZ-247 APIs.

Run the spike harness under the repository's existing root Mix project. Its existing elixirc_paths load the actual Store and PostgreSQL source from the repository, and its already-pinned Mix dependencies are the runtime environment. The harness and tests directly alias and call those modules; do not make a consumer project, export or copy sources, add providers, resolve dependencies for a separate app, or reimplement Store behavior. Root test_paths exclude spikes, so the root test suite does not run this spike unless the harness is explicitly invoked.

Compare only these concrete atomic participants:

- **A — Existing Store:** use the real Store to read and append one stream. The spike's fold maps stored events to trigger-binding or conversation-message state and retained operation results; one append contains the typed mutation event, result event and any same-stream outbox item. The Store's expected stream revision is the concurrency fence, not a command-ID uniqueness row; the fold recognizes retries from the retained operation result. The test observes the actual PostgreSQL Store adapter, not a memory substitute.
- **B — Direct SQL transaction:** one transaction using the repository's already pinned Ecto/PostgreSQL versions owns the fixture trigger_bindings or conversation_messages row and matching command_receipts row. Do not call or nest the current Store from that transaction.

Prefer A only if every required invariant passes for both caller fixtures. Otherwise recommend B, and state the smallest justified production API, participants, result vocabulary, retention/fencing semantics, and the gaps to integrating the existing no-Run authorization and approval reducers. Do not implement that production API.

## Source facts to verify against the pinned checkout

- Store append takes one stream, an expected revision, records and outbox items; the PostgreSQL adapter commits those Store writes in its own transaction.
- The PostgreSQL Store refuses a write from a caller-owned transaction. Preserve that behavior; do not change the Store or weaken the refusal as part of this spike.
- Store confirmation and write classification distinguish a known commit from an indeterminate result; an absent readback is not by itself a safe retry fence.
- Authorization consumes host-supplied trusted context separately from the declarative proposal. Approval is a reducer, not a persistence guarantee.

Relevant source and existing tests are owned by ELZ-009, ELZ-010, ELZ-024, ELZ-032 and ELZ-127. Verify exact function behavior in those sources rather than treating this task's comparison as evidence of a production contract.

## Experiment and acceptance

The spike has one disposable-PostgreSQL test suite and deterministic fault/concurrency controls. It must cover all of the following for the two fixed callers:

1. **Identity and canonical bytes:** tenant, actor and operation are all bound to the command identity and canonical request bytes. Define canonical bytes as :erlang.term_to_binary/1 over one of two fixed tuples: {:command_v1, tenant, actor, operation_id, :trigger_binding, binding_id, expected_revision, bot_ref, package_digest, callable} or {:command_v1, tenant, actor, operation_id, :conversation_message, conversation_id, expected_revision, message_id, message_bytes}. Convert allowlisted maps to these tuple fields in this declared order; never serialize map iteration order. No maps or caller-provided atoms remain in the encoded tuple. Use the existing OTP encoder; add no canonicalization dependency. Equivalent maps with different key insertion order must produce identical bytes and fingerprint. Changing tenant, actor, operation, expected revision or any authorized write-set field must change the bytes. SHA-256 covers those bytes. Reusing the same identity and equal bytes returns the retained recorded result; different bytes with that identity conflict. Treat this as spike-local encoding evidence, not a cross-version production codec guarantee.
2. **Authorized write set:** the test transaction applies only the exact typed changes accepted by the configured authorization decision. A DENY is retained without domain writes. An ASK/approval-pending decision is retained without domain writes and is not reported as completed; identify, rather than conceal, the restart, evidence-consumption and revalidation work needed to integrate the existing approval reducer.
3. **Revision fence:** both caller fixtures compare the expected resource revision in the same atomic boundary as the mutation and result. A stale revision changes neither resource nor result into a false success.
4. **Atomic failure:** a transaction rollback leaves neither the mutation nor a success result. A finite injected-fault test verifies the chosen transaction rolls back both participants; a split-commit negative control exposes an orphan mutation or receipt if atomicity is broken. This is test evidence, not a proof claim.
5. **Concurrency:** concurrent identical requests produce one mutation and the same recorded result for both callers. Concurrent requests with the same identity but different canonical bytes conflict. Concurrent different operation identities obey the resource-revision CAS, with no lost update. In A, the Store expected stream revision serializes appends and the spike fold's retained operation identity recognizes a committed retry. In B, a unique command-receipt key fences duplicate identity. The per-resource CAS is not a substitute for command-identity fencing.
6. **Uncertainty:** simulate a crash or lost response after commit; the retained result can be read back without repeating the mutation. Pause a commit and make readback absent while its outcome is unresolved; the answer remains unknown. Do not infer abort from absence, retry blindly, or convert a connection failure into refusal or success.
7. **Response access and bounds:** an actor/tenant mismatch cannot read or infer another command's result. Inputs have finite bounds for canonical bytes, identity fields, values and write-set size; refusals are bounded and redact supplied data.
8. **Retention and effects:** the experiment has no automatic receipt GC or TTL that can permit an old operation to execute again. State explicitly that database reset is only disposable-test cleanup. No remote effect runs inside the transaction; describe the separate outbox/relay boundary and its duplicate/unknown limits without claiming exactly-once external effects.
9. **Negative controls:** temporarily split mutation and result into separate commits for each scheme; inject failure after the first commit and require the orphan-mutation/receipt assertion to fail. Then remove the relevant operation-identity fence in each scheme. For A, bypass the spike fold's retained-operation lookup/replay while preserving the Store and resource revision fences; retrying an equal request must return a conflict or other non-recorded outcome, so the recorded-result equality test fails. Do not require a duplicate resource mutation. For B, remove the receipt-key unique constraint and submit the same command identity against two distinct target resources within each caller fixture type, with distinct canonical digests and individually valid resource revisions; the command-identity conflict test must fail even though each resource CAS succeeds. Do not remove a nonexistent SQL uniqueness row from A. Restore only spike files and record each failing test name and assertion.

The report compares finite observations from this test suite with the upstream Ecto/PostgreSQL transaction guarantees it relies on. It states what this experiment cannot establish about production load, failover or every database failure mode. It recommends A or B from the results; it does not claim that a production Piece is ready.

## Owned paths and limits

- spikes/command-store-fit/**
- docs/research/command-store-fit.md

The spike uses only the root Mix project's already-resolved dependencies, including the exact Ecto SQL 3.14.0/Postgrex 0.22.4 pins and the existing closure for the Store source. Do not add or resolve dependencies, add providers, or change root pins, config/, the Store, authorization or approval Pieces. No GitHub client, external service or production database is allowed.

After the repository's existing environment setup, the documentation gives the exact disposable database setup and command. run.exs starts ExUnit with automatic execution disabled, requires the spike test files in deterministic order, runs ExUnit, and calls System.halt(1) when failures are reported so the command propagates failure; exceptions must also leave a nonzero process status:

~~~sh
MIX_ENV=test mix run spikes/command-store-fit/run.exs
mix format --check-formatted spikes/command-store-fit/run.exs spikes/command-store-fit/test/command_store_fit_test.exs
~~~

ELZOO_TEST_DATABASE_URL must point to a dedicated disposable PostgreSQL database; tests fail closed when it is absent. The report must give these commands, their exit codes, selected finite test results, dependency pins and any environmental limits.

## Not in scope

No production code or Piece; no arbitrary transaction callback; no nested Store call; no change to caller-transaction refusal; no receipt expiry or automatic GC; no identity-provider work; no generic exactly-once claim; no implementation of checked-command, conversation, trigger-binding or remote dispatch.
