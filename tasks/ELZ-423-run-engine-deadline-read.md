# ELZ-423 — assembly/run-engine: read the committed Run and pause deadlines

- Dependencies: ELZ-420

## Outcome and scope

The engine keeps two deadlines in its committed lifecycle state
(`control.lifecycle.run_deadline` and `control.lifecycle.pause_deadline`,
decided by `workflow/bot-run-lifecycle`):

- The `run_deadline` start option sets the first Run deadline. An applied
  `continue` control replaces it with the control's `run_deadline` and clears
  the pause deadline.
- A `pause` control sets the pause deadline from its `pause_deadline`. An
  internal pause (for example a Budget exhaustion or an expiry report under
  `budget_rule: :pause`) takes the `pause_deadline` of the trusted `context`.
  A Run that is already paused keeps its pause deadline.
- An admitted `wake` at or after the Run deadline, or at or after the pause
  deadline while paused, requests `:out_of_time`.

`status/1` shows neither deadline. So a host that must wake a Run at its
deadline cannot learn the current one after a `continue`, an internal pause or
a restart. The `run_deadline` start option at a restart is the original value:
it is part of the fingerprint.

Add one read. Nothing else changes. This is an improvement under the rule of
ELZ-415 (same Piece ID).

    Elzoo.RunEngine.deadlines(engine)
      :: {:ok, %{phase: phase, run_deadline: ms, pause_deadline: ms | nil}}

- It reads the same committed state as `status/1`, in one call to the engine
  process with the same 60,000 ms limit, so it replies after the input that the
  engine is working on. `phase` is the value `status/1` gives at that point:
  `:active`, `:waiting`, `:paused` or `:terminal`.
- `run_deadline` is the committed Run deadline: the start option until the
  first applied `continue`, then the `run_deadline` of the last applied
  `continue`. It is a positive integer (Unix milliseconds) in every phase,
  also after a terminal outcome.
- `pause_deadline` is the committed pause deadline when `phase` is `:paused`,
  and `nil` in every other phase.
- After a restart on the journal both values come from the recovered state,
  never from the start options.
- `status/1` does not change. `run_engine_frozen_rows_test.exs` compares its
  whole result with the frozen fixtures, so new keys there would change
  frozen data.

Update the README (next to the `status/1` text, and a `## Changes` entry for
this task) and `piece.json` (contract, grounding). In the last commit, update
the Piece's `entries` row in `docs/plans/release-plan.json`
(`manifest_sha256`, and `note` equal to the new `contract`; keep its primary
`job`, since this task is a secondary contribution) and the generated files,
regenerated from current `main` and never hand-merged. Only
`pieces/assembly/run-engine/**` changes outside the index files.

## Acceptance

Tests in `pieces/assembly/run-engine/test`. Each case uses a current
Attempt. Both `pause` controls come before the first pause deadline, and each
`continue` comes before either deadline, with a matching verified person and
a future Run deadline. Under `budget_rule: :pause`, a `wake` carries the
future pause operand that the existing ingress requires.

- A new Run: `run_deadline` equals the start option, `pause_deadline` is
  `nil`, and `phase` equals the `phase` of `status/1`.
- A `pause` control: `phase` is `:paused` and `pause_deadline` equals the
  control's value. A second `pause` keeps the first value. A later `continue`
  with a new Run deadline: `phase` is `:active` or `:waiting`, `run_deadline`
  is the new value and `pause_deadline` is `nil`.
- An internal pause under `budget_rule: :pause`: `pause_deadline` equals the
  `pause_deadline` that the trusted `context` gave for the record that paused
  the Run.
- Recovery: after a `continue` that replaced the deadline, and separately
  after an internal pause, stop the engine and start it again on the same
  journal with the original start options. `deadlines/1` gives the committed
  values, not the start option.
- A Run ended `:out_of_time` by an admitted `wake` at its deadline: `phase` is
  `:terminal` and `pause_deadline` is `nil`.
- The frozen fixtures, `run_engine_frozen_rows_test.exs` and the row hashes
  of `run_engine_cold_recovery_test.exs` do not change.
- `mix test pieces/assembly/run-engine/test`,
  `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0. The hosted check is green on the exact head.
- One independent review by the strongest available model of another family
  (the Piece keeps durable state), and the exact-head automated review with
  its threads answered and resolved, or the authorized replacement review
  under `AGENTS.md` section 6.
