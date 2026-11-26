# ELZ-420 — assembly/run-engine: a root finish that names no action fails its Run

- Dependencies: ELZ-415, ELZ-416

## Outcome and scope

Today a root `finish` must name a completed action of the current Attempt
(`run_engine.ex`, `dispatch` for `kind: "finish"`). The engine reads
`payload["action_id"]` and looks for a settled, completed slot of the same
Attempt with that action ID. With `"action_id": null`, or no `action_id` key,
there is no source: the finish slot settles `refused` with reason
`"completion_evidence"` and actual 0, and the Run stays open. So a pattern
cannot fail its Run:

- `workflow/agent-loop` ends with a `stopped` finish whose `action_id` is
  `null` (reasons such as `model_call_not_completed`);
- `workflow/graph-run` ends a failed root graph with a finish whose
  `action_id` is `nil`.

Such a Run stays open until a separate owner or lifecycle action closes it: a
host cancel, its deadline (which needs a host input), a Budget stop under the
host's policy, or a direct owner `complete`. The Run owner
(`workflow/run-approval-release`) accepts all five outcomes. For an outcome
other than `:completed` it accepts a `nil` evidence reference and validates a
supplied one (Run, Attempt, operation and a non-empty action ID). `result/3`
returns `{:terminal, outcome}` for each noncompleted outcome without reading
any history, and its reader finds a completed source only among accepted
protocol settlements.

New rule, a breaking change under the rule of ELZ-415 (same Piece ID):

- The null/absent-source rule applies to a root finish admitted for dispatch
  after the schema, gate, Budget, authority and Approval checks. A root
  `finish` whose payload has `"action_id": null`, or no `action_id` key, then
  ends the Run with outcome `:failed`. The engine commits a root-failure
  finish transition in its Unit (a new record kind, or a branch of the
  `:finish` record that only this path reaches). The finish slot settles
  `completed` with the finish action's own `schema_id`, `schema_version` and
  payload: that payload is the failure record. Its Budget entry settles at
  actual 0, and its transcript time is the record's time.
- Then, as for a completed Run, the engine appends the `completion` evidence
  row (the same kind and the same four keys `run_id`, `attempt_id`,
  `operation_id`, and the finish action's `action_id`) and completes the Run
  owner with `:failed`, reason `"pattern"` and that evidence reference. The
  reason describes; it is no proof of where the failure came from (any caller
  can send that reason). The reader proves it from the Unit history.
- The transition goes through the v2 replay validation and the transcript
  settlement, at the same dispatch points as the `:finish` record
  (`project_event_wait_transition`, `validate_pure_wait_transition_result`,
  `transcript_at`, `transcript_actual`).
- A root `finish` that names an action is unchanged: that action must be
  settled completed in the same Attempt, else `completion_evidence`. A nested
  finish is unchanged.
- With `result_reader` configured, `result/3` for an owner outcome `:failed`
  returns `{:failed, record}` only for a matching committed root-failure
  finish in the paired Unit history, cross-checked against the Run, Attempt
  and operation, the original finish schema and payload, its slot, the stable
  owner facts and the canonical evidence row. The record has the keys of the
  completed record: `run_id`, `attempt_id`, `operation_id`, `action_id`,
  `schema_id`, `schema_version`, `payload`, `evidence_ref`. A healthy,
  verified paired history with no root-failure transition still gives
  `{:terminal, :failed}` (a plain owner failure). If damage, unavailability
  or a read limit prevents proving that absence, the reader returns
  `{:error, :history}`, `{:error, :unavailable}` or `{:error, :read_limit}` as
  appropriate; it does not classify that as a plain owner failure. For a
  journaled failure, a damaged referenced row, or a valid row whose stream or
  Run, Attempt, operation or action does not match the journaled finish,
  fails closed (`{:error, :completion_mismatch}` or `{:error, :history}`, as
  for a damaged completed Run), never `{:terminal, :failed}`. The reader keeps
  its scope check, its byte and row limits and its rule of calling no
  callback. `:cancelled`, `:out_of_budget` and `:out_of_time` still give
  `{:terminal, outcome}`.
- The records of the completed, paused and open flows do not change: the
  frozen fixtures (`completed-v1.etf`, `paused-v1-owner.etf`,
  `open-v2-messages.etf`), `run_engine_frozen_rows_test.exs` and the payload
  and row-field hashes of `run_engine_cold_recovery_test.exs` stay as they
  are.
- Recovery: a restart after the transition replays to the same state and
  finishes the owner command once. As for a completed Run, the evidence row is
  appended before the owner command, so a crash between them leaves that row
  unreferenced and the retry appends a new one with the same four fields. The
  Unit transition records no evidence sequence, so such equivalent orphan
  evidence rows are allowed; the result is read from the exact row that the
  sole terminal owner record names, and exactly one terminal owner row
  commits.

Update the README and `piece.json` of `assembly/run-engine` (contract, limits,
grounding; the result limit that says noncompleted Runs expose no payload),
and add a `## Changes` section with the entry of this task: the root-finish
rule, `:failed` as an engine outcome and `{:failed, record}` from `result/3`.
Correct the ready texts that promise the old refusal, wording only: the
README of `workflow/agent-loop` (its sentence that a `stopped` finish comes
back refused) and its `piece.json` limit (the ready run engine refuses a
stopped root finish), and the README of `workflow/graph-run` (a failed root
finish, or one with `action_id` `null`, comes back refused). They now say: a
root finish with a null or absent source fails the Run; the named-source and
nested-callable rules are unchanged. No code of either Piece changes.

Paths: `pieces/assembly/run-engine/**`, `pieces/workflow/agent-loop/README.md`,
`pieces/workflow/agent-loop/piece.json`, `pieces/workflow/graph-run/README.md`
and `test/wave9_tools_doors_models_money_test.exs` (its helper already
supplies `result_reader` and Budget headroom). In the last commit: the
`entries` rows of `assembly/run-engine` and `workflow/agent-loop` in
`docs/plans/release-plan.json` (`manifest_sha256`, and `note` equal to each
new `contract`; keep each row's primary `job`, since this task is a secondary
contribution) and the generated files, regenerated from current `main` and
never hand-merged.

## Acceptance

Tests in `pieces/assembly/run-engine/test`:

- A root finish with `"action_id": null` ends the Run `:failed`, and so does
  one with the `action_id` key omitted (separate cases, each with a finish
  schema that admits it). `status/1` shows the terminal outcome; `result/3`
  returns `{:failed, record}` with the finish payload and an `evidence_ref`
  that cross-checks; the transcript shows the finish settled at its recorded
  time with actual 0.
- After the gate and admission succeed, a root finish with a wrong action ID,
  and one naming an existing source that is not completed, are still refused
  `completion_evidence`, and the Run stays open.
- A plain owner failure stays `{:terminal, :failed}`: the existing loop over
  the four noncompleted owner outcomes in `run_engine_test.exs` keeps passing.
- Fail closed for a damaged referenced evidence row, and for a valid row
  whose stream or Run, Attempt, operation or action does not match the
  journaled finish. A paired history whose damage or read limit prevents
  proving that no root-failure transition exists gives `{:error, :history}`
  or `{:error, :read_limit}`, not `{:terminal, :failed}`.
- The completed path keeps its records and its result; the fixtures, the
  frozen-row test and the cold-recovery hashes are unchanged.
- A crash cut after the failure transition and its evidence row commit and
  before the owner command: after restart there is exactly one committed
  terminal owner row. Equivalent orphan rows are allowed, and the result is
  read from the exact row named by that sole terminal owner record.
- On the failed Run: a different `:complete` for the current Attempt is
  `{:refused, :terminal_conflict}`; an exact duplicate is
  `{:unchanged, :duplicate, revision}`.
- A v2 Run ended this way recovers and passes the v2 replay validation, and
  its transcript reads.

Integration, in the owned root test:

- `test/wave9_tools_doors_models_money_test.exs` already runs the real
  AgentLoop through the engine with the arity-2 pattern wrapper
  `Elzoo.Wave9.Agent.step/2` of its helper (it calls `AgentLoop.step/3` with
  the host's estimate function). In its `r4` scenario (one model call that does
  not complete, `unknown`, which cannot enter the model retry branch) assert:
  the model slot is `unknown`, the finish slot is `completed` (no longer
  `refused`), the Run is `:failed`, and `result/3` returns the stopped payload
  (reason `model_call_not_completed`). Keep its one-intent and no-fallback
  assertions, and correct its comment that the Run has no completion.

Gate and review:

- `mix check --affected origin/main` exits 0, or the pull request records the
  exact reason a command cannot run on the host. `git diff --check` exits 0.
  The full hosted check is green on the exact head.
- One independent review by the strongest available model of another family
  (the Piece keeps durable state and a Run outcome), and the exact-head
  automated review with its threads answered and resolved, or the authorized
  replacement review under `AGENTS.md` section 6.
