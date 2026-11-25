# ELZ-400 — integration/oauth-client: compute and check an opt-in refresh transaction deadline

- Dependencies: ELZ-361, ELZ-393
- Release: V1B
- Output: no new Piece ID; bound the OAuth refresh transaction for #886.
- Change class: Piece-only implementation; local small gate, hosted Piece check and full review.
- Owned paths: `pieces/integration/oauth-client/**`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No new dependency or changes to tenant-isolation or other Pieces.

## Contract

**Coordinator decision (owner can veto):** use a checked host overhead budget rather than deriving the transaction timeout from the exchange alone. An optional `refresh_deadline` binding key takes a map with exactly `lock_wait_ms`, `overhead_ms` and `persistence_reserve_ms`. Require positive integer millisecond values, a reserve no larger than the overhead, and `lock_wait_ms + exchange_timeout_ms + overhead_ms` no greater than 600,000; malformed declarations return the existing binding validation error. With the key absent, keep behavior exactly as today and retain the current Repo `:timeout` Need text for that path.

Use that sum as the explicit tenant transaction timeout for opt-in `access_token/3`, the path that takes the lock before deciding whether to return a fresh token, refresh, or obtain client credentials. Other calls keep the existing transaction path and Need. Keep the existing open-transaction refusal and fail closed as `{:error, :unavailable}` for a refused existing checkout on the opt-in path. Do not add a per-statement timeout: the lock-wait declaration allocates transaction time, not a separate PostgreSQL statement deadline. The overhead covers pool and local work, including the host Needs and response processing through final persistence and commit. Its persistence reserve is the declared post-dispatch portion; the host must actually bound this work.

Start a monotonic elapsed-time measurement before entering the transaction. Immediately before the request is dispatched, after request preparation and its host Needs, require at least `exchange_timeout_ms + persistence_reserve_ms` of the computed transaction time remaining. If not, return `{:error, :unavailable}` with no token request and no state or revision change. Do not shorten the exchange to squeeze it into a remaining window. This is a pre-dispatch check, not a guarantee that the host meets its declared bounds or a claim to eliminate unknown outcomes after dispatch. Preserve the exchange and rotation decisions, one-dispatch rule, and handling of a database failure after dispatch.

## Acceptance

- On real disposable PostgreSQL with an ordinary pool, a rotating refresh started with sufficient headroom takes longer than a deliberately short Repo default yet completes within the computed deadline. The new token and revision survive a fresh read. Under the same short Repo default without opt-in, exercise the existing lost-result behavior; with a suitable Repo default the unchanged path still succeeds.
- Force elapsed work before dispatch, including a lock wait and a preparation Need, so the exchange alone would fit but its persistence reserve would not. The call refuses with no provider request and the old token and revision remain. Exercise both sides of the headroom boundary without a sleep-only ordering assumption. Two callers of the same connection still serialize: a successful refresh leaves the waiting caller with the fresh token and no second request. Cover the opt-in client-credentials dispatch and fresh-token path; a checkout refusal performs no exchange.
- Test malformed declarations, the maximum allowed sum and one above it, and reserve greater than overhead. Missing key keeps the existing binding and default behavior; `nil` is not a declaration.
- Negative controls: omit the explicit transaction option (the successful slow rotation loses its result under the short Repo default); remove the headroom check or its persistence reserve (the no-dispatch case makes a request).

Secrets, tenant isolation, durable state, concurrency, external effects and unknown outcomes: local small gate and full review. Do not add a retry layer, recover a lost post-dispatch result, or change non-opt-in calls.
