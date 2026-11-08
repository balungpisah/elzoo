# delivery/trigger (schedule occurrence slice)

Pure Cure policy with a validating Elixir boundary that turns already computed
due slots into admissible schedule occurrences. Apache-2.0. Task ELZ-027,
issue #44. Only the schedule-occurrence slice of `delivery/trigger` is ready;
webhook and app-event triggers stay out of scope.

## What it decides

- **Identity.** `Elzoo.ScheduleOccurrence.identify(schedule_id, generation,
  scheduled_unix_ms)` returns `{:OccurrenceId, schedule_id, generation,
  scheduled_unix_ms}`. Arrival instant, availability boundary, node, process
  and delivery id are not inputs. `encode_id/1` gives the derived text key
  `"<generation>:<instant>:<schedule id>"`; `decode_id/1` inverts it.
- **Overlap policy.** `skip` records `skipped{slot, overlap}` while an
  occurrence is unsettled; `replace` records `replaced{old id, new id}` and
  keeps only the new one; `queue(n)` admits while fewer than `n` are unsettled
  and records `skipped{slot, queue_full}` beyond. At most one occurrence is
  unsettled under skip and replace, at most `n` under queue.
- **Offline catch-up.** The caller passes `%{now_unix_ms, available_since_unix_ms}`
  with each admission call. A due slot before the boundary is an offline
  catch-up slot: `skipped{slot, offline_catch_up}` under skip and replace,
  `occurrence{id, offline_catch_up}` under queue within the bound. A slot at
  or after the boundary is live. The caller is responsible for establishing
  that the scheduler was continuously available from the boundary through now
  and that every unrecorded earlier slot passed while offline; the piece
  validates `boundary <= now` only and refuses the call otherwise.
- **Watermark.** The last recorded instant is supplied at `new/2` and
  advances to every decided slot. A slot at or below it returns
  `already_recorded{slot}`, with no occurrence id, because the slot may have
  been skipped or decided under an older generation. The watermark is per
  schedule and survives redefinition.
- **Settlement.** `settle(state, {:acknowledged | :released, id})` removes a
  matching unsettled occurrence; an older generation is
  `rejected{stale_generation}`, anything else not unsettled is
  `rejected{unknown_occurrence}`. Both are terminal and cancel nothing.
- **Delivery admission.** `admit_delivery(state, id, payload)` is a query:
  `admitted` only when the id is unsettled and the payload equals the schedule
  payload of that generation; the state never changes, so a retry keeps its
  identity.
- **Redefinition.** `redefine(state, schedule)` with the same schedule id and
  a strictly greater generation supersedes every unsettled occurrence and
  records their ids as `redefined{old generation, ids}`; equal or lower
  generations, a different id or an invalid definition change nothing.

## Boundary

```elixir
{:ok, state} = Elzoo.ScheduleOccurrence.new(
  %{schedule_id: "digest", generation: 1, policy: {:queue, 2}, payload: "weekly"},
  definition_instant_unix_ms)

{:ok, state, decisions} = Elzoo.ScheduleOccurrence.admit_slots(
  state, due_slots_ascending, %{now_unix_ms: now, available_since_unix_ms: available_since})
```

Decisions: `{:occurrence, id, :live | :offline_catch_up}`,
`{:already_recorded, slot}`, `{:skipped, slot, :offline_catch_up | :overlap |
:queue_full}`, `{:replaced, old_id, new_id}`. The whole call is refused without
any transition for a slot after `now` (`{:error, {:not_due, slot}}`), a boundary
after `now`, a missing boundary, an unsorted batch or a malformed term.
`restore/3` rebuilds a retained state from the schedule, the watermark and the
unsettled ids; `inspect_state/1` returns them.

The caller must apply transitions through one serialized owner per schedule (a
process, or a compare-and-set store such as ELZ-009 when composed).
Deterministic ids do not serialize concurrent activations; the test exercises
one owner process and sequential replay only.

## Composition (as written in issue #44)

- **core/envelope result schema.** `settlement_from_result/1` validates a
  DeliveryResult with `Elzoo.Envelope.validate_result/1`, decodes the occurrence
  id from `correlation_id`, and maps `completed` to acknowledged, `rejected`
  and `failed` to released, `timed_out` and `unknown` to `:no_settlement`
  (an unknown external outcome is never treated as no effect).
- **delivery/idempotency on the consumer side.** `consumer_dedup(histories, id,
  value)` keeps one real idempotency history per schedule id in a map held by
  the consumer owner, with message key `(sender 0, incarnation = generation,
  sequence = scheduled instant)`. Two schedules with equal generation and
  instant never share a key; `forget_schedule/2` retires a history, after which
  the occurrence emits again. Retention is the idempotency Piece's own:
  unbounded within a history, volatile.
- **delivery/time recipe as the clock port.** The recipe is `Process.send_after`
  and timer cancellation; clock reads stay in the owning shell and the instant
  and boundary are passed into the pure transition as data. The test owner
  does exactly that; the piece never reads a clock and the recipe does not
  read one either.

## Grounding

Proofs are checked by the pinned Cure compiler over the production functions
`admit_slot`, `settle`, `admit_delivery`, `redefine` and `identify`. The
production code is a chain of total dispatch functions that receive each
comparison as a Bool computed at the call site; laws generalize that Bool,
prove both branches and instantiate with the production expression, so the
statement is about the production function by definitional equality. Int
comparisons and string equality do not reduce symbolically in the pinned Cure
and appear as hypotheses.

| Law | Quantified over | Hypotheses |
| --- | --- | --- |
| `identify_schedule_id`, `identify_generation`, `identify_instant` | all ids, generations, instants | none |
| `bound_skip`, `bound_replace` (Equivalent forms of `within_one_skip`, `within_one_replace`) | all schedule ids, generations, payloads, watermarks, unsettled lists, slots, arrivals | `Within(one, list)` |
| `bound_queue` (Equivalent form of `within_bound_queue`) | all Peano bounds and the same | `Within(n, list)` |
| `recorded_keeps_state`, `not_due_keeps_state` | all states, slots, arrivals | the production comparisons as stated |
| `offline_skip_keeps_unsettled`, `offline_skip_advances`, `offline_replace_keeps_unsettled` | all skip/replace configurations | not recorded, due, before the boundary |
| `live_identity_skip`, `live_identity_replace`, `live_identity_queue` | all configurations (skip from empty; queue with `room` true) | not recorded, due, at or after the boundary |
| `arrival_independent_skip`, `arrival_independent_replace`, `arrival_independent_queue` | two arbitrary arrivals | the live hypotheses for both |
| `stale_redefinition_keeps_state`, `redefinition_records_displaced`, `redefinition_clears_unsettled` | all states and definitions | validity, same id and generation comparisons as stated |
| `stale_settlement_keeps_state`, `unknown_settlement_keeps_state` | all states, ids, kinds | generation comparison; `find` result |
| `stale_delivery_rejected`, `absent_delivery_rejected`, `mismatched_delivery_rejected` | all states, ids, payloads | generation comparison; `find` result; payload equality |

`Within(n, xs)` is an indexed proposition (`within_nil`, `within_cons`) proved
through the dispatch chain and, for queue, by induction in `room_true_within`.
What the laws do not say: the truth of the comparisons for concrete integers,
behaviour across several calls, durability, concurrency or the availability
predicate. Those are tests or assumptions.

Tests (`test/elzoo/schedule_occurrence_test.exs`): two activations through a
serialized owner and by replay, restart, replay after skip/settlement/
redefinition, each policy, offline catch-up, clock and ordering edges with
fail-closed refusals, generation conflict, delivery query, identity encoding and
DST fixture instants (identity for supplied instants, not timezone mapping),
configuration and malformed terms, the three composition boundaries, a seeded
trace against an independent model, the Cure audit and seven production
mutation controls (identify generation and instant, placement slot, queue room
at capacity, skip append when busy, already-recorded admits, equal-generation
redefinition), each required to fail inside the named law.

Upstream: pinned Cure, Elixir 1.20.4, OTP 29.1.2. Due-instant and timezone
computation stay upstream; `crontab` 1.2.1 (MIT) and `oban` 2.24.2
(Apache-2.0) are the recorded candidate calculators of the wider
`delivery/trigger` WRAP disposition and are neither exercised nor pinned by
this slice. Jido Sensor ideas were clean-room comparison input; no source was
copied.

## Operational applicability

Telemetry `not_applicable` (pure decisions). Config `supported`: policy and
queue bound (1..1024) fixed per generation at construction or restore, changed
only by a strictly greater-generation redefinition that supersedes pending
occurrences; payload, slots, instants and the boundary are data. Control
`not_applicable`: settlement and redefinition are domain data, not lifecycle
commands.

This directory is a source bundle. See
[consumption instructions](../../../docs/consuming.md). Copied source is
Apache-2.0; evidence describes the recorded source bytes and selected
scenarios.
