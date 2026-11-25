# ELZ-396 — assembly/run-engine: keep the original wait when a reused action ID is refused

- Dependencies: ELZ-127, ELZ-387, ELZ-389
- Release: V1B
- Output: no new Piece ID; restore occurrence-first settlement for #946.
- Change class: Piece-only implementation.
- Owned paths: `pieces/assembly/run-engine/**`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` if the manifest changes. No other Piece or root code changes.

## Contract

Unchanged. A reused action ID still settles its new occurrence with refusal `reused_identity`, without dispatch or a new lifecycle wait. The refusal cannot delete the earlier live occurrence's wait. A correlated outcome before that earlier slot's deadline reaches its own callable and settles that slot normally; it is not late merely because the reused ID was refused. Keep ordinary wait cleanup on settlement, expiry and close, and keep both protocol versions, start options and durable record shapes unchanged. Apply the same occurrence rule on durable fold/recovery and the retained readers; do not synthesize an outcome absent from the history. If a history already affected by the defect needs format or compatibility policy beyond restoring the Contract, report it rather than silently changing the format.

## Acceptance

- Without opt-in start options, the root starts two tool calls `t1` and `t2`; the outcome of `t1` makes the root ask for another `t2`. Assert a refusal of the new occurrence and no second dispatch. Deliver the original `t2` outcome with its own occurrence before its deadline; `input/4` acknowledges it and the slot settles, with applied classification and a single owner delivery. Check the transcript or committed slot state, not only `{:ok, :applied}`, which also acknowledges a recorded late input. A genuine duplicate of the input does not redeliver it.
- Exercise the same rule with `messages: :while_active` as an alternate way to request the reused ID, then restart between the refusal and the original outcome on the same Store to check that recovery retains the wait without redispatch. Existing expiry and retained history tests still pass.
- Negative control: restore deletion by action ID alone; the no-option original outcome is classified late and its slot remains running, failing the regression case.

Durable state, concurrency and unknown outcomes: local small gate and full review. No new dependency.
