# workflow/stall-detect

`Elzoo.StallDetect.verdict(window, limits, now_ms, approval_waits)` decides from
a bounded window of one Run's record that the Run makes no progress. It is one
pure function. It gives a verdict with a reason class and stops nothing: the
caller decides what to do. No process, clock, timer, storage, new input kind,
action kind or outcome class is added. Ready `workflow/pattern-step` keeps its
Contract unchanged.

## Operands and results

- `window`: a list of 1..256 v1 neutral maps (requests and inputs) in record
  order, oldest first. The caller chooses how much of the newest record to pass.
  The bound is fixed, not Config.
- `limits`: exactly `%{repeats: n, idle_ms: ms}`; `repeats` in 2..256, `idle_ms`
  a positive integer.
- `now_ms`: nonnegative Unix milliseconds, an argument. No clock is read, and the
  time is never an input kind or a window entry.
- `approval_waits`: 0..64 action IDs (nonempty UTF-8 text) for which the host
  holds an open approval request. The v1 shapes have no approval word, so the
  caller supplies this fact.

Results: `{:ok, :not_stalled}`, `{:ok, {:stalled, :repeated_action}}`,
`{:ok, {:stalled, :no_input}}`, `{:error, :window_too_large}`,
`{:error, :invalid_shape}`. An error echoes no operand.

## Rules, in order

1. More than 256 entries: `:window_too_large`, before any entry is read.
2. Each entry passes `PatternStep.decode/1`, the window holds at least one input
   that is not a `wake`, and the other operands have the shapes above; otherwise
   `:invalid_shape`.
3. **Repeated action.** Actions are identical when `kind`, `schema_id`,
   `schema_version` and `payload` are equal by `===`, with no normalization; the
   `id` is not compared. When an action of the newest request has at least
   `repeats` identical actions among all actions of the window's requests
   (itself included), the verdict is `{:stalled, :repeated_action}`.
4. **No input.** A `wake` has no content and is not a new input. With `last` the
   greatest `at_ms` of the other inputs, `now_ms - last >= idle_ms` and no healthy
   wait gives `{:stalled, :no_input}`.
5. Otherwise `:not_stalled`.

An action is open when its request is in the window and the ready PatternStep
tracker of that request, fed each later input of the window through
`open/1` and `accept/2`, applied no input to it. A healthy wait is an open
`ask_person` action, or an open action whose ID is in `approval_waits`; an ID
there that names no open action is ignored. A healthy wait suppresses only
rule 4. Shape checks and settlement are PatternStep's, not repeated here.

A retry keeps its action ID and adds no action to a request, so it is never a
repeat; `delivery/retry-timeout` owns retry exhaustion, and the outcome class
`retries_exhausted` gets no rule here.

## Grounding

`mix test pieces/workflow/stall-detect/test` runs the named groups
`repeated_identical_actions`, `no_new_input_within_bound`,
`healthy_person_or_approval_wait`, `window_over_bound_refused` and
`deterministic_verdict` over fixed recorded traces with hand-written expected
verdicts, plus the checked example in `examples/elzoo/stall_detect.exs` (two
identical model calls with `repeats: 2`). These are listed finite scenarios, not
a proof. No Cure law is selected: the verdict is a count, a subtraction and a
fixed order of two rules. Upstream: pinned Elixir term equality and integer
arithmetic, and ready PatternStep validation and settlement, used unchanged.

Needs: the window in true record order with engine-recorded times; Run-wide
unique action IDs; a truthful `approval_waits` list from the host's approval
state; a window that holds the request of each open ask and approval wait.

Limits: the function sees only the window. An open ask whose request is outside
it is not recognised, so the caller sizes the window or leaves `wake` inputs out
of it. The two thresholds are the caller's; no default exists. A Run that has
ended gets no rule: the caller does not ask about it. The verdict is about the
record, not a provider, a person or a retry policy. Telemetry and Control are
not applicable; Config is the two thresholds, per call, with no ambient setting.

The module is application-owned under `Elzoo.StallDetect`; copy it with its
dependency `workflow/pattern-step`. See [consuming](../../../docs/consuming.md).
Apache-2.0; provider Elixir at the repository pin. No new dependency.
