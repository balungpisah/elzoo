# ELZ-109 — Align disposable PostgreSQL setup with validation requirements

- Phase: validation environment defect repair.
- Catalogue IDs: none.
- Dependencies: ELZ-101, accepted; integration follows ELZ-108 acceptance.

## Outcome

Correct the repository-owned orb setup so its owned disposable PostgreSQL service satisfies the accepted data-stream validation guard instead of deliberately disabling durability settings. The current setup sets fsync, synchronous_commit and full_page_writes off; data-stream tests require fsync and synchronous_commit on before schema writes. Separate worker gates failed this exact mismatch. Aggregate validation also exhausted the default 100 connection limit; isolated workers with capacity 300 provide the existing corrective baseline. Preserve every assertion, provider/toolchain pin and runtime Contract.

## Scope

Own only the PostgreSQL disposable-cluster setup block in .agents/setup, this publication copy, docs/work/ELZ-109.md, and coordinator-serialized own planning row/generated views. Keep existing protections against configuring a cluster containing unrelated application databases. Do not change CI, shared infrastructure, production databases, credentials, root application, .agents/resume, tests, Piece metadata, dependencies or runtime source. Do not restart another worker's services.

For the identified owned disposable cluster, converge fsync, synchronous_commit and full_page_writes to on and max_connections to 300. Detect drift across all four settings, including an existing snapshot with off/off/off, rather than checking only one setting. Restart only when applying configuration requires it. A warm rerun must leave these values unchanged without gratuitous restart. Do not silently override role/database settings that change effective test-user behavior: verification should expose mismatches. Scope is a local development-test service, not a durability proof or capacity guarantee for arbitrary workloads.

## Acceptance

1. Reproduce the current setup's incompatible settings from source and retained worker failure evidence. Preserve distinct settings and connection-capacity classifications; do not infer an unrelated test's cause solely from nearby database errors.
2. Validate the changed setup on only the worker's identified disposable service. Run bash syntax checking and actual .agents/setup twice; verify new test-user connections report on/on/on and capacity 300, relevant role/database overrides are absent or explicitly accounted for, and the second run is idempotent. Record exact commands, exit codes and restart observations without publishing private connection data.
3. Verify the unrelated-database guard remains fail-closed using safe isolated/scratch validation, without modifying a real shared cluster. Keep toolchain/provider pins and the rest of setup unchanged. Do not add one-use runtime frameworks or package-manager cache layers.
4. Integrate latest main including accepted ELZ-108 before the final runtime gate. Run pinned mix setup and full mix check once on the final candidate because the changed setup configures the validation environment; this full gate contains the affected gate, so do not immediately duplicate it with a second broad affected run. Preserve and classify any failed evidence before corrective reruns.
5. Synchronize this publication copy/hash and own planning row/views under coordinator serialization. Obtain independent actual-diff/setup/evidence review at named SHA; dispose of automated findings; merge its own PR through the sole queue with exact-head hosted evidence, verify main acceptance, clean only this task's merged refs/worktree and close its issue. ELZ-107 then merges latest main normally before its unchanged final full gate.

Grounding: shell/source checks, bounded idempotence and guard controls, observed disposable-service configuration, existing runtime tests and named PostgreSQL/platform contracts. No production durability, universal concurrency capacity or new Piece behavior is claimed. The operational batch ELZ-105/106/107 Contracts remain frozen and unchanged.
