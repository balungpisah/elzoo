# ELZ-193 — A read of one statement in the PostgreSQL log store is one round trip

- Dependencies: ELZ-009
- Output: none. A change inside the ready Piece `integration/sql`; its Contract is unchanged and the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/integration/sql/**` only, and its index/generated changes under AGENTS.md section 3 (only when `piece.json` changes).

Issue #431 records the cost: one input at the bounds of
`assembly/run-engine` makes 1,046 SQL transactions, and about half of them
are reads. This task removes the wrapper of the reads that need none. It
is the first of several small tasks for #431; it does not close the issue.

Facts checked on `main` (lines of
`pieces/integration/sql/lib/elzoo/durable_log/postgres.ex` at the time of
writing; confirm each when you start, and if one differs, stop and ask):

- Every read callback goes through the private `read/3` (about 470 to
  500). It refuses inside a caller transaction, runs the `test_read` hook,
  and then opens a transaction, sends
  `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY`, runs the
  callback and commits, with the timeout of the store options. A read of
  one `SELECT` costs four round trips.
- `head` (about 122), `latest_checkpoint` (about 217), `read_checkpoint`
  (about 235), `pending` (about 253), `read_ack` (about 268) and
  `read_maintenance` with `:retain` (about 402) are expected to send one
  `SELECT` each. `read` (about 124) and `read_at` (about 144) send more
  than one statement (the head and the rows) and need one snapshot.
- The offer pass of `runtime/durable-unit` calls `pending` and `head`
  after every committed result, so each commit of a unit pays two such
  reads.
- The README and `piece.json` of the Piece state nothing about the
  isolation level of a read.

## The change

A read callback that sends exactly one statement sends it directly, with
no transaction and no `SET TRANSACTION`: one round trip. One statement
sees one snapshot, so the result is the same. Everything else of `read/3`
stays for these callbacks: the refusal inside a caller transaction (no
statement is sent), the `test_read` hook, the timeout, and the mapping of
every failure to the existing error values.

A callback that sends more than one statement keeps the transaction as it
is. Decide each callback by reading it: if one of the six named above
sends more than one statement on some path, it keeps the transaction, and
you name it in the pull request body.

The Contract does not change: no return value, error value, option,
migration or SQL result changes. Update the README only if it describes
the read path.

## Named acceptance groups

1. **`one_statement_reads_are_one_query`**: for each changed callback,
   one call makes exactly one query of the Repo, counted with the query
   telemetry of the Repo of the test, and none of them is a `begin`, a
   `commit` or a `SET TRANSACTION`. Negative control, by a temporary edit
   that is reverted: with the old wrapper the count differs and the test
   fails.
2. **`multi_statement_reads_keep_one_snapshot`**: `read` and `read_at`
   still run inside one repeatable-read, read-only transaction (asserted
   from the same query events).
3. **`refusals_are_unchanged`**: inside a caller transaction each changed
   callback returns `{:error, :caller_transaction}` and sends no query; a
   `test_read` hook that returns an error is returned as before; an
   unavailable Repo gives `{:error, :unavailable}`; a query that passes
   the timeout of the store gives `{:error, :unavailable}`.
4. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged.

## Evidence and gate

Run `mix test pieces/integration/sql/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. The small gate also runs the ready Pieces that depend
on this one. Record in the pull request body the count of queries of one
`pending` and one `head` before and after. Make no claim about wall time.
One independent review, risk normal (store code, reads only).

## Not in scope

The write path of the store (the head update and the inserts), the
record digests, `runtime/durable-unit`, `assembly/run-engine`, and any
other Piece.
