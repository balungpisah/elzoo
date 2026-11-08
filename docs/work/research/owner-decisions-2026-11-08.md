# Owner decisions on the ecosystem ranking — 2026-11-08

Recorded by the coordinator session from the owner's answers on 2026-11-08 (WIB). The owner
accepted the coordinator's recommended defaults: "i follow ur recommendations on the decisions."
Earlier the same day the owner set the admission rule quoted on issues #44, #45, #46 and #48:
every planned and deferred catalogue entry is open for development; "demand-led" admission
applies only to gaps outside the catalogue found during consumer work; prefer a maintained
Elixir library ("take the codes or the ideas") and build only what does not exist.

## Answers to the six open questions in ecosystem-ranking-2026-11-08.md

1. Next admitted batch: Telemetry (R03), object store (R18), notification (R20), audit log
   (R15), in that order. Then the first ReqLLM model boundary (R16), then the MCP client,
   text chunking and pgvector slices (R37, R39).
2. Storage boundary: option A, an S3-only caller behind an Adapter, req_s3 first; ExAws S3
   only if multipart or large operations require it. Jido VFS is not adopted now.
3. AI and protocol provider: the first model Adapter exercises Anthropic over the hosted API.
   The first tool boundary is an MCP client (ex_mcp). No agent-runner CLI is selected yet.
4. Identity and notifications: no identity provider is selected; identity, principal,
   auth-policy and membership wait for a product decision. The first email provider is a
   plain SMTP provider through Swoosh.
5. Retained records: the first audited mutation is the effect-intent decision record from
   ELZ-023 (pieces/delivery/effect-intent); its PostgreSQL store owns the transaction.
   Artifact integrity, access and expiry are specified separately when state/artifact is admitted.
6. Specialized demand: replication, CRDT, FHIR, media and the UI host have no current caller
   and stay conditional comparisons.

## Limits

These are admission decisions, not implementation authorization for any single task. Each task
still needs its published issue, Contract review, evidence and merge under AGENTS.md. The
license decision for "Apache-2.0 OR MPL-2.0" packages (Apache option, full closure recorded) was
taken by the coordinator session on 2026-11-08 and is recorded in the ranking document.
