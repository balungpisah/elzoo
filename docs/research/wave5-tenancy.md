# Wave 5 tenancy root acceptance

## Scope

ELZ-286 ([issue #650](https://github.com/balungpisah/elzoo/issues/650)) is the mandatory
Wave 5 root consumer acceptance. It adds no Piece, runtime, provider or generic framework. It
calls the public interfaces of `domain/principal`, `integration/token-verify`,
`domain/membership`, `state/tenant-isolation`, `integration/egress-policy`,
`domain/provider-data-policy`, `integration/pii-redaction`, `state/retention-erasure`,
`domain/kill-switch`, `integration/mcp-runtime` and `workflow/tenant-lifecycle`, together with
the ready `assembly/checked-command`, `assembly/run-engine` and the PostgreSQL Store. No Piece
was edited.

Files: [test/wave5_tenancy_test.exs](../../test/wave5_tenancy_test.exs) and the bounded fixture
[test/support/wave5_tenancy_helper.exs](../../test/support/wave5_tenancy_helper.exs).

## Fixture

- Two Repos on the worker's disposable PostgreSQL 16 database. The owner Repo (the test role
  `elzoo_test`) creates a random schema, runs the migrations, grants and reads ground truth.
  The application Repo's `after_connect` runs `SET ROLE` to `ELZOO_TEST_APP_ROLE` (ELZ-285).
- Fail, never skip: `setup_all` flunks when `ELZOO_TEST_APP_ROLE` is unset, or when the
  application connection's `current_user` is not that role, equals the session (owner) role,
  is a superuser or `BYPASSRLS` role, or holds the owner's privileges through inheritance
  (`pg_has_role(current_user, session_user, 'USAGE')`).
- In the schema: the CheckedCommand Store tables, the `state/retention-erasure` vault tables and
  four consumer tables protected with `state/tenant-isolation`: `documents` (flat), `notes`
  (spaced), `memberships` (flat; the host's membership rows) and `ledger` (spaced, append-only:
  each row references a membership row by foreign key). The application role gets only
  `USAGE` on the schema and the table privileges it needs; on `ledger` only `SELECT, INSERT`.
- Tenants: T1 and T2 flat (one space each); T3 with root R, child A (`block_inheritance:
  true`), grandchild B under A and sibling C under R, with `non_inheriting: ["money."]`.
- Principals come from `integration/token-verify` API keys generated in the test (HMAC-SHA-256
  digests of random secrets, a digest key as an `Elzoo.Secrets.Credential`). Permissions and
  space lists come from `Elzoo.Membership` over the membership rows the host reads back as the
  application role.
- RunEngine Runs use the RunEngine test fixture with the Run's tenant set to the test tenant.
  The fixture's owner Repo creates its own schema and runs its migration; the owner grants the
  application role only the Store-table privileges there (no `DELETE`, no `TRUNCATE`), and the
  Run, Unit, Effect intent, host and evidence stores run on the application connection
  (ELZ-327). Each Run asserts that every one of its Store bindings connects as the application
  role and that the role owns no table of, and holds no `TRUNCATE` or `DELETE` on, the engine
  schema. CheckedCommand commands use the PostgreSQL Store on the application connection.

## Cases

1. **Database floor as the application role.** `verify/3` is `:ok` for all four tables.
   Under T1 a read sees only T1 rows, an update and a delete touch only T1 rows (ground truth
   by the owner with `FORCE` dropped in a rolled-back transaction). An insert of a T2 row and
   an update moving rows to T2 (flat and spaced) give SQLSTATE 42501 and change nothing.
   `NO FORCE`, `DISABLE ROW LEVEL SECURITY` and `DROP POLICY` give 42501 on every table;
   `SET LOCAL row_security = off` and a read give 42501 ("row-level security"). Afterwards
   `verify/3` is still `:ok`, and outside the helper every table shows no row while ground
   truth holds rows. The role facts are asserted last.
2. **Identity to rows.** Each API key verifies to its principal; a wrong secret for a known key
   ID is `:invalid_signature`. Over the stored memberships, `Membership.spaces/4` gives the list
   that `transact/3` uses: a T3 reader at R sees R and C (`note-r`, `note-c`), not A or B; an
   editor at A sees A and B. An agent delegated from the A member with `docs.read` and space B
   sees only B and nothing for `docs.write`; asking for `money.pay` is `:escalation`. The T1
   principal resolves only `t1-home`, also over facts holding T3's memberships, and every
   space list resolved for any principal and permission, plus `[r, a, b, c]`, shows T1 no T3
   row.
3. **Soft revocation.** Setting `revoked_at` on the R reader's row (kept) empties its space list
   and permissions at the next call (at `now - 1` it still holds). Its ledger row and foreign
   key stay; an auditor at R reads it through the `ledger.read` space list; the application
   role cannot update or delete a ledger row (42501), and ground truth is unchanged.
4. **Non-inheriting scope.** A treasurer at R holds `money.pay` at R only; its `money.pay`
   space list is `[r]` while `docs.read` is `[c, r]`. The host check refuses a payment at C;
   with the host check bypassed, the `[r]` space list still refuses a ledger row at C (42501).
   A treasurer membership at C grants it there and the payment commits.
5. **Provider data policy on live Runs.** A RunEngine gate maps
   `ProviderDataPolicy.decide/2` to `:allow` or `{:deny, code}`. On a live Run with two model
   actions tagged `:pii`, the one for a provider the T1 policy does not admit is refused with
   `{:deny, "data_provider"}`; the admitted one passes the gate and its Effect is dispatched.
   On a second Run, a malformed policy (`{:error, :policy}`) denies with
   `data_policy_unavailable`; that Run's only action is that refused slot, so it has no Effect
   to dispatch.
6. **Runtime MCP egress.** `McpRuntime.admit/1` for an allowlisted tenant URL whose resolver
   answers `10.0.0.5`, `169.254.169.254`, `127.0.0.1` or `{93.184.215.14, 10.0.0.5}` is
   `{:error, {:egress, :non_public_address}}`. The resolver ran once each, the credential Need
   (`secrets`) ran zero times, and the count of `ExMCP.Client` processes is unchanged. Control:
   a public answer reaches the credential Need (count 1), which raises, giving
   `{:error, :credentials_unavailable}`, still with no client. `admit/1` starts no client on any
   path by its Contract, so the unchanged client count is a guard against a later change, not
   a detected absence; no case here shows the count rising, and a client that started and
   exited between the two samples would leave it unchanged. The decisive evidence is the
   credential Need count of zero.
7. **Kill switch on live work.** T1 and T2 are activated through lifecycle commands; a live
   RunEngine Run of each dispatches its first local work. A T1 tenant switch commits through
   CheckedCommand on the PostgreSQL Store (the kill-switch descriptor's gate allows; it never
   calls `check/2`).
   - The host's admission takes the read before `start_link/1`, calls `check/2` and gets
     `tenant_suspended`; the start counter and the engine Registry count are unchanged.
   - The host pauses the live T1 Run with `control/4`. Its gate, over the read taken before its
     start, still answers `:allow` for a probe frame. A wake to the paused Run dispatches no
     work (500 ms), the phase stays `paused` and the request count stays 1.
   - A T1 notes command, its handle built over a fresh read of the control resource just before
     `execute/3`, is `{:denied, {:gate, "tenant_suspended"}}`.
   - T2's Run and commands proceed throughout (`work-1`, `work-2`, request count 3; notes
     commands commit).
   - A gate over `resource/3` on a Store binding whose Repo was never started
     (`{:unknown, :storage}`) denies `kill_switch_unavailable`.
   - The release commits while the switch is engaged and before the T1 pause deadline (clock
     2,000 ms < 50,000 ms). The verified-person continue control makes the Run `active`; its next
     wake dispatches `work-1`. A new T1 Run starts and dispatches. The refused command commits
     under a new `operation_id`; the old ID replays the retained denial through `execute/3` and
     `result/3`; resubmitting the old ID at the new revision is `{:conflict, :identity}`.
   - Lifecycle `suspend` refuses a new T1 Run and a T1 command; T2 still commits; `activate`,
     committed while the lifecycle switch is engaged, restores both (four admitted starts in
     total).
8. **Invitations on real PostgreSQL.** The host resolves that the inviter at R may grant
   `docs.write` at C. `invite` (code digest only) and `accept` run as checked commands. Two
   accepts with distinct operation IDs, prepared at revision 3, meet at a barrier inside a
   preparer that then calls `TenantLifecycle.prepare/3`. Exactly one is
   `{:completed, %{revision: 4}}` and the other `{:conflict, :stale_revision}`, each retained
   under its identity. The host applies each completed accept with the operation ID as a unique
   source: one membership row; replay of the winner returns its response and applies nothing.
   The membership is the exact six-key record and grants `docs.read, docs.write` at C. The code
   (text and bytes, raw or hex) is in no stored row; its digest is in `elzoo_log_records`
   (positive control of the search). The harness hands the Piece only the digest, as the
   `workflow/tenant-lifecycle` Contract requires, so this shows the host composition keeps the
   code out of storage; it is not a refusal by a Piece.
9. **Crypto-shredding with intact logs.** User text with a known name and an email is tokenized
   by `PiiRedaction.redact/2` with the vault Need `RetentionErasure.put/3` for the subject; the
   two refs open to the spans. The notes command stores only the tokenized text: neither raw
   value appears in any row of any table (read through `FORCE`, bytea as hex), and the refs do
   appear in `elzoo_log_records`. `erase` makes both refs `{:error, :not_found}` and the status
   `:erased`. A fresh handle on a fresh Store binding returns equal `result/3` and `resource/3`;
   the T1 stream head has `low_water == 0` and a revision equal to its record count; the
   record count and per-row SHA-256 are unchanged. Lifecycle `close` commits; `erase` with
   `vault_erased` computed from `RetentionErasure.status/2` is `not_erased` while the tenant
   subject is active, and commits only after both subjects are `erased`. At the end, the record
   hashes taken before the subject erasure and those taken just before the tenant-subject
   erasure (which include the close and the refused erase) are all still present, and the
   final erase only appended.

## Environment and checks

Toolchain: Elixir 1.20.4 / Erlang-OTP 29.1.2. The orb's disposable PostgreSQL 16.16 with
pgvector 0.8.7, in a database of this worker's own; the application role `elzoo_app` of
ELZ-285 (`NOLOGIN NOSUPERUSER NOBYPASSRLS NOINHERIT`, granted to `elzoo_test` with
`INHERIT FALSE, SET TRUE`).

```sh
ELZOO_TEST_APP_ROLE=elzoo_app mix test test/wave5_tenancy_test.exs --warnings-as-errors --repeat-until-failure 30
```

```text
Result: 9 passed   (31 consecutive runs)
```

The affected gate (`mix check --affected origin/main`), the roadmap and claims checks
(`python3 scripts/check-roadmap.py --live`, `python3 scripts/check-claims.py`) and
`git diff --check` are recorded with their exit codes in the pull request.

## Harness negative controls

Each was a temporary edit at `4eacf3ea`, run, recorded and reverted with `git checkout`; both
files then matched the committed SHA-256 (test `6e059de5…`, helper `aa0d1c7f…`). Control 1
ran `mix test test/wave5_tenancy_test.exs` (and `:94`, group 1, with the guard bypassed),
controls 2 and 4 ran `mix test test/wave5_tenancy_test.exs:427` (group 7) and control 3 ran
`mix test test/wave5_tenancy_test.exs:833` (group 9), each exiting 2. Line numbers are those
of `4eacf3ea`.

1. The application Repo connected without `SET ROLE` (as the owner). The guard failed
   `setup_all`, invalidating all nine tests:
   `the application connection is not the non-owner application role: %{session: "elzoo_test",
   super: false, current: "elzoo_test", bypass: false, inherits_owner: true}`. With the guard
   also bypassed, group 1 failed at its first owner-only refusal: `ALTER TABLE
   <schema>.documents NO FORCE ROW LEVEL SECURITY` succeeded.
2. The notes CheckedCommand gate replaced with `fn _, _ -> :allow end`: group 7 failed at the
   command refusal (`left: {:completed, %{response: {:record, [{"revision", 1}]}, revision: 1}}`,
   `right: {:denied, {:gate, "tenant_suspended"}}`).
3. The raw text passed to the command instead of the tokenized text: group 9's search failed
   (`H.leaks(p, [name, email])` was `["elzoo_log_records"]`).
4. The `control/4` pause removed: group 7's next-input case failed (`Unexpectedly received
   message {:work, "T1", "work-1"}` at the `refute_receive`).

These validate the harness; they do not replace the Pieces' own controls.

## Limits

- A RunEngine gate cannot see a switch engaged during its Run; live Runs stop through the
  host's Run control (`control/4`), as group 7 shows.
- A command refused by a gate keeps that retained denial under its operation ID.
- Carbonite `state/audit-log` is not composed (it needs its own audit-owner role), so audit
  capture of these commands is not shown.
- The MCP success path over a public endpoint is not shown; group 6 shows only the egress
  refusal path.
- Identity providers are pinned test keys; no JWT issuer or production key store.
- The RunEngine Runs, their Run owner, Unit, Effect intent and evidence stores run as the
  application role since ELZ-327, as do CheckedCommand, the vault and the consumer tables; the
  RunEngine fixture's owner Repo keeps only its schema and migration. The ready Store tables are
  not protected by `state/tenant-isolation`.
- The host checks (membership resolution, the payment check, invitation application, the
  `vault_erased` fact) are this harness's host code, not Pieces.
- Durability claims stay those of the reused Pieces; no database crash or failover is tested.
- Finite scenarios, not proofs. No complete-Wave claim.
