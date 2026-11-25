# ELZ-391 — runtime/os-isolation: a restarted Adapter does not notify twice

- Dependencies: ELZ-029, ELZ-305
- Release: V1B
- Output: no new Piece ID; restore the one-notification Contract for #710.
- Change class: Piece-only implementation.
- Owned paths: `pieces/runtime/os-isolation/**`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` if the manifest changes. No root or provider changes.

## Contract

Unchanged. Adapter recovery must not start an observer or notify again for an Owner that retired its row after the registry snapshot but before the dead-Owner decision. The dead-Owner decision uses the current row, including both retirement forms `:finished` and `{:finished, :exit_unconfirmed}`; retain the existing behavior for a genuinely abandoned live row. No new public option or result.

## Acceptance

- Force the interleaving, using a test barrier rather than a sleep: restart the Adapter, hold recovery after it snapshots the live row, let the Owner retire, notify and exit, then let recovery run. The submitter receives its original result (`completed` for a short command that finished, `unknown` with reason `port_closed` for the existing unconfirmed-exit fixture) and no second result. Synchronize the assertion with completion of recovery and any observer work. Exercise both retirement forms.
- Existing recovery scenarios still pass, including an Owner that really died without retiring.
- Negative control: use the old snapshot-only dead-Owner decision and show the completed case receives a second `unknown` result with reason `owner_exit`.

Native code and concurrency: local small gate and full review. No new dependency.
