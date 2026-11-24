# Wave 9 tools, doors, models and money root acceptance

## Scope

ELZ-379 ([issue #919](https://github.com/balungpisah/elzoo/issues/919)) is the mandatory Wave 9
root consumer acceptance (Level 3 of [the Wave 9 plan](../plans/bot-platform-wave9.md)). It adds
no Piece, runtime, provider or generic framework. It calls the public interfaces of the Wave 9
Pieces together with the ready Pieces they compose, as the task's dependency table lists them.
The Wave 9 Pieces are `integration/oauth-client`, `integration/mcp-runtime` (with
`%{oauth: id}`), `integration/mcp-server`, `integration/webhook-out`, `delivery/model-routing`,
`integration/ai-text-compatible`, `integration/ai-text-google`, the image input of
`integration/ai-text`, `workflow/prompt-assembly` and `workflow/agent-loop`, `domain/plan`,
`domain/invoice`, `domain/payment-lifecycle`, `assembly/ledger-checkout`, and the code mode of
`workflow/lua-tool` under run-engine's `expiry_reports: :owner`. No Piece was edited. Every
grant that the application role needed is in the owning Piece's README. The Store grants follow
ELZ-323's `grant_store!/2`.

One Contract case was amended during the build, before the first release (coordinator
decision, 2026-11-24, recorded in the task file and #919). Group 3's image case had said
"Ann's `message` with `images`". Under `assembly/run-engine`, a `message` is given to the root
"only when no slot is active" ([run-engine README](../../pieces/assembly/run-engine/README.md),
lines 536–539), and an agent-loop bot holds a slot from its start to its finish. So a `message`
with images, given while the bot's tool slot was open, was committed (`{:ok, :applied}`, an
`:input` entry of kind `message`) and reached no model call. The image now arrives on the
`start` form, which takes agent-loop's same `images/2` and `arrive/3` path. The rest of the case
is unchanged. The message behaviour is
[#930](https://github.com/balungpisah/elzoo/issues/930), its own issue. The test does not
assert it.

Files: [test/wave9_tools_doors_models_money_test.exs](../../test/wave9_tools_doors_models_money_test.exs)
and the bounded fixture
[test/support/wave9_tools_doors_models_money_helper.exs](../../test/support/wave9_tools_doors_models_money_helper.exs).
The helper copies ELZ-349's `app_role!/0`, `role_facts/1`, `role_guard!/1`, `grant_store!/2`,
`engine_on_app!/2`, `store_on_app!/2`, `grants/2`, `read_as/2` and `try_as/3` shapes. It loads no
other wave's test files. It requires the run-engine, recipe-store and mcp-client test helpers
for the construction that it copies, and it changes no Piece's test helper.

## Environment

- PostgreSQL 16.16 (Debian 16.16-1.pgdg13+1), one disposable database per run through
  `ELZOO_TEST_DATABASE_URL`.
- MinIO `RELEASE.2025-09-07T16-13-09Z` as the disposable S3 test server.
- Elixir 1.20.4 and OTP 29.1.2 (the `.tool-versions` pins), on an orb with 4 vCPUs and 7 GiB of
  memory.

## Fixture

- **Two Repos.** The owner Repo connects as the session role, a non-superuser. It creates the
  schemas, runs the installs and grants, reads the catalog, and reads the tables that are not
  under row security. The application Repo's `after_connect` runs `SET ROLE` to
  `ELZOO_TEST_APP_ROLE` (ELZ-285). Every Piece call other than the installs runs on the
  application Repo. Every engine, Run-owner, Effect-intent, recipe-store and artifact Store is a
  `Postgres` Store on it.
- **Fail, never skip.** `setup_all` flunks when `ELZOO_TEST_APP_ROLE` is unset or is not
  `elzoo_app`. It also flunks when the application connection's `current_user` is not that role,
  equals the session role, is a member of the session role, or is a superuser, `BYPASSRLS`,
  `LOGIN`, `INHERIT`, `CREATEROLE` or `CREATEDB` role. The role reached: `current` `elzoo_app`,
  `super`, `bypass`, `login`, `inherit`, `createrole`, `createdb` and `member_of_owner` all
  false. The setup test shows that the guard fails for an unset variable, `elzoo_test` and
  `postgres`. `engine_on_app!/2` and `store_on_app!/2` check every Store of each engine and
  intent owner when it starts.
- **Installs.** Each install runs from a consumer Ecto migration's `up/0` as the owner, one
  Piece per disposable schema `wave9_<hex>_<key>`: oauth-client, webhook-out,
  dead-letter-store, plan, invoice, payment-lifecycle, ledger-checkout, journal and metering. The
  Effect-intent Stores are in `wave9_<hex>_intents`, each tenant's engine Stores in
  `wave9_<hex>_t1` and `_t2`, and the recipe store in `_rs`. One install of each Piece serves both
  tenants, so only the floor keeps a T1 read from T2's rows.
- **Grants.** The setup test reads, as the owner, that `elzoo_app` owns no table of any test
  schema and holds exactly these grants, with no column grant:

  | Tables | Grant | Source |
  | --- | --- | --- |
  | `elzoo_oauth_connections`, `elzoo_oauth_attempts` | `SELECT, INSERT, UPDATE` | oauth-client README |
  | `elzoo_webhook_endpoints`, `elzoo_webhook_events` | `SELECT, INSERT` | webhook-out README |
  | `elzoo_webhook_deliveries`, `elzoo_webhook_observations` | `SELECT, INSERT, UPDATE` | webhook-out README |
  | `elzoo_dead_letters` | `SELECT, INSERT, UPDATE, DELETE` | dead-letter-store README |
  | `elzoo_plan_subscriptions` | `SELECT, INSERT, UPDATE` | plan README |
  | `elzoo_invoices`, `_invoice_lines`, `_invoice_applications`, `_invoice_reversals`, `_invoice_series` | `SELECT, INSERT, UPDATE` | invoice README |
  | `elzoo_payment_payments`, `_payment_refunds`, `_payment_observations` | `SELECT, INSERT, UPDATE` | payment-lifecycle README |
  | `elzoo_payment_events` | `SELECT, INSERT` | payment-lifecycle README |
  | `elzoo_checkout_checkouts`, `elzoo_checkout_steps` | `SELECT, INSERT, UPDATE` | ledger-checkout README |
  | `elzoo_journal_operations`, `elzoo_journal_postings` | `SELECT, INSERT` | journal README |
  | `elzoo_journal_accounts` | `SELECT, INSERT, UPDATE` | journal README |
  | `elzoo_metering_corrections` | `SELECT, INSERT` | metering README |
  | `elzoo_metering_observations` | `SELECT, INSERT, UPDATE` | metering README |
  | Store heads and outbox (intents, engine and recipe-store schemas) | `SELECT, INSERT, UPDATE` | ELZ-323 `grant_store!/2` |
  | Store records and checkpoints (the same schemas) | `SELECT, INSERT` | ELZ-323 `grant_store!/2` |

  There is also `USAGE` on each schema. The Piece and intents schemas are read in the setup
  test; the engine schemas (`_t1`, `_t2`) and the recipe-store schema (`_rs`), which the engines
  create, are read in the group 3 test and hold exactly the Store grants. No table has `TRUNCATE`, and only `elzoo_dead_letters`
  has `DELETE`. The PUBLIC defaults that oauth-client's README names hold: `EXECUTE` on the
  tenant readers (`elzoo_tenant_id`, with no explicit ACL) and `TEMP` on the database for
  `verify/1`. No grant that the role needed was missing from a README, so there is no grant
  finding.
- **`verify/1` before the first call**, as `elzoo_app`: payment-lifecycle, invoice, plan,
  webhook-out (the setup test) and oauth-client (each OAuth binding when it is built) return
  `:ok`.
- **Session settings.** The application Repo has `:timeout` 30,000 ms, `queue_target` and
  `queue_interval` 1,000 ms each and `pool_size` 24. Its `after_connect` sets
  `lock_timeout = 20s` and `statement_timeout = 20s`, which meets ledger-checkout's Need.
  oauth-client has `exchange_timeout_ms` 5,000, and the Needs take at most 1,000 ms. The bound of
  one `access_token/3` caller is 14,000 ms: the pool queue wait (1,000 + 1,000), plus the
  row-lock wait for another caller's exchange (5,000 + 1,000), plus its own exchange (5,000), plus
  its Needs (1,000). Each of the three timeouts exceeds that bound, and the setup test asserts
  this and reads both settings back as `elzoo_app`. No Piece call runs inside a sandbox or
  harness transaction.
- **Table reads.** Every read of a protected table is harness SQL run as `elzoo_app` inside
  `TenantIsolation.transact/3` with the named tenant's scope. Each read that expects no row of a
  kind also reads a row that the fixture put there.
- **Fixture people and time.** Two tenants with pinned test identities. In T1: the admin Ann
  (`human:ann`), the bots' service principal, and the MCP callers P and Q (`:human`, with
  different authority sets). In T2: the admin Cara and one MCP caller D. One shared clock in
  milliseconds, starting at `1_801_000_000_000`; mcp-server's `clock` is its value divided by
  1,000.
- **Engines.** As in ELZ-349: the harness copies the run-engine fixture's construction. There is
  one Run owner per tenant under a per-tenant lock, a Unit directory, `budget_rule: :finish` and
  `result_reader` on each engine. The code-mode bot's engine adds `expiry_reports: :owner`.
  Slot deadlines after admission: model and tool 300,000 ms, `run_code` 200,000 ms and a
  lua-tool module call 20,000 ms. The Run deadline is 1,000,000 ms. Each tenant has a recipe
  store (artifacts on MinIO) with the bots' published version.
- **Harness code**, as the task names it: the scripted host (each engine Effect runs in its own
  process and reaches its engine through `input/4`), the scripted model, the MCP tool binding,
  the code-mode binding (`code_child/3` builds the lua-tool spec from the Run's declared
  functions; `local_work` runs `LuaSandbox.run/2`), the routing binding `Elzoo.Wave9.Models`,
  the recorder tenant MCP server, the local authorization server, the webhook receiver, the
  payment provider double `Elzoo.Wave9.Provider` (HMAC-signed events), and the resolver double.
  The resolver double answers `93.184.215.14`, outside the documentation ranges, and the case
  says when it answers `10.0.0.7` instead.

## Cases

Each test names its group of the task.

- **setup.** The role attributes, the guard refusals, the session settings, `verify/1`, the exact
  grant map, no `DELETE` or `TRUNCATE` but the listed one, and the PUBLIC defaults.
- **group 1, OAuth.** `begin_authorization/3` for provider `auth`. The authorization server
  reads `state` and `code_challenge` from the URL and issues a code. `complete_authorization/3`
  returns `grant: :authorization_code, state: :active`, and the token request carried a verifier
  whose S256 hash is the challenge. The same `state` again is `:invalid_state` with no second
  exchange. The tokens are b64tokens of at least 24 bytes. `McpRuntime.configure/1` with
  `credential: %{oauth: "conn-1"}` then `admit/1` gives a client config with one OAuth Need
  call. Sessions of the ready client in `:loopback` mode to the recorder server are listed with
  `McpClient.list_tools/1`, and an agent-loop bot calls `echo` through the MCP tool binding.
  Every request carried the current token. Past the freshness edge, two more bot Runs, each with
  its own session of the admitted config, call the tool at once. The token endpoint holds the
  first refresh until the second caller waits on the connection row. As `elzoo_app`, the harness
  sees in `pg_locks` a session of this database that holds a lock on `elzoo_oauth_connections`
  and waits on a row or a transaction. Exactly one refresh reaches the token endpoint, both calls complete, and both
  `tools/call` requests carried the new token. A T1-scope read of the connection row while it holds both tokens finds none of their
  bytes in any column, and no MCP result holds one. Then `invalid_grant`: the triggering call is
  `{:refused, :credentials_unavailable}` with no `tools/call`, the token endpoint saw that one
  refresh, `get/3` is `:reauthorization_required`, a later call sends nothing to either server,
  and a new `admit/1` is `{:error, :credentials_unavailable}`.
- **group 1, code mode.** A bot's snapshot holds `run_code` on a nested source. The binding
  builds the lua-tool spec: `id` `"code-"` plus 32 hex characters of the action ID's SHA-256 (no
  `":"`), `bindings` from `LuaBinding.resolve/2` of the declared functions' manifests only,
  `max_calls` 4, and `limits` with `wall_ms` 1,000 and `steps` 20,000. Two declared calls (`add`,
  `mul`) are two `tool_call` actions of `elzoo.lua-tool.module-call`, each settled `completed`,
  and the finish is `completed` with `{"total": 4}`. An undeclared `wipe` finishes `failed`,
  `sandbox_refused`, `unlisted_name`, with no module call. A loop without end finishes `steps`. A
  source that begins with `\eLua` finishes `lua_error`. Under `expiry_reports: :owner`, a held
  module call's slot (deadline 20,000 ms) is settled `expired` by a harness `wake` after the clock
  moves. The report reaches lua-tool, which finishes `failed`, `module_call_not_completed`,
  naming `<id>:r:1`, and the `run_code` slot completes before its own deadline. No `wall_time`
  flake occurred.
- **group 2, the mounted server.** `Plug.Cowboy` on `127.0.0.1` at an ephemeral port, `/mcp`
  forwarded to `Elzoo.McpServer.Plug`, idle timeout 60,000 ms, `call_timeout_ms` 3,000, and a JWT
  verifier. P and Q list exactly their allowed bots in name byte order (`slow, summarize` and
  `summarize, translate`), and the lists differ.
  `badroot` (array root) is listed for neither, and D lists only T2's `invoice`. P's call pins
  the bot's version, starts one Run with principal `human:P`, and returns `{"payload", "run_id"}`
  from `RunEngine.result/3`. A Run held past the bound returns the tool error
  `{"run_id", "state": "running"}` and completes after release. Raw `tools/call` arguments that
  fail the schema give the tool error `invalid_arguments` and no Run. An expired token gives
  HTTP 401 `{"error":"unauthorized"}` with no start. D's valid token lists only T2's bots, its
  raw call of a T1 bot is `-32602` with no start, and its request on P's legacy session is HTTP
  404 `-32600`. Neither the 401 nor the 404 calls the `authority` or `bots` Need, so no handler
  ran. `subscriptions/listen` is HTTP 200 `-32601` with no stream. A session connected
  with a valid 30 s token, called after `exp + leeway`, gets `{:refused,
  :authentication_failed}`. This pair has no Piece test, and the result is what the task states.
- **group 2, events out.** E1 (`dedup: true`) and E2 (`dedup: false`) give `{:ok, %{deliveries:
  2}}`. Every POST passes the Standard Webhooks check with its `whsec_` secret and fails with
  another. E1 answers 503 then 200: two claims `backoff(retry, 1)` apart, one `webhook-id`,
  `:delivered` `try: 2`. E2 answers 503: one POST, `:dead_lettered` `filed`, one dead letter
  `dispatched_unresolved`. For E3 the resolver answers private at send: no POST, the same try is
  due again after each `delay/4` with `rearm`, and at `max_attempts` 3 it is dead-lettered
  `retries_exhausted`. `register/3` while the resolver answers private is `{:error, {:egress,
  :non_public_address}}` with no row.
- **group 3, models.** Route `chat` v1 with `compat` (rank 1, model table `[:tools]`), `gemini`
  (rank 2, `gemini-3.8-flash`) and `compat-eu` (rank 3, `[:tools, :image_input]`, region `eu`,
  which T1's policy refuses). Each candidate has its own Binding module (accounts `acct-compat`,
  `acct-gemini` and `acct-compat-eu`), ai-text Config, key and Needs. The bot spec is
  `model_attempts: 2`, `move_on: ["throttled", "overloaded"]` and `image_input: true`.
  - Throttle: compat's 429 with `Retry-After: 30` gives `{:next, %{ref: "compat", not_before_ms:
    now + 30_000}}`. `r1:m:1` settles `failed` with `throttled`, 30 and `"compat"`, and one
    observation of amount `:unknown` is recorded. `r1:m:1:2` is asked under
    `elzoo.agent-loop.model-attempt` with those attempts. `select/3` excludes compat `:tried`,
    and gemini completes with its counters recorded. `Metering.totals/3`: `output_tokens`
    `:unknown` `known: 0, unknown_count: 1`, and `:provider_reported` `known: 87` (gemini maps
    `candidatesTokenCount + thoughtsTokenCount`).
  - Cool-down: at `t0 + 29_999` compat is `:cooling_down`, and at `t0 + 30_000` it is eligible
    and picked first.
  - Data policy: compat-eu is excluded `{:data_policy, :region}` in all 7 selects. Its credential
    and artifact Needs are never called, its stub gets no request, and no intent identity names
    `acct-compat-eu`.
  - Credentials: every compat request has only `authorization: Bearer <compat key>`, and every
    gemini request only `x-goog-api-key: <gemini key>`. No request holds another candidate's
    key. An owner read of every row of the intent, T1 and T2 Store tables finds neither key, and
    it does find `acct-gemini`, which shows that the read covers the intents.
  - Image (start form, amended): Ann's start with one PNG artifact committed on MinIO gives
    `r2i:m:1`, whose newest user message is `[text, image]`. compat is excluded `:capability`
    (checked before its cool-down). gemini's request holds one `inline_data` whose decoded data
    is the artifact's bytes. compat's credential and artifact Needs are not called.
  - Unknown: at `t0 + 30_000` compat times out, which gives `{:unknown, :timeout}` and `{:stop,
    :unknown_outcome}`. `r4:m:1` settles `unknown`, the loop's finish is `stopped`,
    `model_call_not_completed`, there is exactly one intent, and gemini gets no request. The
    intent count is read from the intents Store as the owner: of every candidate and Attempt
    1..4 of `r4:m:1` and `r4:m:1:2`, only compat's first intent stream exists. Its key is
    derived from ai-text's identity, not from the harness log.
  - Local rate: with `tenant_rate` capacity 1 per 5,000 ms, `r5:m:2`'s admission is
    `{:rate_limited, 5_000}`, which gives `{:retry_same, 5_000}` (backoff 100 below W, `jitter:
    :none`). The binding waits until the test moves the clock 5,000 ms, and no request is sent
    meanwhile. Then there is one intent to compat with `same_ref_attempts: 2`. The refused send
    made no intent and no observation. The intents Store holds compat's intent number 2 of
    `r5:m:2` and no other.
  - The compatible stub parses each Chat Completions body of req_llm's LMStudio encoding. Each
    body validates against the documented request schema (ai-text-compatible's own test
    fixture, read only) and names `compat-chat`, a non-empty `messages` list and the bot's
    `host_lookup` function tool. No body has a `stop` key.
- **group 4, money.**
  - Renewal: `create/3` with trial end `1_801_353_600_000` gives `:trialing` period 0, no fee
    line and grant `sub-1/0`. `renew/3` 1 ms before is `:not_due`. At the trial end it gives
    `:active` period 1 ending `1_803_772_800_000`, the fee line and `sub-1/1`. The repeat is
    `duplicate: true` and writes nothing. The harness stores the returned grants in its own
    state, and `resolve/3` over the stored grants is entitled in period 1.
  - Invoice: invoice 1 of the series first, then number 2 with `invoice/inv-2/issue` from the fee
    line and a complete pricing charge. The journal post is `:applied`, then `:duplicate`, then
    `mark_posted/3` once. A period with an unknown observation is `incomplete`, and `add_line/3`
    refuses it `:incomplete_charge`.
  - Checkout pays it: it waits `:charge_intent`, the payment is `:pending`, and the charge
    answers `pending`. The verified success event is `applied: true`, `:succeeded`, the same
    bytes are `duplicate: true`, a later pending event is `applied: false`, and a forged one is
    `:verification_failed` with nothing changed. Then it completes: the invoice is `:paid`, the
    settle is posted once, the receivable is 0, and a further `resume/3` calls nothing.
  - Compensation: the settle names an unopened account. One `resume/3` gives `:compensating`
    waiting `:refund_intent` with the invoice step compensated (the invoice `:open`, paid 0) and
    the charge step succeeded. Then `:compensated`, one reversal `checkout/comp/c/invoice`, one
    `comp/charge` refund and one provider refund call. A declined refund gives `:needs_operator`
    and `compensation_failed`, listed by `list_running/3`.
  - Refunds: 60 is admitted and 50 is `:over_refund`. An unknown charge keeps waiting
    `:charge_intent` until a poll answers `succeeded`. Drift gives `:compensated`
    `:approval_mismatch` with the payment `:created` and no provider call. A top-up posts
    `checkout/<id>/wallet`, and a later post over the balance is `:insufficient_funds`.
- **group 5, isolation.** Each tenant runs one flow of each part: an authorization-code
  connection, a delivered and a dead-lettered webhook, a subscription, and a compensated invoice
  checkout with one applied event. On all 18 new tables, as `elzoo_app`:
  - `ALTER TABLE … NO FORCE ROW LEVEL SECURITY` and `DROP POLICY elzoo_tenant_floor` are refused.
  - `SELECT DISTINCT tenant` gives `["T2"]` in T2's scope and `["T1"]` in T1's.
  - A copy of a T1 row naming T2 is refused in T1's scope with the row-security 42501.
  - On the 15 tables with `UPDATE`, an update of T2's rows matches 0 in T1's scope and at least 1
    in T2's own scope (rolled back).
  - On `elzoo_webhook_endpoints`, `elzoo_webhook_events` and `elzoo_payment_events`, the update
    is 42501 by privilege, not by row security.

Engine facts recorded on the way, not cases:

- A root finish with no completed source action is refused `completion_evidence` by the engine
  (`run_engine.ex`, `dispatch/3` of a root `finish`). So a Run whose loop finishes `stopped`
  keeps no completion. The test asserts the loop's own finish payload and the finish's
  `refused` settlement.
- A `message` given while a slot is active is the subject of #930 (above).
- `RunEngine.result/3` of a completed Run rechecks the owner's revision. `Run.status/2` reports
  that as the revision of the owner's whole stream, so another Run of the same shared owner that
  commits during the read makes it `{:error, :completion_mismatch}`. This happened once, in group
  1, when two bot Runs completed at about the same time. mcp-server would answer such a read as
  `state: unknown`. This is [#931](https://github.com/balungpisah/elzoo/issues/931), its own
  issue. The harness now reads those two results only after both Runs are completed in the
  owner, and no assertion changed.

## Negative controls

Each control was one temporary edit in the worktree, run, recorded and reverted with
`git checkout`. None was committed. The final passing run came after all five were restored.

1. The application Repo without `SET ROLE`. With the guard on, `setup_all` fails: "the
   application connection is not the non-owner application role elzoo_app" (`current` and
   `session` are both the session role, with `login` and `member_of_owner` true), and every test
   is invalid. With the guard off for that run only (the role guard and the per-Store and
   per-engine checks made no-ops), group 5 fails at its first owner-only refusal:
   `ALTER TABLE … NO FORCE ROW LEVEL SECURITY` on `elzoo_oauth_connections` succeeds, because
   the connection is the owner.
2. The code-mode bindings resolved from every manifest instead of the declared functions. Group
   1's undeclared-function case fails: the program's `wipe` runs as a module call, and the finish
   is `completed` with `{"n": 0}` instead of `sandbox_refused`, `unlisted_name`.
3. The resolver double kept answering the public address at send time. Group 2's private-address
   case fails: E3's delivery is `:delivered` at `try: 1` (the receiver got the POST) instead of
   `:pending`.
4. The routing binding with `{:stop, :unknown_outcome}` treated as `{:next, nil}`, giving a
   `failed` outcome with reason `overloaded` and the candidate. Group 3's unknown case fails:
   `r4:m:1` settles `failed`, not `unknown`, and the intents of `r4` are `[{"r4:m:1", "compat"},
   {"r4:m:1:2", "gemini"}]`, a second intent to gemini.
5. A temporary edit of `assembly/ledger-checkout`'s `backward/3` from `Enum.max_by` to
   `Enum.min_by` on the step position (reverted, never committed). Group 4's order snapshot
   fails: after the one `resume/3`, the invoice step is still `:succeeded` (position 2), not
   `:compensated`.

## Commands and times

    mix test test/wave9_tools_doors_models_money_test.exs --slowest 12
    mix check --affected origin/main
    git diff --check
    python3 scripts/check-roadmap.py --live

One local run of the module (`mix test test/wave9_tools_doors_models_money_test.exs --slowest
11`, exit 0) on this orb: 11 tests, 21.3 s in total, of which these are the tests (ms):

| Test | ms |
| --- | --- |
| setup | 306.1 |
| group 1, OAuth | 1,532.0 |
| group 1, code mode | 3,229.5 |
| group 2, the mounted server | 3,730.9 |
| group 2, events out | 353.6 |
| group 3, models | 4,185.2 |
| group 4, renewal | 200.4 |
| group 4, invoice and checkout | 322.7 |
| group 4, compensation | 414.5 |
| group 4, refunds, unknown, drift, top-up | 395.4 |
| group 5, isolation | 634.4 |

Fifteen consecutive whole-module runs (`--repeat-until-failure 14`) passed in 13.8 to 14.9 s
each, after the first-review repairs. Two failures came before those repairs. One whole-module
run failed once in group 1, before the read-order change of #931 (below). The reviewer saw one
failure in 14 runs in the code-mode test's teardown: `DROP SCHEMA … CASCADE` deadlocked
(40P01) with an Effect-intent owner of the Run owner. That owner was linked to the Run owner
and survived its `:normal` stop. When its held task was stopped, it wrote a `:Lost` event into
the schema being dropped. The teardown now stops each Run owner with `:shutdown` and waits for
it and its linked owners to exit before it stops the tasks and drops the schemas.

The root suite's per-test limit is 120,000 ms (`test/test_helper.exs`), and no test sets a
`@tag timeout:`.

## Limits

The task's "Limits to state" are the full list, including the amended line for #930. This
report adds only the two engine facts above: a loop that finishes `stopped` leaves its Run with
no completion, and under a shared Run owner `result/3` of a completed Run can be
`completion_mismatch` while another Run commits (#931). In short: models and the payment provider are scripted, so there is no claim about
answer quality, provider behaviour or settlement. The authorization server, the webhook
receiver and the compatible endpoints are `Req.Test` plugs behind a resolver double, and the
Gemini endpoint is a plug through its test option, all with no socket. Elzoo's MCP server and
the tenant MCP server are real loopback sockets, and the tenant session is the ready client's
`:loopback` evidence mode. Identities are pinned test identities. The Lua sandbox is not OS
isolation. A retried MCP call starts a second Run. The harness attaches no Req or Finch
telemetry handler. Every engine port schema is built from `{}`, which accepts any payload; the
cases assert the payloads that matter (the Attempt payload among them) directly. The RunEngine, Effect-intent, recipe-store and artifact Stores are not under
row security. READ COMMITTED is a consumer Need. Races and failure paths inside one Piece are
that Piece's tests. These are finite scenarios, not proofs, and no complete-Wave claim is made.
