# ELZ-032 — Refuse PostgreSQL Store calls inside a caller transaction

- Phase: P2 durable workflow (bug fix to the ELZ-009 ready Contract)
- Catalogue IDs: integration/sql (bug fix; same ID), state/outbox and state/checkpoint only if their callers need a matching documented result
- Dependencies: ELZ-009

## Outcome

Restore the ELZ-009 commit-point rule for `integration/sql`. Today `Elzoo.DurableLog.Postgres`
calls `repo.transaction/2`. Inside a caller's open Ecto transaction that call joins the outer
transaction and issues no COMMIT, but the adapter still returns `{:committed, n}`; a later outer
rollback erases the write (ELZ-010 early review, finding S1, on `docs/work/ELZ-010.md` at
`23e87a9`). The approved ELZ-009 Contract defines `committed` as "provider `COMMIT` returned ok".
Reads run `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY`, which fails inside an
outer transaction that already ran a query and can abort the caller's transaction.

This is an implementation bug fix that restores the existing Contract, so the Piece IDs stay the
same (AGENTS.md "Evolving a ready Contract"). The reason for keeping the IDs must be recorded.

## Scope

- Before any I/O, every Postgres Store callback checks `repo.in_transaction?()`.
- A write callback (`append`, `put_checkpoint`, `retain`, `ack`, `repair_torn_tail`) refuses with
  `{:rejected, :caller_transaction}`: confirmed nothing written, with no provider statement issued.
  It never returns `committed` or `indeterminate` for this case.
- A read callback returns `{:error, :caller_transaction}` without issuing a statement, so the
  caller's transaction is not poisoned.
- Add the reason to the Contract's rejected/read result lists with this rationale, and to the
  Store behaviour docs and the `integration/sql` README limits.
- Keep the Memory double unchanged. It has no caller transactions; state that explicitly.

## Acceptance

- [ ] Scenario: inside `Repo.transaction`, each write callback returns `{:rejected, :caller_transaction}`;
      after the outer transaction commits *or* rolls back, the stream is unchanged (test).
- [ ] Scenario: inside an outer transaction that already ran a query, each read callback returns
      `{:error, :caller_transaction}` and the outer transaction can still run a query and commit (test).
- [ ] Existing K1–K11 and D-scenarios still pass unchanged; mix check passes.
- [ ] The Contract note records why this restores rather than widens the ready Contract.

## Evidence and limits

Tests ground the listed scenarios against a disposable PostgreSQL. `Repo.in_transaction?/0`
and Ecto's nested-transaction behaviour are upstream Ecto SQL 3.14.0 contracts. No claim about
transactions opened outside Ecto on the same connection.

## Out of scope

Savepoint-based nesting, cross-stream outbox discovery, any ELZ-010 job behaviour.
