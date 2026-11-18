# ELZ-264 — BotRunLifecycle v2 outside-event waits

- Phase: Level 4
- Dependencies: ELZ-124, ELZ-263
- Output: extension of the existing workflow/bot-run-lifecycle Piece; no new
  Piece ID.
- Owned paths: `pieces/workflow/bot-run-lifecycle/**`; this Piece's existing row
  only in `registry/catalogue.json` and `docs/plans/release-plan.json`; generated
  `LEDGER.md`, `docs/plans/views.md`, and `docs/plans/dependencies.mmd`.
  Update `piece.json`, README, catalogue summary as needed, and the existing
  release-plan `note`/`manifest_sha256` per AGENTS. Preserve ready status and all
  existing job/output ownership. No other Piece, shared runtime, dependency, pin,
  root-test, or CI changes.

Start after publication and ELZ-124/ELZ-263 merge. Follow normal Piece tests,
small gate, exact-head hosted check, review, queue, and main-push checks. A
selected gate is not full acceptance.

## Changed Contract

Keep `step/3` strictly v1. Add exactly the explicit v2 entry point
`step(state, input, context, 2)`; do not add a constructor. V2 supports every v1
action/input kind plus `wait_event`/`outside_event` and host Control operands.
Preserve the exact six state keys and all old v1 wait shapes. A v2 outside-event
wait adds only fixed `source_id` and `correlation_id`, and remains one-shot and
scoped to its execution Attempt. V2 tracker tags cannot mix with v1.

Outside-event context uses exactly `verified_event` with the trusted identity
triple `%{source_id: ..., correlation_id: ..., event_id: ...}`. Missing/malformed
or mismatching trusted facts, or input facts that do not equal this triple, are
invalid before lifecycle precedence. This is a caller-verified Need, not source
authentication. RunEngine supplies the facts. No source callback, clock, Store,
persistence, dispatch, cancellation runtime, or replay service is added.

After valid-input/context checking, retain existing precedence: terminal
absorption; authoritative `run_ended`; stale/old Attempt before time; recorded
deadline and cancellation/control decisions; then wait/source/ticket correlation
and budget decisions. A valid but expired current input can request existing
`out_of_time` before a wait mismatch is examined; do not blanket-refuse all
mismatches as unchanged state. Preserve current `step` result classes/shapes.

A valid event can settle only its matching open wait/action, source, correlation
ticket, event ID, and Attempt. Source/ticket mismatches are correlation decisions
after the precedence checks; mismatch with `verified_event` is invalid input.
Generic completed outcome cannot bypass verified event settlement; existing
non-completed failure may close a wait according to the current table. While
paused, record a valid already-open receipt but preserve pause and forbid work or
Run completion. Settling the last wait makes the Run active, not terminal. The
ready Run owner commits terminal outcomes.

## Needs and grounding

The caller owns verified identity, truthful Run/Attempt facts, recorded time,
budget facts, and serialized durable state. On main, `step/3` rechecks PatternStep
v1, correlates caller-owned waits, and applies precedence; v1 outside-event wait
fixtures are not a v2 event result or source-authentication implementation.

## Contract-to-test acceptance

1. Keep all v1 tests/fixtures unchanged. Exercise all v1 kinds and host Controls
   under explicit v2 selection; assert `step/3` does not reinterpret v2 and
   mixed-version trackers are refused using existing return shapes.
2. Test valid verified event, simultaneous independent waits, replay/duplicate,
   absent wait, wrong action, source, ticket, Attempt, event ID, settled outcome,
   and mismatched `verified_event`. Distinguish invalid trusted facts from
   correlation decisions after precedence.
3. Test terminal absorption, `run_ended`, old Attempt before time, exact Run
   and pause deadlines, expired current input before wait mismatch, cancellation,
   budget-pause and budget-finish precedence. Preserve existing order; do not
   invent errors.
4. Test generic completed versus failure outcomes, paused receipt without work
   or completion, final wait becoming active only, and pause/control behavior
   with explicitly versioned controls.
5. Temporarily bypass the source/ticket match in the production transition; the
   named mismatch assertion must fail. Restore exact source bytes. Keep selected
   Cure laws scoped to their finite table; they do not prove the new mapper.
6. Keep every v1 deadline-equality, stale-Attempt, terminal, and precedence case.
   Update README/manifest grounding only for implemented behavior. Run Piece
   tests/source guards, the selected Piece gate, and diff check, followed by the
   normal hosted/main checks. A selected pass is not full acceptance.
