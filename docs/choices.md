# Choices and limits

This page lists the owner choices and the deliberate limits that shape what
the Elzoo Pieces do. Each entry says what was chosen, why, what it means for
you when you use the Pieces, and how to change it. Each entry links its
source; when this page and a source differ, the source wins. Later waves add
their choices to this page.

## How a change works

- You own the source that you copied ([consuming](consuming.md)). You can
  change your copy without an Elzoo task.
- A change of a Piece in Elzoo is a published task; the coordinator sizes and
  publishes tasks ([AGENTS.md section 9](../AGENTS.md#9-coordinator)).
- The ID rule ([AGENTS.md section 4](../AGENTS.md#4-build)): Elzoo is not
  released yet, and before the first release a ready Piece is changed in place
  under its ID. From the first release, a change of a ready Piece's accepted
  inputs, outputs, state, delivery, failure guarantees or Needs gets a new
  Piece ID, and the old ID stays usable. A fix that restores the Contract
  keeps the ID. "Under the ID rule" below means this rule.
- A new dependency or a changed pin is always its own task, and it merges
  first ([AGENTS.md section 3](../AGENTS.md#3-lanes-how-many-workers-stay-safe)).

## Wave 5 owner choices (2026-11-20)

Sources: the 2026-11-20 entries in
[bot-platform.md](plans/bot-platform.md#owner-decisions-that-are-still-open)
and the postures in
[bot-platform-wave5.md](plans/bot-platform-wave5.md#wave-5-green-flag-readiness-and-locked-design-posture).

### No identity provider in core

- **Chosen.** No core Piece runs a login. `integration/token-verify` checks a
  bearer JWT or an API key offline against pinned configuration and returns a
  `domain/principal`. OIDC or passkey login is a consumer recipe
  ([ELZ-268](../tasks/ELZ-268-token-verify.md)).
- **Why.** Login ceremonies stay with your web stack, for example an `oidcc`
  recipe, which feeds verified facts into `integration/token-verify` and
  `domain/principal`; no core Piece wraps AshAuthentication
  ([wave plan](plans/bot-platform-wave5.md#all-28-candidate-handles)).
- **For you.** Your application runs the login and supplies the pinned keys.
  `integration/token-verify` has no JWKS fetch or rotation, no single-use
  `jti`, no ES256, no JWE and no OIDC ceremony.
- **To change.** Add the login to your application; no Piece changes. An
  Elzoo-owned OIDC Adapter would be its own provider-prerequisite task, only
  if a consumer needs one
  ([wave plan](plans/bot-platform-wave5.md#provider-prerequisites-and-open-notes)).
  Key fetch or another algorithm in `integration/token-verify` changes its
  accepted inputs: under the ID rule.

### DENY when a policy result is unavailable or unknown

- **Chosen.** A missing, timed-out or unresolvable policy or context check is
  `DENY`. A typed abstention from an external standing or trust provider goes
  to `ASK` (dual control through `workflow/approval`) only where a rule
  declares that routing, and it is never read as `0` or distrust; otherwise it
  is `DENY`.
- **Why.** It fails closed, matching the `unavailable_context` and default-deny
  Contract of `domain/authorization` (posture 4).
- **For you.** An outage of a policy source refuses work instead of allowing
  it. In `domain/kill-switch`, a missing, unreadable or malformed read is a
  refusal ([ELZ-281](../tasks/ELZ-281-kill-switch.md)). To get `ASK` for an
  abstention, declare it in the rule.
- **To change.** Allowing on an unknown result would change the failure
  guarantees of the Pieces that follow this choice: under the ID rule.

### Erasure by per-subject keys, logs never rewritten

- **Chosen.** Statutory erasure uses a PII vault with per-subject (or
  per-tenant) keys and crypto-shredding. Command, event and audit logs carry
  opaque IDs and are never deleted or rewritten.
- **Why.** `assembly/checked-command` recovers only from contiguous history
  (`low_water == 0`) and has no deletion or compaction API, and Carbonite
  `state/audit-log` captures mutations immutably (posture 3).
- **For you.** Keep personal data in `state/retention-erasure`, with only refs
  in logs (`integration/pii-redaction` puts them in place of the data). Erasing a subject destroys
  its key and its entries in one transaction. Dead tuples, WAL and backups keep
  wrapped keys until the database reclaims them; destroying an old KEK version
  after the backup retention period finishes the erasure, and that is your
  duty. No artifact or object tombstones and no retention schedule
  ([ELZ-279](../tasks/ELZ-279-retention-erasure.md)).
- **To change.** There is no API that deletes or rewrites log rows. Another
  vault shape goes in your copy, or in an Elzoo task under the ID rule.

### Only an agent's permissions are capped by its allowed scopes and spaces

- **Chosen.** `domain/membership` intersects an agent's permissions with its
  `allowed_scopes`, and a space outside its `allowed_spaces` gives none. For a
  human or service principal the memberships alone are its authority; its
  allowed scopes and spaces bound only what it can delegate
  ([ELZ-269](../tasks/ELZ-269-membership.md)).
- **Why.** An agent acts for its parent and never exceeds the parent's
  authority; a delegation that asks for more is refused whole
  ([ELZ-267](../tasks/ELZ-267-principal.md)). For a human or service, the
  allowed scopes and spaces bound what it delegates; the record gives no
  further reason.
- **For you.** An agent resolves its parent's memberships; a membership naming
  the agent's own ID grants nothing, and revoking the parent's membership
  removes the agent's permission. An agent's `allowed_spaces` match exactly,
  not through the tree, so an agent acts in at most 256 named spaces.
- **To change.** Capping humans or services the same way changes the output of
  `domain/membership`: under the ID rule.

### AES-256-GCM only, one layer

- **Chosen.** `integration/encryption` seals with one AES-256-GCM layer under
  the caller-held per-subject key: no ChaCha20-Poly1305 and no wrapped data
  keys ([ELZ-273](../tasks/ELZ-273-encryption.md)).
- **Why.** The owner fixed this scope at Wave 5 Level 2; the record gives no
  further reason. The Piece is a narrow Adapter over OTP `:crypto` with no
  custom primitive, and one key per subject means that destroying the key
  makes every envelope under it unreadable.
- **For you.** You hold the keys: the Piece has no key store, key generation
  policy, destruction, KMS or HSM. Random 96-bit nonces bound one key version
  to at most 2^32 seals; the Piece does not count seals, so you rotate.
- **To change.** Another cipher or wrapped data keys change its accepted
  inputs and outputs: under the ID rule.

### No fetch helper in `integration/egress-policy`

- **Chosen.** `integration/egress-policy` admits an outbound URL and returns
  its checked public addresses. It ships no HTTP client: redirects and
  response bounds are transport duties
  ([ELZ-271](../tasks/ELZ-271-egress-policy.md)).
- **Why.** A Req-based guard would start one Finch instance per distinct
  hostname and never stop it, so it would grow without bound on
  tenant-supplied hosts.
- **For you.** Your transport connects only to a returned address, with SNI
  and `Host` set to the host, treats a redirect as a new URL through
  `resolve/3`, and bounds the body. For `integration/mcp-runtime`, redirect
  refusal and the response cap are duties of ex_mcp and
  `integration/mcp-client` ([ELZ-283](../tasks/ELZ-283-mcp-runtime.md)).
- **To change.** Write the fetch in your application. A fetch helper in Elzoo
  is a task under the ID rule.

### One-use invitations in `workflow/tenant-lifecycle`

- **Chosen.** One-use invitations are durable checked commands in
  `workflow/tenant-lifecycle`, not part of `domain/membership`
  ([ELZ-284](../tasks/ELZ-284-tenant-lifecycle.md)).
- **Why.** Single use needs a durable compare-and-set, which a pure membership
  Piece cannot hold; `assembly/checked-command` has one.
- **For you.** Your host makes a random code, sends it out of band and passes
  only its SHA-256, so the code never enters command history. An accept
  returns the membership record, and your host stores it. At most 32
  invitations are pending; there is no reminder, resend or expiry sweep. An
  accept answered `ASK` and released after its expiry commits, so `ASK` is
  meant for the lifecycle operations, not for `accept`
  ([#648](https://github.com/balungpisah/elzoo/issues/648)).
- **To change.** Change the invitation rules in your copy, or in an Elzoo task
  on `workflow/tenant-lifecycle`, under the ID rule.

### The kill-switch reason prefix `lifecycle` is reserved

- **Chosen.** `domain/kill-switch` refuses a reason that starts with the bytes
  `lifecycle` (so `lifecyclex` too); only `workflow/tenant-lifecycle` uses it
  ([ELZ-281](../tasks/ELZ-281-kill-switch.md)).
- **Why.** A lifecycle transition writes the status and its own `lifecycle`
  switch in one append, and an operator's switch stays
  independent: `activate` does not release it.
- **For you.** Give your switches other reasons. A lifecycle operation that
  must engage its switch while 64 other switches are engaged is refused
  `too_many` ([#648](https://github.com/balungpisah/elzoo/issues/648)).
- **To change.** It touches both Pieces: under the ID rule.

### The fixed `elzoo_app` test role

- **Chosen.** The test databases get one fixed role `elzoo_app` (`NOLOGIN
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS`), granted to `elzoo_test` for
  `SET ROLE` only; `elzoo_test` gains no attribute
  ([ELZ-285](../tasks/ELZ-285-test-app-role.md)).
- **Why.** The hosted `elzoo_test` owns its database, so the non-owner
  row-security boundary prints `NOT EXERCISED` in every hosted run, and
  giving it `CREATEROLE` would widen the test role for every test.
- **For you.** The Wave 5 root acceptance (ELZ-286) runs as this role, so it
  shows the production posture: an application role that neither owns the
  protected tables nor bypasses row security. The `state/tenant-isolation` and
  `state/audit-log` tests still print `NOT EXERCISED`; switching them to this
  role is its own later task if wanted. For a local run, export `ELZOO_TEST_APP_ROLE=elzoo_app` beside
  `ELZOO_TEST_DATABASE_URL`.
- **To change.** It is CI and shared setup: its own task with the full gate,
  never a documents change. No Piece ID is involved.

## Limits of the Wave 5 acceptance (ELZ-286)

[ELZ-286](../tasks/ELZ-286-wave5-tenancy-acceptance.md) runs the Wave 5 Pieces
together on PostgreSQL. It shows only its finite tested composition; its
[report's Limits](research/wave5-tenancy.md#limits) are the full list, and the
[wave closure](plans/bot-platform-wave5.md#wave-5-closure-and-open-defect-handoff)
restates them. An acceptance has no Piece output, so a later acceptance task
that adds what is missing needs no Piece ID; only a change of a Piece follows
the ID rule.

### No production identity provider

- **Chosen.** The identity keys are pinned test keys: no JWT issuer and no
  production key store.
- **Why.** Core has no identity provider (above), and
  `integration/token-verify` checks against pinned keys.
- **For you.** Your issuer and key store are not exercised by Elzoo.
- **To change.** Test your own issuer in your application.

### Live Runs stop through the host's Run control

- **Chosen.** A RunEngine gate cannot see a kill switch engaged during its
  Run; live Runs stop through the host's Run control (`control/4`).
- **Why.** A RunEngine gate sees only the read taken before `start_link/1`
  ([ELZ-281](../tasks/ELZ-281-kill-switch.md)).
- **For you.** When you engage a switch, pause the live Runs yourself with
  `control/4`.
- **To change.** A gate that sees a switch during a Run would change
  `assembly/run-engine`: under the ID rule.

### No live public MCP endpoint

- **Chosen.** Only the egress refusal path is shown; a successful connect to a
  public endpoint is not.
- **Why.** `integration/egress-policy` refuses loopback and private addresses
  by design, so a test server cannot be reached through it
  ([ELZ-283](../tasks/ELZ-283-mcp-runtime.md)).
- **For you.** The `integration/mcp-client` loopback tests are the transport
  evidence; a successful public connect is not exercised in Elzoo.
- **To change.** Exercise your own public server.

### No Carbonite `state/audit-log` capture

- **Chosen.** The acceptance does not compose `state/audit-log`, so audit
  capture of its commands is not shown (owner decision, Wave 5 Level 3).
- **Why.** `state/audit-log` needs its own audit-owner role.
- **For you.** If you need audit capture of these commands, compose and test
  it yourself.
- **To change.** Add `state/audit-log` with its audit-owner role in your test.

### RunEngine Store tables without row security

- **Chosen.** The RunEngine Run, Unit, Effect intent, evidence and transcript
  stores run as the application role, as do CheckedCommand, the vault and the
  consumer tables
  ([ELZ-327](../tasks/ELZ-327-run-engine-stores-as-app-role.md); until it, the
  RunEngine stores ran on the RunEngine fixture's owner connection). The owner
  keeps the engine schema and its migration and grants the role only the
  Store-table privileges the Store needs, with no `DELETE` or `TRUNCATE`. The
  ready Store tables are not protected by `state/tenant-isolation`.
- **Why.** The acceptance uses the ready Store tables as they are.
- **For you.** In this composition, row security does not protect the Store
  tables; grant your application role only the Store-table privileges.
- **To change.** Composing the Store tables with `state/tenant-isolation` would
  be a task of its own.

## Wave 5 coordinator decisions

These are recorded on their issues
([wave closure](plans/bot-platform-wave5.md#wave-5-closure-and-open-defect-handoff)).

### A runtime MCP context is bound to its admission

- **Chosen.** For a runtime MCP server, the client context carries the intent
  key of its admission, and the Adapter refuses (`adapter_error`, nothing sent)
  a context whose key differs
  ([#646](https://github.com/balungpisah/elzoo/issues/646)).
- **Why.** Without it a session of another config could send to another
  endpoint with another credential: it failed open, against the `DENY` rule.
- **For you.** Build a runtime context with the admission-bound form, not
  `context/2`.
- **To change.** Pair contexts yourself in your copy; an unbound runtime
  context in Elzoo would change the failure guarantees of
  `integration/mcp-client`, under the ID rule.

### One tenant credential per MCP server

- **Chosen.** `integration/mcp-runtime` keeps one tenant credential per server;
  two configs for one `{tenant, server}` that differ only in credential are
  outside its Contract, and that is a host duty
  ([#647](https://github.com/balungpisah/elzoo/issues/647)).
- **Why.** RC-59 fixes one tenant credential per server (below).
- **For you.** Do not configure two credentials for one tenant's server.
- **To change.** Binding the credential into the runtime identity would be a
  new `integration/mcp-client` Contract task, under the ID rule.

## Wave 6 owner choices (2026-11-21)

Sources: the 2026-11-21 entries in
[bot-platform.md](plans/bot-platform.md#owner-decisions-that-are-still-open)
and the questions in
[bot-platform-wave6.md](plans/bot-platform-wave6.md#provider-prerequisites-and-open-questions).

### Usage, allowance and dead-letter records in Piece-owned tables (Q1 A)

- **Chosen.** `domain/metering`, `domain/quota` and `delivery/dead-letter-store`
  each install their own plain Ecto tables with `Migration.install/1`, protected
  by `state/tenant-isolation`
  ([ELZ-299](../tasks/ELZ-299-metering.md),
  [ELZ-301](../tasks/ELZ-301-dead-letter-store.md)).
- **Why.** The ready Store tables are not under row security and give no sum
  query; a period total over a Store stream would read every record.
- **For you.** Run each Piece's migration in your Repo, connect as a
  non-owner, non-bypass role, and grant the minimum the Piece's README lists.
- **To change.** Store-stream storage would change the Pieces' Needs: under the
  ID rule.

### Charge unit-tagged usage, no tiers yet (Q2 A)

- **Chosen.** A price is charged on unit-tagged usage per provider and model in
  the `integration/ai-model` unit set, a rate per line and an optional per-line
  minimum. No flat per-Run fee and no volume tiers in Wave 6.
- **Why.** It is what the providers report; tiers wait until a plan needs them.
- **For you.** Write rate cards per unit; a flat fee is a host unit added
  later (see "Deferred options").
- **To change.** Tiers and a `runs` unit are additive (below).

### Exact rates, one rounding per line with a declared mode (Q3 A)

- **Chosen.** One currency per tenant billing account, any `domain/money`
  registry currency, no exchange; rates are exact decimal strings; each rate
  card carries a required `rounding` field (one of the `domain/money` rounding
  modes), applied once per priced line per period. No platform currency.
- **Why.** Rounding once per line does not over-charge many small records, and
  a declared mode lets each consumer match its own accounting rule.
- **For you.** Choose the rounding mode per card, for example `:half_even`.
- **To change.** Rounding per record would change `domain/pricing`'s outputs:
  under the ID rule.

### Owner-authored rate cards (Q4 A)

- **Chosen.** Rate cards are authored as decimal strings; `llm_db` prices are a
  reference only.
- **Why.** `llm_db` rates may be Floats and `domain/money` takes no Float.
- **For you.** Copy a provider price into your card by hand and review it.
- **To change.** A card derived from `llm_db` needs a declared Float-to-decimal
  conversion: its own task.

### Postpaid and prepaid, shown in the acceptance (Q5 C)

- **Chosen.** Both billing models are shown in the Wave 6 root acceptance; no
  Piece is configured for either.
- **Why.** `domain/journal` supports both with the same postings; the model is a
  composition (see "Composing plan types").
- **For you.** Pick the model in your host code; nothing to configure.
- **To change.** Nothing in a Piece; change your composition.

### The UTC calendar month, no carry-over (Q6 A)

- **Chosen.** An allowance's `period_kind` is `:utc_month` in version 1;
  unused allowance does not carry over
  ([ELZ-300](../tasks/ELZ-300-entitlement.md)). Metering and quota take the
  period as an opaque host ID.
- **Why.** It is the simplest period that every consumer can compute.
- **For you.** Pass your period ID, for example `2026-11`.
- **To change.** A tenant-local month or a rolling window is additive (below).

### Deterministic scripted eval (Q7 A)

- **Chosen.** `workflow/eval` runs scripted cases through
  `runtime/recipe-test` with a closed check set
  ([ELZ-302](../tasks/ELZ-302-eval.md)).
- **Why.** Live models need credentials and are not repeatable in CI; a
  model-graded judge would make a model's word the evidence.
- **For you.** A passing report shows that a recipe handles the scripted
  results, not what a provider would return.
- **To change.** Live-model scoring is additive (below).

### No Run or model metrics in Wave 6 (Q8 A)

- **Chosen.** Counts are `domain/metering`; seeing is the Run transcript
  ([ELZ-298](../tasks/ELZ-298-run-transcript.md)), which emits no telemetry.
- **Why.** Metrics would touch four ready Pieces; no consumer asks yet.
- **For you.** Build dashboards from metering totals, or add your own events.
- **To change.** Additive (below).

### `assembly/tenant-edge` stays a deferred example (Q9 A)

- **Chosen.** The Wave 6 root acceptance composes the counted gate as harness
  code over the public interfaces.
- **Why.** No consumer asks for the gate as one interface yet.
- **For you.** Compose the gate in your host, in the acceptance's order.
- **To change.** Additive (below).

### Plan types are compositions, not Pieces

- **Chosen.** Pay-as-you-go, quota-capped and prepaid are built from blocks
  (see "Composing plan types"); no Piece or Assembly knows a plan type.
  Subscriptions wait for Wave 9 (`domain/plan`, `domain/invoice`).
- **Why.** A consumer can mix the blocks into the plan it sells.
- **For you.** Choose and compose the blocks; the guide below names them.
- **To change.** A plan-type Assembly would be its own task.

### No corner: every deferred option stays addable

- **Chosen.** Every Wave 6 Contract leaves each deferred option addable in
  place before the first release without breaking existing callers: closed
  sets that can gain members, records and results that can gain keys, digests
  that encode a later optional field only when present, no single currency and
  no single plan shape.
- **Why.** Elzoo may serve many kinds of consumer.
- **For you.** Match on the members and keys you use; do not assert that a
  result map has no other keys.
- **To change.** Each option's path is listed in "Deferred options".

## Limits of the Wave 6 acceptance (ELZ-323)

[ELZ-323](../tasks/ELZ-323-wave6-count-and-see-acceptance.md) runs the Wave 6
Pieces together on PostgreSQL, with the application connection as the
`elzoo_app` role. It shows only its finite tested composition; its
[report's Limits](research/wave6-count-and-see.md#limits) are the full list,
and the
[wave closure](plans/bot-platform-wave6.md#wave-6-closure-and-open-handoff)
restates them. An acceptance has no Piece output, so a later acceptance task
that adds what is missing needs no Piece ID; only a change of a Piece follows
the ID rule.

### Audit capture covers only the checked commands

- **Chosen.** `state/audit-log` captures the checked-command records on
  `elzoo_log_records`, not the journal, quota or metering tables.
- **Why.** Those tables are Piece-owned, and `elzoo_log_records` is the one
  table that `state/audit-log` audits.
- **For you.** A journal post, a reservation or a usage row has no Carbonite
  transaction of its own; send the admin change through a checked command
  when you need its audit record. That record is of the command, not of its
  effect: the acceptance audits `credit-3` before its account exists, and the
  journal posts it only on a later apply. Attribution is per binding, as
  `state/audit-log` states, and the acceptance binds one session per command:
  on a reused binding, a checked command alone does not give each change its
  own actor and action.
- **To change.** Auditing a Piece-owned table would change `state/audit-log`:
  under the ID rule.

### Pinned test keys and host service actors

- **Chosen.** Identities are pinned test keys, as in ELZ-286 (above). Only
  the checked-command actors are verified principals; the quota, metering and
  journal service actors are host strings.
- **Why.** The Wave 6 Pieces take opaque tenant, Run and actor IDs.
- **For you.** Your issuer, and who may act as a service actor, are yours to
  check.
- **To change.** Test your own issuer and service principals in your
  application.

### Scripted providers

- **Chosen.** Providers and eval models are scripted: no real provider usage
  report and no live MCP endpoint.
- **Why.** The acceptance counts the usage that `integration/ai-model`
  reports and does not depend on a provider account.
- **For you.** Check your provider's usage report against metering in your
  own test.
- **To change.** Exercise your own provider.

### No invoice, payment or settlement

- **Chosen.** Charges post to `domain/journal`; there is no invoice, payment
  or settlement.
- **Why.** Wave 6 counts and prices. The Wave 9 baseline plans
  `domain/payment-lifecycle` and `integration/payments`; `domain/invoice`
  stays deferred there.
- **For you.** A balanced journal does not prove external settlement.
- **To change.** A later payment or invoice task; none is admitted.

### RunEngine Store tables without row security

- **Chosen.** The RunEngine Run, Unit, evidence and transcript stores run as
  `elzoo_app`, and the ready Store tables are not under row security: the same
  arrangement as
  [RunEngine Store tables without row security](#runengine-store-tables-without-row-security)
  of Wave 5, which states the reason, what it means for you and how to change
  it. ELZ-323 merged with those stores on the RunEngine fixture's owner
  connection, a limit the coordinator accepted (review blocker B1);
  [ELZ-327](../tasks/ELZ-327-run-engine-stores-as-app-role.md) moved them to
  `elzoo_app`.
- **To change.** Composing the Store tables with `state/tenant-isolation` would
  be a task of its own.

### The counted gate is harness code

- **Chosen.** The counted gate, the admission and settlement, the metering
  split, the committed actual, the billing decision, the credit apply and the
  spend check are host code of the acceptance, not Pieces, and Run and model
  metrics are not shown
  ([Q8 A](#no-run-or-model-metrics-in-wave-6-q8-a),
  [Q9 A](#assemblytenant-edge-stays-a-deferred-example-q9-a)).
- **Why.** The owner chose to keep them out of Wave 6 (above).
- **For you.** Compose them in your host, in the acceptance's order.
- **To change.** Additive, as Q8 and Q9 say.

### The spend alert is committed, not sent

- **Chosen.** Reaching a threshold commits one outbox notice (the acceptance
  reaches exactly 80%); the acceptance does not deliver it.
- **Why.** The acceptance does not compose `integration/notification`.
- **For you.** Deliver the notice from the outbox yourself.
- **To change.** Compose `integration/notification` in your test.

### No database crash or failover

- **Chosen.** The restart is an engine restart over committed history and a
  restart of the application pool.
- **Why.** The acceptance runs on one disposable database.
- **For you.** Durability claims stay those of each Piece.
- **To change.** Test a crash or failover of your database yourself.

## Wave 6 coordinator decisions

These are set in the published task texts
([wave plan](plans/bot-platform-wave6.md#status-and-scope)).

### A reversal never takes a wallet below zero

- **Chosen.** In `domain/journal`, a reversal is an ordinary posting under the
  same balance rule: a reversal that would take an account with
  `allow_negative: false` (a wallet) below zero is refused
  `insufficient_funds`, and nothing is posted
  ([ELZ-297](../tasks/ELZ-297-journal.md)).
- **Why.** The flag forbids a negative balance without exception, so a wallet
  balance is never negative, also under a correction.
- **For you.** Before you reverse a credit to a wallet that has been spent,
  post the shortfall from another account, or open the wallet with
  `allow_negative: true` if a negative balance is acceptable.
- **To change.** A reversal that may overdraw would change the failure
  guarantees of `domain/journal`: a published task, under the ID rule.

### The durable Wave 6 Pieces need READ COMMITTED

- **Chosen.** `domain/journal`, `domain/metering` and
  `delivery/dead-letter-store` check that their transaction runs at READ
  COMMITTED and refuse `isolation` otherwise
  ([ELZ-297](../tasks/ELZ-297-journal.md),
  [ELZ-299](../tasks/ELZ-299-metering.md),
  [ELZ-301](../tasks/ELZ-301-dead-letter-store.md)).
- **Why.** Their row locks and conflict-free inserts give the stated results
  only at READ COMMITTED, and `state/tenant-isolation` cannot set the level.
- **For you.** Keep the PostgreSQL default isolation on their Repo.
- **To change.** Another level would change these Pieces' Needs: under the ID
  rule.

### Metering also counts cache writes

- **Chosen.** The unit set of `domain/metering` and `domain/entitlement` is the
  `integration/ai-model` counter set plus one cache-write unit per TTL
  ([ELZ-299](../tasks/ELZ-299-metering.md)).
- **Why.** Providers charge cache writes; an `integration/ai-model` usage holds
  them apart from the counters.
- **For you.** Record each cache write as its own observation.
- **To change.** A new unit is additive.

### An eval case holds only its own data

- **Chosen.** A `workflow/eval` dataset case holds its input, script and
  checks; the host supplies the rest of the recipe-test spec once per run
  ([ELZ-302](../tasks/ELZ-302-eval.md)).
- **Why.** The spec holds modules and functions, which JSON cannot carry, and
  one dataset can then test a changed recipe.
- **For you.** Keep your recipe package and bindings in test code.
- **To change.** Additive members of a later format version.

### Quota reads the allowance at each reservation

- **Chosen.** `domain/quota` takes the tenant's current `domain/entitlement`
  resolution with each reservation and derives each unit's amount from it: the
  sum of the allowances of that unit whose grant is not in grace, each checked
  against the grants the resolution lists; an allowance of a unit or period
  kind quota does not map is ignored. Settlements take no resolution. An
  open reservation is never freed by time; past its expiry it stays counted
  until it is settled ([ELZ-303](../tasks/ELZ-303-quota.md)).
- **Why.** A plan change, grace or revocation then applies at the next
  reservation, as a gate does, and a Run that may have started never loses its
  share.
- **For you.** Resolve the plan before each reservation. End a lost Run by
  settling `:unknown` and reconciling with `basis: :write_off`.
- **To change.** Another stacking rule for several grants is in place before
  the first release; a timed release of expired reservations would change
  `domain/quota`'s state rules: under the ID rule.

### A rate-card minimum applies to a used line, and estimates are charged

- **Chosen.** In `domain/pricing`, a line's minimum applies only when the
  period has usage on that line, also usage of amount zero or unknown; a card
  line with no usage is not charged. Every known amount is charged, whatever
  its source (`:estimated`, `:provider_reported` or `:unknown`); each charged
  line lists the sources it used ([ELZ-304](../tasks/ELZ-304-pricing.md)).
- **Why.** A tenant pays nothing for a model it never used, and a corrected
  estimate keeps its source in `domain/metering`, so excluding estimates would
  exclude corrected usage.
- **For you.** Charge a fixed fee as its own host unit later, not as a
  minimum. Refuse to post a charge whose `sources` include `:estimated` if
  your contract bills reported usage only.
- **To change.** An optional per-line field (an always-on minimum, or a source
  filter) is additive.

## Deferred options

Each option below is open by design. "Additive" means an in-place change before
the first release that leaves existing callers working; from the first release
an addition that changes a ready Piece's accepted inputs, outputs, state,
delivery, failure guarantees or Needs gets a new Piece ID, and the old ID stays
usable (the ID rule above).

| Option | Piece | How it is added | Additive |
| --- | --- | --- | --- |
| Volume tiers | `domain/pricing` ([ELZ-304](../tasks/ELZ-304-pricing.md)) | An optional `tiers` field on a rate-card line; each line stands alone, so a card without tiers prices as before | Yes |
| Tenant-local month, rolling window | `domain/entitlement`, `domain/quota`, `domain/metering` | Entitlement gains a `period_kind` member; quota keys its allowance by a tagged window (`{:period, id}`) and gains a rolling window beside it; metering already takes an opaque period ID and keeps `observed_at_ms`, so a time-range total is a new read | Yes |
| A reusable `assembly/tenant-edge` | new Assembly (RC-40) | Composes the public interfaces of verify, membership, authorization, kill-switch, entitlement, quota, Run, metering, pricing and journal; no Piece needs a private path for it | Yes (new ID) |
| Run and model metrics | `runtime/telemetry`, `integration/observability`, `assembly/run-engine`, `integration/ai-text` | A new event family emitted in place; the transcript and metering stay as they are | Yes |
| More than one active plan per tenant | `domain/entitlement` | Drop the version 1 `overlap` refusal for a declared stacking rule; a resolution already lists its grants and plans, and allowances are a list tagged by grant; `domain/quota` checks each allowance against the listed grants and sums the amounts of one unit | Yes (accepted inputs widen) |
| A host unit such as `runs` | `domain/metering`, `domain/entitlement` | A new member of the unit set | Yes |
| Live-model eval | `workflow/eval` | An optional dataset `mode` member, default scripted | Yes |

## Composing plan types

Each plan type is a composition of Pieces in your host. The planned Wave 6 root
acceptance has one named group for each
([ELZ-323](../tasks/ELZ-323-wave6-count-and-see-acceptance.md), group 7;
[wave plan, Level 3](plans/bot-platform-wave6.md#level-3--mandatory-wave-6-root-consumer-acceptance-no-piece-output)).
`domain/quota` and `domain/pricing` are published as Level 2 tasks
([ELZ-303](../tasks/ELZ-303-quota.md), [ELZ-304](../tasks/ELZ-304-pricing.md)).

- **Pay-as-you-go.** Record each Run's usage with `domain/metering`
  (unknown kept apart), price the period's totals with a `domain/pricing` card,
  and post each charge with `domain/journal` from a receivable account to
  revenue. A correction posts a linked difference. Invoicing waits for Wave 9.
- **Quota-capped.** Resolve the tenant's plan with `domain/entitlement`, reserve
  before each Run with `domain/quota` by `run_id` and give the Run's Budget the
  reserved share, settle with the Run's actual, and record usage with
  `domain/metering`. A grace resolution settles but reserves nothing.
- **Prepaid.** Open a wallet account in `domain/journal` with
  `allow_negative: false`, post top-ups to it, and post each charge (priced as
  for pay-as-you-go) from it; an overdraw is refused `insufficient_funds`.
  A top-up may also grant allowance through `domain/quota`.

You can combine them, for example a quota-capped plan whose overage is billed
pay-as-you-go.

## Wave 7 owner choices (2026-11-22)

Sources: the 2026-11-22 entries in
[bot-platform.md](plans/bot-platform.md#owner-decisions-that-are-still-open)
and the questions in
[bot-platform-wave7.md](plans/bot-platform-wave7.md#provider-prerequisites-and-open-questions).
The owner took every recommendation: option A for Q1–Q9 and option B for Q10.
The 2026-11-22 answer did not restate the standing "no corner" rule of
Wave 6 (above); the coordinator applies it to each Wave 7 Contract at
publication, and each task lists the options it keeps open.

### Plain text, Markdown and HTML, with `floki` for HTML (Q1 A)

- **Chosen.** `integration/document-parse` takes `text/plain`, `text/markdown`
  and `text/html`; HTML is parsed with `floki 0.38.5`, to be adopted as a
  direct dependency by its own provider task (ELZ-330, in publication) before
  the parser task.
- **Why.** It covers web pages and exported help articles with a maintained
  library that is already locked; PDF parsers have a long history of
  memory-safety faults, and `runtime/os-isolation` is not a sandbox.
- **For you.** Convert other formats to one of the three before you ingest
  them.
- **To change.** PDF or DOCX is a new member of the media-type set with its
  provider (a parsing service in a container first): additive.

### Lexical search with PostgreSQL full-text search, no extension (Q2 A)

- **Chosen.** `integration/search-data` gains a lexical query in place over the
  same chunk rows, with one text search configuration declared per index
  ([ELZ-331](../tasks/ELZ-331-search-data-text-delete-floor.md)). No `pg_trgm`.
- **Why.** Words and stems cover keyword search with no new extension; a
  separate Piece would copy every source and the filters.
- **For you.** Declare the configuration (for example `simple`, `english` or
  `indonesian`) when you create the index; an index without one has no lexical
  query.
- **To change.** Trigram matching is an added match member with its own
  provider task for the extension: additive.

### The host fuses vector and lexical ranks, no rerank provider (Q3 A)

- **Chosen.** The Wave 7 root acceptance fuses the two ranked lists by
  reciprocal rank in harness code into `workflow/context-selection`
  priorities. No `integration/ai-rerank`.
- **Why.** Fusion is a few lines of host code; a rerank provider is a new paid
  call per query.
- **For you.** Fuse in your host, or rank by one list only.
- **To change.** A provider-neutral rerank interface and adapter is its own
  Piece: additive.

### A memory belongs to one tagged scope (Q4 A)

- **Chosen.** A `state/memory-record` record has exactly one scope of the closed
  set `{:tenant}`, `{:space, id}`, `{:subject, id}` and `{:bot, id}`; recall
  names the scopes that the caller may read
  ([ELZ-332](../tasks/ELZ-332-memory-record.md)).
- **Why.** Bots need tenant knowledge and per-user preferences alike, and a
  closed set keeps erasure by subject defined.
- **For you.** Choose the scope when you write; check in your host that the
  reader may read each scope that it recalls.
- **To change.** A new scope member (for example `{:conversation, id}`) is
  additive.

### Forget deletes, a tombstone stays, personal values go through the vault (Q5 A)

- **Chosen.** `forget/3` deletes the record's content and keeps a tombstone of
  opaque IDs; subject erasure forgets every record of the subject. Personal
  values are written through `integration/pii-redaction` tokenize mode with the
  `state/retention-erasure` vault, so crypto-shredding covers them.
- **Why.** Memory is state, not a log, so it can be deleted; sealing every
  memory would make every recall depend on the key Need.
- **For you.** Tokenize personal values before you write a memory, and delete
  each forgotten memory's search-data source.
- **To change.** Content sealed in the vault is an optional mode: additive.

### A host policy decides who may write a memory (Q6 A)

- **Chosen.** Each write runs a host policy over the scope kind, the memory
  kind and the writer's `domain/principal` kind, with deny for an unlisted
  triple and no default policy. A model's proposal is written under the Run's
  `:agent` principal; an `:ask` needs an approval of the exact proposal.
- **Why.** Model output is a proposal (rule 3), and a tenant-wide memory changes
  every user's bot.
- **For you.** Write your policy table; obtain an approval through
  `workflow/approval` for each `:ask`.
- **To change.** A new policy member or decision is additive.

### An optional tenant floor on search-data (Q7 A)

- **Chosen.** A search-data binding that names a `state/tenant-isolation` prefix
  runs every statement under the tenant scope over protected tables; a binding
  without it is unchanged
  ([ELZ-331](../tasks/ELZ-331-search-data-text-delete-floor.md)).
- **Why.** Knowledge chunks and memory indexes hold tenant content, and the
  floor guards against a forgotten filter, as for the Wave 6 tables.
- **For you.** Protect the tables in an Ecto migration after the index is
  installed, connect as a non-owner, non-bypass role, and call `verify/1`
  before you serve.
- **To change.** A space-list floor is additive.

### Knowledge ingest gets its own Piece ID; RC-39 stays deferred (Q8 A)

- **Chosen.** `assembly/knowledge-ingest` is a new Piece ID;
  `assembly/data-pipeline` (RC-39) stays a deferred example for a later data
  workload.
- **Why.** RC-39 names a generic build-graph and dataframe family; a knowledge
  ingest is a specific Contract.
- **For you.** Nothing to configure.
- **To change.** A data-pipeline Assembly is its own task.

### A throttled embedding call gets a new, counted attempt (Q9 A)

- **Chosen.** After a throttle or overload, knowledge ingest starts a new attempt
  with a new request reference after `retry_after` or a declared backoff, up to
  a declared `max_attempts` (1..5, default 3), and records each attempt with its
  usage. An `unknown` outcome is never retried automatically.
- **Why.** A throttle is the provider's own signal to try later; recorded
  attempts keep the cost of a request that may have been processed visible.
- **For you.** Record each attempt's usage in `domain/metering`; resubmit an
  ingest that failed on an unknown outcome yourself.
- **To change.** Another retry policy is a declared option: additive.

### Recall by meaning as a composition (Q10 B)

- **Chosen.** Recall is by scope, kind and recency in `state/memory-record`; the
  Wave 7 root acceptance also embeds each written memory into a search-data
  memory index, so a query by meaning finds it. No Piece changes for it.
- **Why.** Recency alone misses an old relevant fact; the composition needs only
  the source delete that forgetting needs anyway.
- **For you.** One query covers at most 256 memory sources; query the newest 256
  or several sets.
- **To change.** Recall by meaning inside `state/memory-record` is additive.

## Wave 7 coordinator decisions

These are set in the published task texts
([wave plan](plans/bot-platform-wave7.md#status-and-scope)).

### Each knowledge-ingest step bounds itself

- **Chosen.** In `assembly/knowledge-ingest`, each Oban job keeps Oban's
  timeout `:infinity`: `Elzoo.Jobs.Worker` defines none and traps exits, so an
  Oban timeout could not stop it. Each step kills its own work at a fixed
  deadline instead: prepare 120 s, embed the embedding receive timeout plus
  30 s, index 120 s. The prepare deadline is about five times the observed
  worst parse and chunk times (7.0 s and 10.0 s for 8 MiB of nested HTML,
  14.3 s for 1 MiB of emoji), which are observations, not guarantees. Oban's
  Lifeline `rescue_after` must exceed the largest deadline plus 60 s; its
  default of 60 minutes does
  ([ELZ-334](../tasks/ELZ-334-knowledge-ingest.md)).
- **Why.** A deadline that the Piece owns holds whatever the host's Oban
  configuration; Lifeline then rescues only jobs whose node died.
- **For you.** Keep Lifeline's `rescue_after` above the stated bound. On a slow
  host a very large document can fail `{:step_failed, :prepare}`.
- **To change.** A configurable deadline per step is additive.

### Knowledge ingest embeds one batch at a time, from a pinned artifact version

- **Chosen.** One ingest has at most one live embedding call; the job of a
  completed batch enqueues the next. `submit/3` names an artifact version, not
  `:head`. A cancel while the index write runs is refused `:indexing`
  ([ELZ-334](../tasks/ELZ-334-knowledge-ingest.md)).
- **Why.** One call at a time keeps the provider's load and the attempt record
  simple; a pinned version makes every re-run read the same bytes; the index
  write cannot be taken back.
- **For you.** Remove a document that was indexed after a refused cancel with
  `delete_source/4`.
- **To change.** Parallel batches and a `:head` reference are additive.

## Request charge and payload caps of `assembly/run-engine` (RC-50)

Sources: the [piece.json](../pieces/assembly/run-engine/piece.json) contract
and limits, and the
[README](../pieces/assembly/run-engine/README.md#recorded-cycle-and-obligations).

### The shared sealed request charge

- **Chosen.** The host gives each Run a `request_cap`, a sealed integer from 1
  to 256. Every actual pattern output is charged before it is checked
  (`:none` charges nothing). Root and nested callables share one count, and
  no Attempt, pause and continue, or restart replenishes it. The first excess
  stops generation: it creates no action, verdict, outcome, join or pattern
  input, and work admitted within the cap is kept. Separately, one Unit has 64
  active and 256 lifetime actions, and a new room period does not reset the
  256 lifetime actions.
- **Why.** No restart, continue or nested callable can give a Run more
  requests than the host sealed at its start.
- **For you.** Choose `request_cap` per Run. A long-lived host such as a room
  reaches 256 lifetime actions; the recommended default is to start a new host
  identity before then and carry bounded summary state over, which waits for
  owner confirmation before Wave 8
  ([room decision](plans/bot-platform.md#a-decision-that-wave-8-waits-for-the-life-of-a-room)).
- **To change.** `request_cap` is a host option within 1 to 256. A larger cap
  or a reset changes the Contract: under the ID rule.

### Payload and record caps

- **Chosen.** Payload and outcome JSON at most 65,536 bytes and depth 32;
  ingress at most 262,144 bytes; a record or output at most 16,777,216 bytes;
  control at most 2,097,152 bytes; the state of a callable within its bound
  (65,536 bytes for the root; a nested child's `state_bytes`, 1 to 65,536);
  an active slot at most 131,072 bytes; the request map at most 4,456,448
  bytes; a checkpoint at most 33,554,432 bytes. The read-only `result/3` and
  `event_waits` read at most 65,536 rows and 536,870,912 canonical bytes.
- **Why.** Each bound is a complete encoded size, so records, control and
  checkpoints stay finite; the record and checkpoint caps match the Store
  limits ([README](../pieces/assembly/run-engine/README.md#host-construction)).
- **For you.** An oversized outcome becomes a bounded failure or loss, never a
  truncation, and an oversized checkpoint is refused without stopping the
  engine. Byte caps are not a sandbox
  ([README](../pieces/assembly/run-engine/README.md#failure-size-and-audit-limits)).
- **To change.** `request_cap`, a nested child's `state_bytes` and the read
  limits of `result/3` and `event_waits` are host options within these caps.
  Raising a cap changes the Contract: under the ID rule.

## Earlier owner decisions still in force

Source: the
[owner decisions](plans/bot-platform.md#owner-decisions-that-are-still-open)
of `bot-platform.md`, unless an entry names another.

### Plain Elixir, no Ash wrapper in core (2026-11-20)

- **Chosen.** Core Pieces are plain Elixir, Cure, Ecto and Postgrex, with the
  already locked `jose 1.11.13`; no Ash wrapper.
- **Why.** The ready Pieces of Waves 1 to 4 use no Ash at runtime, and
  [ADR-0005](adr/0005-ash-foundation-and-upstream-first.md) requires
  AshPostgres and AshOban durability proof before production adoption
  (posture 1 of the
  [Wave 5 plan](plans/bot-platform-wave5.md#wave-5-green-flag-readiness-and-locked-design-posture)).
- **For you.** Ash stays an optional choice of your application.
- **To change.** Use Ash in your application around the copied Pieces. Ash in
  a core Piece is a new dependency, so its own task merges first, and the
  change of that Piece is under the ID rule.

### Adopt a maintained library, do not write a reader (2026-11-14)

- **Chosen.** Where a maintained library does the work, a Piece adopts it as a
  dependency; a reader is not written by hand. First use: `yaml_elixir` with
  `yamerl` reads skill frontmatter (ELZ-176).
- **Why.** Elzoo uses upstream releases first and writes only the policy that
  is missing ([AGENTS.md section 4](../AGENTS.md#4-build)).
- **For you.** A Piece names its provider, and you merge the pinned dependency
  into your own project ([consuming](consuming.md)).
- **To change.** Swap the library in your copy. In Elzoo a new dependency or
  pin is its own task, and a ready Piece that changes its provider is under
  the ID rule.

### In-place change before the first release (2026-11-14)

- **Chosen.** A ready Piece that lacks something which clearly belongs to it is
  extended, refactored or cut clean in place, with the same Piece ID.
- **Why.** Elzoo is not released yet, so no second ID is made for the same job.
- **For you.** Until the first release, a ready Piece's Contract can change
  under its ID; check its `piece.json` when you copy it again.
- **To change.** It ends at the first release, when the new-ID rule of
  [How a change works](#how-a-change-works) applies.

### Version-1 action kinds, RC-68 (2026-11-12)

- **Chosen.** Version 1 has nine action kinds: model call, tool call, local
  work, ask a person, run a nested callable, open, use and close a run
  resource, and finish. Asking for an approval and filling a secret are never
  action kinds: the engine does them. Starting a child Run, waiting for an
  outside event, a part of an answer to a channel, a message to another
  member, making or removing a binding, giving an inside event and giving a
  run resource to a person enter only in later versions, with the wave that
  performs them.
- **Why.** The three resource actions stay distinct because the engine checks
  and performs them differently.
- **For you.** New versions only add members, never change or remove them, and
  records written under older versions stay readable. A person's answer names
  exactly one ask-a-person action and carries the verified person's identity.
- **To change.** A new kind comes in a new version that adds it, with its
  wave; the change of each ready Piece that takes it is under the ID rule.

### Runtime MCP servers bearer first, OAuth in Wave 9, RC-59 (2026-11-12)

- **Chosen.** `integration/mcp-multi` keeps its server bindings fixed at build
  time. A server that a tenant adds goes through one-server runtime Pieces
  under `integration/egress-policy`, with a bearer token first
  ([ELZ-282](../tasks/ELZ-282-mcp-client-runtime-endpoint.md),
  [ELZ-283](../tasks/ELZ-283-mcp-runtime.md)). OAuth with
  `integration/oauth-client` waits for Wave 9.
- **Why.** Tool lists belong to a server and a credential; the MCP tools
  specification says lists may vary by authorization.
- **For you.** One tenant credential per server, with lists keyed by tenant
  and server; per-person credentials would need separate lists. No OAuth and
  no stdio.
- **To change.** OAuth comes with Wave 9; per-person credentials need a new
  Contract, under the ID rule.

The same record holds the 2026-11-12 decisions on time limits and pause
(RC-48), run resources (RC-49), the source set of a Run (RC-65 and RC-56) and
skills (RC-67), the 2026-11-14 decision that puts the safe Lua helpers in
`runtime/lua-sandbox` as policy version 2 (RC-60), and the 2026-11-20
coordinator choices that the owner kept; they are part of those jobs'
Contracts.

## Workflow decisions

### A flaky ELZ-176 `bounded_time` test stays unchanged (2026-11-21)

- **Chosen.** The ELZ-176 test that parses a 1,048,576-byte YAML document
  within a 5-second limit stays unchanged. A failure gets the flake rule, and
  the test is revisited only if it fails again
  ([#670](https://github.com/balungpisah/elzoo/issues/670)).
- **Why.** The 5-second bound is the test's claim in ELZ-176's acceptance;
  measuring something else or raising the limit would change that
  acceptance.
- **For you.** If it fails, rerun all jobs once; a second
  failure of the same test is a real failure
  ([AGENTS.md section 5](../AGENTS.md#5-local-gate-then-pull-request)).
- **To change.** A new bound changes ELZ-176's acceptance, so it needs an
  owner decision and its own task. No Piece ID is involved.

### The `Amp-Thread-ID` commit trailer is allowed

- **Chosen.** The `Amp-Thread-ID` trailer that Amp adds to its commits is
  allowed metadata; it needs no approval, and published history is not
  rewritten to remove it
  ([ELZ-292](../tasks/ELZ-292-amp-thread-id-trailer.md)).
- **Why.** The rules allowed automatic authorship metadata but forbade session
  identifiers, so the status of the trailer was unclear.
- **For you.** Commits may carry it. Authored content, commit-message prose
  and issue or pull request prose stay roles-only, without session links.
- **To change.** It is a workflow rule in `AGENTS.md`: its own documents task.
  No Piece ID is involved.
