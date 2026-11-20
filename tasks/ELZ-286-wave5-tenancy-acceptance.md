# ELZ-286 — Exercise many tenants safely end to end on PostgreSQL as a non-owner application role

- Phase: Wave 5 Level 3 (sub-level 3c), mandatory root consumer acceptance
- Dependencies: ELZ-268, ELZ-269, ELZ-270, ELZ-272, ELZ-278, ELZ-279, ELZ-281, ELZ-283, ELZ-284, ELZ-285
- Release: V1B
- Output: none
- Change class: shared root consumer acceptance; full/affected gate

## Admission and scope

This mirrors ELZ-252 and ELZ-266. It is not ready until every dependency has merged. It exercises the actual public interfaces of the Wave 5 Pieces together with ready `assembly/checked-command`, `assembly/run-engine` and the PostgreSQL Store. No new production Piece, runtime, provider or generic test framework. A failure of an owning Piece's Contract is a separately scoped repair, not permission to edit that Piece here or to weaken an assertion. Passing this alone makes no claim about production identity providers, a live public MCP endpoint or Carbonite audit capture.

The application connection runs as the fixed role of ELZ-285: the test Repo's `after_connect` runs `SET ROLE` to `ELZOO_TEST_APP_ROLE`, and the owner Repo runs migrations. If the variable is unset, or the connected role is an owner, superuser or `BYPASSRLS` role, the test **fails**. It does not print `NOT EXERCISED` and does not skip.

## Fixture

There are two flat tenants, T1 and T2, and one hierarchical tenant T3. T3 has root R, a child A with `block_inheritance: true`, a grandchild B under A and a sibling C under R, with `non_inheriting: ["money."]`. Consumer tables are protected with `state/tenant-isolation` in a random schema: a flat table, a spaced table, and an append-only table whose rows reference a membership row. Principals come from `integration/token-verify` API keys (keys generated in the test), and permissions and space lists from `domain/membership`.

## Acceptance

1. Database floor as the application role: `verify/3` is `:ok` for every protected table. Under T1, reads, updates and deletes touch only T1 rows. An insert or move to T2 gives SQLSTATE 42501. `NO FORCE`, `DISABLE`, `DROP POLICY` and `SET row_security = off` are refused. A query without a tenant filter outside the helper returns no row.
2. Identity to rows: an API key verifies to a principal. `Elzoo.Membership.spaces/4` gives the space list that `transact/3` uses, so a T3 member at R sees R and C rows, not A or B. A member at A sees A and B. An agent delegated from that member is capped by its scopes. A T1 principal sees no T3 row with any space list the membership resolves.
3. Soft revocation: setting `revoked_at` on the membership row (the row is kept, and the append-only rows that reference it stay valid) removes its spaces at the next call. The FK row is still present and readable by an authorized principal.
4. Non-inheriting scope: `money.pay` held at R resolves at R only, the `money.pay` space list excludes C, and a write that needs it at C is refused by the host check. A membership at C grants it there.
5. Provider data policy: a model action whose payload is tagged `:pii`, bound for a provider the tenant policy does not admit, is denied by the host gate on a live RunEngine Run (`domain/provider-data-policy` `{:deny, _}` mapped to `{:deny, code}`). An admitted one passes. A malformed policy denies.
6. Runtime MCP egress: `Elzoo.McpRuntime.admit/1` for a tenant-added URL whose resolver answers `10.0.0.5`, `169.254.169.254`, `127.0.0.1` or a mixed public/private set is refused with `{:egress, :non_public_address}`. The credential Need is never called and no client process starts (counted).
7. Kill switch on live work: a tenant switch committed through CheckedCommand on the PostgreSQL Store. Then the next action of a live RunEngine Run of that tenant is refused by the gate with `tenant_suspended`, a checked command of another descriptor is refused, and a new Run is not started. T2's Run proceeds. The release lets the next action pass. A gate built over a failed `resource/3` read (an unreachable Store binding) denies `kill_switch_unavailable`. Every gate is built over a read taken just before its call, as ELZ-281 requires. `workflow/tenant-lifecycle` `suspend` has the same effect and `activate` undoes it.
8. Invitations on real PostgreSQL: invite and accept as checked commands. Two accepts with distinct operation IDs race at one revision behind a controlled barrier: exactly one commits, the other has the retained stale result, and the host applies exactly one membership. Replay of the winner returns its response. No invitation code appears in any `elzoo_log_records` row.
9. Crypto-shredding with intact logs: user text with an email and a known name is tokenized by `integration/pii-redaction`, whose vault Need is `Elzoo.RetentionErasure.put/3` for the subject. The checked command's payload then holds only refs (search every stored row for the raw values: none). `erase` makes every ref `:not_found`. A fresh CheckedCommand handle then recovers the tenant stream (`low_water == 0`) with equal `result/3` and `resource/3`, and no `elzoo_log_records` row was deleted or changed (row count and per-row SHA-256 before and after). Lifecycle `close` then `erase` with `vault_erased: true` commits only after `RetentionErasure.status/2` is `erased` for the tenant's subjects.
10. Negative controls in this acceptance, one at a time: connect the application Repo without `SET ROLE` (as owner), and group 1's refusals must fail; replace the kill-switch gate with `:allow`, and group 7 must fail; pass the raw text instead of the tokenized text, and group 9's search must fail. Restore before the final passing checks. These validate the harness; they do not replace the Pieces' own controls.

## Owned paths and validation

`test/wave5_tenancy_test.exs`, an optional bounded fixture `test/support/wave5_tenancy_helper.exs`, and `docs/research/wave5-tenancy.md`. No Piece, root dependency or pin, export, registry, CI, workflow or queue change. The short report records the exact cases, commands, environment versions, negative-control failures and their restoration, and limits. It makes no complete-Wave claim.

Limits to state: Carbonite `state/audit-log` is not composed (it needs its own audit-owner role), so audit capture of these commands is not shown. The MCP success path over a public endpoint is not shown. Identity providers are pinned test keys. Durability claims stay those of the reused Pieces.

Run the new root acceptance with real disposable PostgreSQL and the role of ELZ-285, then `mix check --affected origin/main`, the live roadmap and claims checks and the diff check. No selected-Piece shortcut. One independent review, exact-head hosted checks and the coordinator merge queue are required. Never turn a skipped database test or a mocked protocol into integration evidence.
