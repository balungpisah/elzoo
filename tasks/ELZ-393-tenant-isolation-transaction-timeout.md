# ELZ-393 — state/tenant-isolation: allow an opt-in Repo transaction timeout

- Dependencies: ELZ-270
- Release: V1B
- Output: no new Piece ID; provide the tenant-isolation prerequisite for #886.
- Change class: Piece-only implementation in the tenant-isolation lane. Keep the Piece hosted check and run the affected gate locally for the shared transaction boundary used by root acceptances.
- Owned paths: `pieces/state/tenant-isolation/**`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No other Piece or root code changes.

## Contract

Keep `transact(repo, scope, fun)` unchanged, including Repo defaults, callback values and failure behavior. Add `transact(repo, scope, fun, opts)` with `[]` for the old behavior or exactly `[timeout: milliseconds]` with an integer in 1..600,000. Scope and callback validation still return `{:error, {:tenant_isolation, :scope}}` first; invalid options return `{:error, {:tenant_isolation, :timeout}}` before a query or callback. Valid options keep the existing open-transaction refusal and pass the timeout to the outer `repo.transact/2`, not the individual SQL statements. A checkout/connection deadline failure on the opt-in path is `{:error, :unavailable}`; this does not attest whether a commit happened. Preserve callback-domain errors, explicit rollback and unrelated exceptions. The Repo timeout bounds the database transaction; it does not kill application code in the callback or configure PostgreSQL `statement_timeout` or `lock_timeout`.

## Acceptance

- Real disposable PostgreSQL with an ordinary pool, not a sandbox transaction: a short explicit timeout disconnects a held write transaction and its row is absent after the callback is released. The callback attempts to return `{:ok, value}` but the call is `{:error, :unavailable}`. The same write committed before a longer explicit timeout is present. Hold long enough to cross the short bound with margin, or observe the timeout before releasing the callback. Verify from a fresh transaction.
- With `transact/3` or explicit `[]`, the Repo default and callback result are unchanged; preserve scope clearing and rollback, nesting refusal, and fail-closed isolation as the application role. Exercise 1 and 600,000 as accepted option bounds without relying on useful work completing in 1 ms, and reject 0, 600,001, a non-integer, a duplicate key and an unknown key with no query or callback.
- Negative control: omit the timeout when calling the Repo; the short case commits under the longer Repo default and fails its assertion.

Tenant isolation, durable state and unknown outcomes: local affected gate and full review. No new dependency or per-statement timeout. The OAuth caller is separate.
