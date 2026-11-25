# ELZ-397 — delivery/dead-letter-store: state what a purge retry can delete after an unknown commit

- Dependencies: ELZ-301
- Release: V1B
- Output: no new Piece ID; correct the retry guarantee for #947, the BLOCKER from the section 6 recheck of PR #699.
- Change class: Piece-only tests and Contract wording; no library code change.
- Owned paths: `pieces/delivery/dead-letter-store/README.md`, `pieces/delivery/dead-letter-store/piece.json`, `pieces/delivery/dead-letter-store/test/**`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`.

## Contract

This supersedes ELZ-301's general write-retry wording for `purge/3`; the README and manifest must agree. `{:error, :unavailable}` still does not establish whether the write committed. `purge/3` is excluded from the write-retry guarantee: after an unknown outcome the same request can delete up to another `limit` eligible records and reports only its own deletion count. Only records for that tenant, resolved strictly before the requested cutoff, are eligible; open records are never deleted. The first call's result cannot be recovered. `put/3` and `resolve/3` keep their existing retry rules and purge/key-reuse limits. No operation identity, replay or new behavior.

## Acceptance

- On disposable PostgreSQL as the application role, seed four eligible records, one open record, one resolved exactly at the cutoff and one eligible by time in another tenant. Run a `purge/3` with `limit: 2` to commit and discard its result at the caller boundary (simulate the lost reply). Confirm only the first two eligible records are gone. Repeat the exact request, receive `{:ok, 2}` and check that it removed the other two. Confirm the three ineligible records survive both calls and a further repeat returns `{:ok, 0}`; the request has no way to replay the first result. Exercise the public API; do not fault production code to simulate the lost reply.
- Negative control: temporarily make the repeat a no-op or replay the count without deleting its own batch, at the test boundary. The retry assertion that the second pair is gone must fail even if the count is still two. Restore the control before the final gate.

Durable deletion, tenant isolation and unknown outcomes: local small gate and full review. No new dependency.
