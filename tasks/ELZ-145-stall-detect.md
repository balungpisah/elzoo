# ELZ-145 — Stall verdict from the record

## Scope and reuse

- Dependencies: ELZ-033, ELZ-114
- Output: `workflow/stall-detect`; release V1B; bot-platform level 2.
- Owned paths: `pieces/workflow/stall-detect/**` and its index/generated changes under AGENTS.md section 3.

Decide from a bounded window of the recorded requests and inputs of one Run that the Run makes no progress. One pure function over values in the v1 shapes of ready `workflow/pattern-step`. It gives a verdict with a reason class and stops nothing: the caller decides what to do. No process, clock, timer, storage or new input, action or outcome word.

Implement only the five acceptance groups below. Add no options, layers, behaviours, generic helpers or future hooks. Change no ready Piece, shared path, `mix.exs`, `mix.lock` or CI file. The independent reviewer flags extra features for removal.

Reuse: the one Piece dependency is `workflow/pattern-step`. `PatternStep.decode/1` checks each entry, and `open/1` with `accept/2` say which action is still open. Write no second shape check and no second settlement rule. `delivery/retry-timeout` owns retry exhaustion, which is a different fact: a retry keeps its action ID and adds no action to a request, so it is never a repeat here, and the outcome class `retries_exhausted` gets no rule.

## Interface: `Elzoo.StallDetect`

One public function:

`verdict(window, limits, now_ms, approval_waits)` returns `{:ok, :not_stalled}`, `{:ok, {:stalled, :repeated_action}}`, `{:ok, {:stalled, :no_input}}`, `{:error, :window_too_large}` or `{:error, :invalid_shape}`. An error echoes no operand.

- `window`: a list of 1..256 entries of the record in record order, oldest first. Each entry is a v1 neutral map: a request or an input. The caller chooses how much of the newest record to pass. The bound 256 is fixed, not Config.
- `limits`: the exact map `%{repeats: n, idle_ms: ms}`. `repeats` is an integer in 2..256: the count of identical actions that is a stall. `idle_ms` is a positive integer of milliseconds.
- `now_ms`: the current time as nonnegative Unix milliseconds. It is a function argument. The function reads no clock, and the time is never an input kind or an entry of the window.
- `approval_waits`: a list of 0..64 action IDs for which the host holds an open approval request. The v1 shapes have no approval word (the engine asks for an approval; it is never an action kind), so the record in these shapes cannot show this wait and the caller supplies it.

Rules, in this order:

1. A window with more than 256 entries is `{:error, :window_too_large}`. This check runs before any entry is read.
2. Each entry must pass `PatternStep.decode/1`, and the window must hold at least one input that is not a `wake`. The other three operands must have the shapes above. Otherwise `{:error, :invalid_shape}`.
3. **Repeated action.** Two actions are identical when `kind`, `schema_id`, `schema_version` and `payload` are equal as exact terms (`===`), with no normalization. The `id` is not compared: it differs by definition. When an action of the newest request of the window has at least `repeats` identical actions among all actions of all requests of the window, itself included, the verdict is `{:stalled, :repeated_action}`.
4. **No input.** A `wake` is not a new input: it has no content. Let `last` be the greatest `at_ms` of the other inputs of the window. When `now_ms - last >= idle_ms` and the window shows no healthy wait, the verdict is `{:stalled, :no_input}`.
5. Otherwise the verdict is `:not_stalled`.

An action is open when its request is in the window and the ready tracker of that request applied no later input of the window to it. A healthy wait is an open action whose kind is `ask_person`, or whose ID is in `approval_waits`. An ID in `approval_waits` that names no open action of the window is ignored. A healthy wait suppresses only rule 4.

## Host Needs and Limits

Needs: the window in true record order with the times that the engine recorded; Run-wide unique action IDs; a truthful `approval_waits` list from the host's approval state; a window that holds the request of each open ask and each approval wait.

Limits: the function sees only the window. An open ask whose request is outside the window is not recognised, so the caller sizes the window or leaves `wake` inputs out of it. The two thresholds are the caller's and no default exists. A Run that has ended gets no rule of its own: the caller does not ask about it. The verdict is a statement about the record, not about a provider, a person or a retry policy. Telemetry and Control are not applicable. Config is the two thresholds, per call, with no ambient setting.

## Named acceptance groups

Each recorded trace is a fixed list of v1 neutral maps in the test file, as `@v1_fixture` of `workflow/pattern-step` is. No provider fixture is needed. Expected verdicts are written by hand.

1. **`repeated_identical_actions`**: with `repeats: 3`, three requests that each hold the same tool call under three IDs, with outcomes between them, give `{:stalled, :repeated_action}`; two give `:not_stalled`. A different payload, kind or schema version is not identical. One action with a `retries_exhausted` outcome is not a repeat. When rule 3 and rule 4 both hold, the verdict is `:repeated_action`.
2. **`no_new_input_within_bound`**: one trace and three values of `now_ms`: `last + idle_ms - 1` gives `:not_stalled`; `last + idle_ms` and `last + idle_ms + 1` give `{:stalled, :no_input}`. The times come from `at_ms` of the trace and `now_ms` is only the argument. A `wake` that is newer than `last` does not move `last`.
3. **`healthy_person_or_approval_wait`**: with `now_ms` far past the bound, an open `ask_person` gives `:not_stalled`, and an open tool call whose ID is in `approval_waits` gives `:not_stalled`. Paired controls on the same traces: after an `expired` outcome settles the ask, and with the ID absent from `approval_waits`, the verdict is `{:stalled, :no_input}`. An ID in `approval_waits` that names no open action changes nothing.
4. **`window_over_bound_refused`**: 256 entries are accepted; 257 give `{:error, :window_too_large}`, also when an entry is malformed. An empty window, a malformed entry, a window of wakes only and malformed limits give `{:error, :invalid_shape}` with no value in the error.
5. **`deterministic_verdict`**: the same window and arguments give the same verdict on each call, and an equal window that was built separately (payload maps built in another key order) gives the same verdict.

## Evidence

Tests only. No Cure law is selected: the verdict is a count, a subtraction and a fixed order of two rules over a list, and a law over supplied Booleans would add nothing that groups 1 to 3 do not show. Report it to the coordinator if the worker finds a decision here that earns a law; do not add one silently.

- Test: the five groups; one small checked example; two negative controls. Count a `wake` as a new input for a moment: `no_new_input_within_bound` must fail. Ignore open asks for a moment: `healthy_person_or_approval_wait` must fail. Revert both.
- Upstream: ready `workflow/pattern-step` validation and settlement, used unchanged; pinned Elixir term equality and integer arithmetic.
- Assumption: the host Needs above. Proof, type check and monitored behavior: none.

Run the Piece tests, then `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. Record commands, exit codes, scenarios and limits separately. One independent review checks this body and the exact diff, including features that nobody asked for.
