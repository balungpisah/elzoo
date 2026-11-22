# Wave 7 remember-and-know root acceptance

## Scope

ELZ-338 ([issue #810](https://github.com/balungpisah/elzoo/issues/810)) is the mandatory
Wave 7 root consumer acceptance (Level 4 of [the Wave 7 plan](../plans/bot-platform-wave7.md)).
It adds no Piece, runtime, provider or generic framework. It calls the public interfaces of
`workflow/citation`, `integration/search-data` (its lexical query, source delete, version guard
and floor), `state/memory-record`, `integration/document-parse` and `assembly/knowledge-ingest`,
together with the ready `state/artifact`, `integration/text-chunking`, `integration/ai-embedding`,
`delivery/effect-intent`, `integration/jobs`, `integration/sql`, `workflow/context-selection`,
`workflow/prompt-assembly`, `workflow/untrusted-content`, `workflow/typed-decision`,
`assembly/run-engine`, `domain/authorization` with `workflow/approval`, `domain/principal`,
`integration/pii-redaction`, `state/retention-erasure`, `state/tenant-isolation` and
`domain/metering`. No Piece was edited, and no Piece finding was raised: every grant the
application role needed is in the owning Piece's README.

Files: [test/wave7_remember_and_know_test.exs](../../test/wave7_remember_and_know_test.exs) and
the bounded fixture
[test/support/wave7_remember_and_know_helper.exs](../../test/support/wave7_remember_and_know_helper.exs).
The harness copies ELZ-323's `grant_store!/2`, `role_facts/1` and `engine_on_app!/2` into its
own helper and loads no Wave 5 or Wave 6 test file.

## Fixture

- Two Repos on the worker's disposable PostgreSQL 16 database. The owner Repo connects as
  `elzoo_test` (a non-superuser). It creates two random schemas per test (`p` for the Piece
  tables, Oban and the intent Store; a second one for the artifact Store), besides the RunEngine
  fixture's own schema, runs the installs
  (inside Ecto migrations where the Piece asks for one; search-data's run-time
  `Migration.install/1` followed by `Migration.protect/1` in a consumer migration), grants, and
  reads the catalog and the unprotected tables. The application Repo's `after_connect` runs `SET
  ROLE` to `ELZOO_TEST_APP_ROLE` (ELZ-285). Every Piece call other than the installs runs on the
  application Repo.
- Fail, never skip: `setup_all` flunks when `ELZOO_TEST_APP_ROLE` is unset or is not `elzoo_app`,
  or when the application connection's `current_user` is not that role, equals the session role,
  inherits the owner's privileges, or is a superuser, `BYPASSRLS`, `LOGIN`, `INHERIT`,
  `CREATEROLE` or `CREATEDB` role.
- The setup test reads, as the owner, that `elzoo_app` owns no table of either test schema and
  that the relation, schema and column ACLs of both schemas grant `elzoo_app` and `PUBLIC`
  exactly these privileges, and nothing else:

  | Tables | Grant | Source |
  | --- | --- | --- |
  | `elzoo_knowledge_ingests`, `_batches`, `_attempts` | `SELECT, INSERT, UPDATE` | knowledge-ingest README |
  | `elzoo_knowledge_chunks` | `SELECT, INSERT, UPDATE, DELETE` | knowledge-ingest README |
  | `oban_jobs`; `oban_jobs_id_seq` | `SELECT, INSERT, UPDATE, DELETE`; `USAGE` | knowledge-ingest README |
  | `elzoo_search_indexes` | `SELECT` | search-data README (floor) |
  | both indexes' vector tables | `SELECT, INSERT, DELETE` | search-data README (floor) |
  | both indexes' delete-mark tables | `SELECT, INSERT, UPDATE` | search-data README (floor) |
  | `elzoo_memory_records`; `elzoo_memory_tombstones` | `SELECT, INSERT, DELETE`; `SELECT, INSERT` | memory-record README |
  | `elzoo_metering_observations`; `elzoo_metering_corrections` | `SELECT, INSERT, UPDATE`; `SELECT, INSERT` | metering README |
  | `elzoo_vault_subjects`, `_keys`, `_entries` | `SELECT, INSERT, UPDATE, DELETE` | none stated; as in ELZ-286 |
  | Store heads and outbox (both schemas) | `SELECT, INSERT, UPDATE` | ELZ-323 `grant_store!/2` |
  | Store records and checkpoints (both schemas) | `SELECT, INSERT` | ELZ-323 `grant_store!/2` |

  plus `USAGE` on each schema; `PUBLIC` holds nothing and no column grant exists. In every
  test's fixture, before its first call, `KnowledgeIngest.verify/1`, `SearchData.verify/1` of
  each index and `TenantIsolation.verify/3` over the two memory-record and the two metering
  tables pass as `elzoo_app`.
- Each RunEngine Run uses the RunEngine test fixture with `store_repo` and `grant` (ELZ-327):
  `engine_on_app!/2` asserts that every Unit, Run, host, evidence, transcript and Effect intent
  `store`/`host` binding is a `Postgres` Store on the application Repo whose `current_user` is
  `elzoo_app` with the attributes above, and that `elzoo_app` owns no table of, and holds no
  `TRUNCATE` or `DELETE` on, the engine schema.
- Oban (`Oban.Peers.Isolated`, one queue, `max_attempts` 3) runs on the application Repo with
  the knowledge-ingest runner registered. One knowledge-ingest config, embedding option
  `max_inputs: 4`, chunking `chunk_overlap: 0`, over the search-data index `wave7-knowledge`
  (`text_search: %{config: "english"}`) and the memory index `wave7-memory`, both under the floor.
  The knowledge-ingest intent Store and the host's own embedding calls share one durable
  `integration/sql` Store on the application Repo; host references are
  `host/<tenant>/<purpose>/<n>`.
- The scripted embedding provider maps each input to a unit vector of 8 topic dimensions from a
  word table in the helper, reports `input_uncached_tokens` (10 per input), counts calls, and can
  be told, for one rule, to throttle (`retry_after` 1 s), answer `authentication_failed`, time
  out, or hold the call behind a barrier. The scripted model answers each `model_call` with an
  `elzoo.ai-text.result` value; for the extraction Run it copies `[pii:...]` markers from its
  request.
- A typed decision runs inside a RunEngine Run of a harness root pattern that steps
  `Elzoo.TypedDecision`, with the extra schema entries of `runtime/recipe-test`. The model-call
  intent identity carries the Run's tenant.
- Tenants T1 and T2, period `2026-11`. In T1, Ann and Bob (`:human` end users), a reviewer
  (`:human`), the ingest service (`:service`) and each Run's `:agent` delegated from its user; in
  T2, Cara, a reviewer and the ingest service. All are `domain/principal` values checked with
  `Principal.check/2`; each ingest service's ID is the actor of its tenant's `submit/3` and the
  principal of its artifact reads. T1 documents `refunds` (HTML with a `<script>`
  holding `IGNORE ALL RULES`), `shipping` (Markdown, five chunks, so two batches) and `old-terms`
  (plain text), at source version 1; T2 `refunds` and `shipping` at version 7, holding
  `cara-only` and words that rank better for T1's queries, and `old-faq` version 7, refused
  `authentication_failed`. T2 also has Cara's memories, indexed, one of them forgotten with its
  source deleted.

## Cases

Setup. The role guard, the exact grants map above, nothing owned, every `verify` `:ok`.

1. **Ingest.** Each tenant's `refunds` and `shipping` and T1's `old-terms` reach `indexed` through
   `submit/3`. For each, the chunks returned by `query/2` equal `TextChunking.chunk/4` of
   `DocumentParse.parse/2` of its artifact bytes (version, content, offsets) and their
   `source_digest` is the status's `text_sha256`. A table read in T1's scope finds 7 rows and none
   with the `<script>` text.
   - *Restart between steps.* T1's `shipping` reaches `embedding` with batch 0 done and 1 of 2
     batches total, with its chunks staged (a T1-scope read finds them), then the Oban instance
     is stopped and a new one started. It ends `indexed`
     with 2 provider calls (one per batch), one stored version and no staged chunk.
   - *Restart during a call.* The provider holds T1's `refunds` call; the Oban instance (started
     with `lifeline: false`) is killed and its job row stays `executing`. A new instance with
     Lifeline `rescue_after: 200, interval: 100` rescues it: attempt 1 `:unknown`, the ingest
     `failed` `:embedding_unknown`. That instance is replaced by one with Lifeline's default
     (60 minutes). The harness then runs `Elzoo.Jobs.Worker.perform/1` again on the latest
     embed job row, as a second rescue of the recovery run: the status and attempts are
     unchanged. `resubmit/3` runs attempt 2 to `:completed` and the ingest to `indexed`. The
     provider saw 2 calls for that document: the held one and attempt 2.
   - *Throttle.* `old-terms`'s first call is throttled once: attempt 1
     `{:refused, :throttled}` with no usage, attempt 2 `:completed` under a new `ref`.
   - *Metering.* Paging `attempts/3` of 7 ingests and recording each attempt gives 11
     observations, each `{:ok, :applied}` (host calls record the same way). `totals/3`: T1 known
     130 from 7 `:provider_reported` observations and 2 unknown (the throttle and the killed
     call); T2 known 20 from 2 and 1 unknown (`authentication_failed`). Recording again gives 11
     `{:ok, :duplicate}` and equal totals.
   - *New version and removal.* `shipping` version 2 ends `indexed`; both queries return only
     its 5 version-2 chunks, and version 1's status stays `indexed`. `old-terms` is returned by
     both queries, then `delete_source/4` at version 1 is `{:committed, 1}` and neither query
     returns it although permitted.
   - T2's `old-faq` ends `failed` `{:embedding_refused, :authentication_failed}` with its staged
     chunk kept, and its `delete_source/4` at version 7 is `{:committed, 0}`.
2. **Retrieve.** T1 embeds the query (a `host/` call) and runs `query/2` and `query_text/2`
   with the same `k`, `allowed_sources`, `principal` and `checked_at`.
   - The vector order is refunds 0, then shipping 0–4; the lexical order is shipping 0–4, then
     refunds 0. Fused by reciprocal rank, `div(1_000_000, 60 + rank)` summed: shipping 0 32,522,
     shipping 1 32,002, refunds 31,544, shipping 2 31,498, shipping 3 31,009, shipping 4 30,535.
     `ContextSelection.select/2` selects exactly that order with those priorities.
   - A stop-word-only lexical query (`the and of`) returns `{:ok, []}`, and the selection is the
     vector order.
   - *Revocation.* Three runs. Baseline: both permitted, chunks of both selected. Revoked before
     the query: `allowed_sources` is `["refunds"]`, and both lists hold only `refunds`. Revoked
     after the query: the `refunds` candidate is dropped `access_denied` with detail `denied`,
     and the 5 `shipping` candidates are selected.
   - *Tenants.* No T1 result holds version 7, `cara-only` or a T2 `source_digest`; T2's query in
     its own scope returns them, its best vector candidate with a smaller distance and its best
     lexical candidate with a higher rank than T1's best. As `elzoo_app`, `ALTER
     TABLE ... NO FORCE ROW LEVEL SECURITY` and `DROP POLICY elzoo_tenant_floor` on the knowledge
     vector table and on `elzoo_memory_records` are refused.
   - *Table floor, after 6* (its own test, which rebuilds the group 1, 4, 5 and 6 state). Each of
     the 11 protected tables (both indexes' vector and delete-mark tables, the four
     knowledge-ingest tables, `elzoo_memory_records`, `elzoo_memory_tombstones`,
     `elzoo_metering_observations`), read without a tenant predicate, shows T2 rows in T2's scope
     and no T2 row in T1's scope. In T1's scope each also shows T1 rows, except
     `elzoo_knowledge_chunks`, where T1 has none and T2 has `old-faq`'s. An insert of a T2 row
     into each of them and into `elzoo_metering_corrections`, in T1's scope, is SQLSTATE 42501
     (row-level security).
3. **Answer with citations.** The selected chunks become citation items. `PromptAssembly.build/2`
   puts each as an `untrusted` `:content` entry before the question. A RunEngine Run of
   `Elzoo.TypedDecision` with `{:schema, Citation.schema()}` on `elzoo.citation.answer` v1 sends
   it to the scripted model; the `model_call` payload holds each item's rendered block.
   - A cited answer resolves. For each citation, the parsed text's SHA-256 is the version's
     `text_sha256` and `binary_part(parsed_text, start_byte, end_byte - start_byte)` is the quote.
     The host shows it as cited.
   - An answer citing a T2 chunk (version 7, from T2's own query) or a revoked item gives
     `{:error, :unknown_item}`; a quote not in its item gives `{:error, :quote_not_found}`. The
     host's display result is `{:not_cited, reason}` for each.
4. **Remember.** Ann's messages are tokenized with `PiiRedaction.redact/2` (`:tokenize`,
   `known: [Ann's name]`, a vault closure on `"principal:ann"`). The Run's records and proposals
   hold markers, not values, and so do the memory records and the memory index (each read
   finds an email marker and neither the email nor the name). A typed-decision Run proposes memories under a host schema of at most
   8, written under the Q6 A policy.
   - A subject fact with Ann's email marker is `{:ok, :applied}`, and the marker fetches the
     email; an agent's subject `:summary` is `{:error, :denied}`; the same proposal again is
     `{:ok, :duplicate}`.
   - A tenant fact is `{:error, :approval_required}`. The host proposal binds a write to
     `memory:<id>`, field `write`, value `{:bytes, digest}`, under a requirement of scope
     `:once`; the decision is `:ask`. `Approval.request/3` opens revision 1; an edit changes the
     digest and supersedes it (revision 2); revision 1 evidence is `:superseded` on revision 1
     and `:stale_revision` on revision 2; the edited proposal with the first digest is `{:error,
     :approval_mismatch}`; revision 2 evidence releases the second digest, and that write is
     `{:ok, :applied}`. No record holds the first version.
   - A new language preference `supersedes` the old one; one memory expires at the next Run's
     `now_ms`. Recall over Ann's subject, the tenant and `{:space, "support"}` returns the current
     memories newest first without those two. With `recency: :newest` and `max_selected_count`
     below the count, the oldest is left out, and the reviewer's space memory is dropped
     `access_denied` (Ann left the space). The selected memories are one `user` message of
     rendered blocks after the system message. The instruction-like memory appears only between
     its block's opening and closing lines, and no `system` message holds it.
5. **Recall by meaning.** After each committed write the host embeds the content (`host/`) and
   puts `memory:<id>` version 1 with `if_newer: true`. A meaning query over the current recall's
   sources finds an old fact first; with that hit at the highest priority it is selected although
   recency alone leaves it out. The address memory's index embedding times out once (`:unknown`
   usage): it is recalled but not found by meaning, and the retry (a new `host/` reference,
   `{:committed, 1}`, known usage) makes it found.
6. **Forget and erase.**
   - *Forget.* `forget/3` is `{:ok, :applied}`; `delete_source/4` of `memory:<id>` at version 1 is
     `{:committed, 1}`. Recall leaves it out, and a meaning query that permits its source and the
     email memory's finds only the email memory. T1-scope reads find no index row of it (and one
     of the email memory) and no record row of it, its tombstone, the delete mark at version 1 and another current
     memory's record. A write of that ID is `{:error, :forgotten}`; a late index put at version
     1 is `{:refused, :stale_version}`, and nothing is stored.
   - *Erase.* `erase_subject/3` with `max_batch: 2` is stopped after the first batch (two IDs, a
     cursor), then repeated from `cursor: nil` until the cursor is `nil`: it returns all 7 of
     Ann's IDs. The host deletes each source (6 `{:committed, 1}`, and `{:committed, 0}` for the
     one already forgotten) and calls `RetentionErasure.erase(vault, "principal:ann")`. After it:
     recall holds only the tenant, space and Bob's memories; a meaning query that permits all of
     Ann's sources and Bob's finds only Bob's; T1-scope reads of the records and the memory index find Bob's, and no row with
     Ann's subject, her plain-text street address or any of her markers. Every marker of Ann
     fetches `{:error, :not_found}`, the status is `{:ok, :erased}`, and Bob's markers fetch his
     name and email. Owner reads of the vault: `elzoo_vault_entries` and `elzoo_vault_keys` hold
     only `principal:bob` (2 and 1); `elzoo_vault_subjects` holds `principal:ann` `erased` and
     `principal:bob` `active`.

## Environment and checks

Toolchain: Elixir 1.20.4 / Erlang-OTP 29. The orb's disposable PostgreSQL 16.16 with pgvector
0.8.7, in a database of this worker's own. The roles are those of ELZ-285, read from
`pg_roles`: `elzoo_app` `NOSUPERUSER NOINHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOBYPASSRLS`;
`elzoo_test` `NOSUPERUSER NOBYPASSRLS LOGIN`, a member of `elzoo_app` with `SET TRUE`,
`INHERIT FALSE` and `ADMIN FALSE`. MinIO `RELEASE.2025-09-07T16-13-09Z`. Oban 2.24.2, ecto_sql
3.14.0, postgrex 0.22.4, floki 0.38.5.

```sh
ELZOO_TEST_APP_ROLE=elzoo_app mix test test/wave7_remember_and_know_test.exs --warnings-as-errors --repeat-until-failure 20
```

```text
Result: 8 passed   (21 consecutive runs, exit 0)
```

Before the `:pg` scope precondition of the harness's Oban start (copied from the durable-job
test helper, DJ11), the review saw group 1's Oban restart fail in 2 of 9 full runs: the new
notifier found the dying `Oban.Notifiers.PG` scope of the stopped instance and exited
`:noproc`.

The affected gate (`mix check --affected origin/main`), the roadmap and claims checks and `git
diff --check` are recorded with their exit codes in the pull request.

## Harness negative controls

Each was a temporary edit in the worktree, run, recorded and reverted with `git checkout`;
none was committed. Each run exited 2.

1. The application Repo without `SET ROLE` (connected as the owner). With the guard on,
   `setup_all` failed and invalidated all 8 tests: `the application connection is not the
   non-owner application role elzoo_app: %{current: "elzoo_test", login: true, inherit: true,
   inherits_owner: true, ...}`. With the guard call also removed for that run, group 2 failed at
   its first owner-only refusal: `ALTER TABLE <knowledge vector table> NO FORCE ROW LEVEL
   SECURITY` succeeded.
2. The citation check skipped (`display` takes every answer as cited with no citations): group 3
   failed at the unknown-item case, `left: {:cited, "A refund is paid within 14 days; ...", []}`,
   `right: {:not_cited, :unknown_item}`.
3. A host policy that allows every `:agent` triple: group 4 failed at `assert write(fx, "T1",
   tenant_fact) == {:error, :approval_required}` (`left: {:ok, :applied}`).
4. `delete_source/4` skipped, in two runs:
   - after `forget/3`: group 6 failed at the meaning query that permits the forgotten source and
     the email memory's, `left: ["memory:<run>/m0", "memory:<run>/m5"]`, `right:
     ["memory:<run>/m0"]`;
   - in the erasure only, with the deletes' result list faked to the expected shape so that only
     the reads can fail: group 6 failed at the meaning query that permits Ann's sources and
     Bob's, `left: ["memory:<run>/m6", "memory:<run>-later/m0", "memory:<run>/m3", ...]`,
     `right: ["memory:bob-1"]`.

These validate the harness; they do not replace the Pieces' own controls.

## Choices of this harness

- Every ingest uses `chunking: [chunk_overlap: 0]`, so the chunk count and offsets are simple to
  check by hand.
- The second rescue of the recovery run is a second `Elzoo.Jobs.Worker.perform/1` of the
  latest embed job row, not a second Lifeline pass.
- Each test has its own fixture. The table-floor case is its own test that rebuilds the state of
  groups 1, 4, 5 and 6 before its reads.

## Limits

- Scripted embedding and model providers: no claim about embedding, retrieval, ranking or answer
  quality, and no live provider. No rerank provider (Q3 A); the fusion is harness code. No live
  connector: the documents are artifact versions put by the harness.
- A citation shows that the quoted bytes are in the cited item's content, not that the answer is
  right; its offsets are in the parsed text, not the uploaded bytes.
- Pinned test identities, not an identity provider. The approval state is a volatile harness
  value; its events are not kept durably.
- Not under row security: the search-data declaration registry, the Store tables (RunEngine,
  artifact, the intent Store), Oban's job rows and the retention-erasure vault tables. The
  intent Store keeps each admitted embedding call's texts outside the floor, and no forget,
  erasure, cancel or `delete_source/4` removes them; for a memory they hold only the markers of
  the values redaction found. A value that pii-redaction does not find (listed patterns only,
  such as the street address) stays in plain text in the Run records and the intent Store and,
  until forgotten, in the memory record and the memory index; the Run records are not erased
  with a subject, and the markers in them stop opening. The host redacts once: a new redaction
  of the same text gives new markers (`put/3` mints a new reference each time), so a retry that
  redacts again writes other bytes (`:conflict` for the same memory ID). Tombstones keep opaque
  IDs, including Ann's subject ID. Dead tuples, WAL and backups keep deleted content and
  wrapped keys until PostgreSQL reclaims them. `log: false` silences only the Logger: the
  application Repo's query telemetry still receives tenants, IDs, content and vectors as
  parameters. READ COMMITTED, the Repos' default, is a consumer Need that the Pieces check and
  cannot set.
- From `assembly/knowledge-ingest`: the Lifeline Need is the host's (the short `rescue_after`
  runs only on the instance that rescues the killed instance's job and is replaced before
  `resubmit/3`); `indexed` is not live state; a stranded ingest waits for an equal `submit/3`;
  batches run one at a time. Under a volatile Memory intent Store, which this task does not use,
  an interrupted attempt whose intent is not found is `:unknown` even when it was never sent.
  Two databases that share one intent Store and one embedding binding must not also reuse the
  same schema prefix and index identity. A throttled or unknown attempt may have been charged:
  the host records it as unknown, and whether the provider charged it is not known. The Runs'
  model calls are not metered here (the Wave 6 acceptance covers Run metering). The restarts
  are an Oban instance stopped or killed in one VM, not a database restart.
- Outcomes the host maps but this task does not reach (`:completed_lost`, `:not_dispatched`,
  `credentials_unavailable`, other refusals, a Memory intent Store) and races inside one Piece
  are the owning Piece's tests.
- A meaning query covers at most 256 permitted sources, so one query covers at most 256
  memories; a tenant with more queries several sets, which this task does not exercise.
  Expired memories stay stored until forgotten.
- Finite scenarios, not proofs. No complete-Wave claim.
