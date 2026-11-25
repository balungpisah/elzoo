# ELZ-393 — state/tenant-isolation: allow an opt-in Repo transaction timeout

- Dependencies: ELZ-270
- Release: V1B
- Output: no new Piece ID; provide the tenant-isolation prerequisite for #886.
- Change class: Piece-only implementation in the tenant-isolation lane. Keep the local small gate and hosted Piece check; also run the local affected gate for the shared transaction boundary used by root acceptances.
- Owned paths: `pieces/state/tenant-isolation/**`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No other Piece or root code changes.

## Contract

Keep `transact(repo, scope, fun)` unchanged, including Repo defaults, callback values and failure behavior. Add `transact(repo, scope, fun, opts)` with `[]` for the old behavior or exactly `[timeout: milliseconds]` with an integer in 1..600,000. Scope and callback validation still return `{:error, {:tenant_isolation, :scope}}` first; invalid options return `{:error, {:tenant_isolation, :timeout}}` before a query or callback. Valid options keep the existing open-transaction refusal and pass the timeout to the outer `repo.transact/2`, not the individual SQL statements. A connection deadline failure on the opt-in path is `{:error, :unavailable}`; this does not attest whether a commit happened. Preserve callback-domain errors, explicit rollback and unrelated exceptions. The Repo timeout bounds the database transaction; it does not kill application code in the callback or configure PostgreSQL `statement_timeout` or `lock_timeout`.

**Coordinator decision (owner can veto):** after the existing open-transaction check, the explicit-timeout path refuses an existing Repo checkout with `{:error, {:tenant_isolation, :in_checkout}}` before I/O or the callback. A nested transaction can otherwise inherit the checkout's later deadline. Do not add this refusal to `/3` or `[]`.

**Coordinator decision (owner can veto):** the callback is opaque. Its return values, raised exceptions and explicit rollbacks pass through unchanged, even after the explicit deadline and including driver errors that the callback obtains itself. On the opt-in path, only a deadline failure in work the helper owns (begin, setting and clearing the scope, and commit) becomes `{:error, :unavailable}`. A callback that returns success after the deadline gets `{:error, :unavailable}` from the failed commit.

## Acceptance

- Real disposable PostgreSQL with an ordinary pool, not a sandbox transaction: a short explicit timeout disconnects a held write transaction and its row is absent after the callback is released. The callback attempts to return `{:ok, value}` but the call is `{:error, :unavailable}`. The same write committed before a longer explicit timeout is present. Hold long enough to cross the short bound with margin, or observe the timeout before releasing the callback. Verify from a fresh transaction.
- With `transact/3` or explicit `[]`, the Repo default and callback result are unchanged; preserve scope clearing and rollback, nesting refusal, and fail-closed isolation as the application role. Exercise 1 and 600,000 as accepted option bounds without relying on useful work completing in 1 ms, and reject 0, 600,001, a non-integer, a duplicate key and an unknown key with no query or callback.
- Inside `Repo.checkout/2` but outside a transaction, use a checkout deadline longer than the explicit timeout. The opt-in call returns `:in_checkout`, without a SQL query or callback. `/3` and `[]` still run and return their callback values in that checkout; an existing transaction still gets the existing nesting refusal, not `:in_checkout`.
- An expiry after the scope is cleared and before commit gives `{:error, :unavailable}`, not `{:error, :rollback}`.
- A connection error or cancellation that the callback obtained from another Repo, and returns or raises after the deadline, is returned or raised unchanged.
- Negative controls: omit the timeout when calling the Repo (the short case commits under the longer Repo default); omit the checkout refusal (the opt-in checkout case executes the callback instead of refusing).

Tenant isolation, durable state and unknown outcomes: local small and affected gates and full review. No new dependency or per-statement timeout. Leave #886 open for the separate OAuth caller task.
