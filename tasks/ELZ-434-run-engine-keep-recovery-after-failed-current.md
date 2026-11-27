# ELZ-434 — assembly/run-engine: a failed replacement recovery is retried before the next input

- Dependencies: ELZ-433

## Outcome and scope

`current/1` in `pieces/assembly/run-engine/lib/elzoo/run_engine.ex` (about
line 2986) recovers a replacement Unit. When `start_unit/2` returns a new
process, it runs `recover_local/1`, `sync_run/1`, `recover_intents/1`,
`release_waiting/3`, `consume_resources/1` and `drain/1` with `s.unit` set to
the new process. If one of those steps fails without a halt, `current/1`
returns `{:error, reason, s}`. An example is `{:error, :source_unavailable, s}`
when a ready `wait_event` cannot read its source head. The returned `s`
already names the new process.

Most callers keep that returned state. The next call's `current/1` then sees
`pid == s.unit`, takes the same-Unit branch, and skips the replacement
recovery. That call commits its own input before the failed recovery has been
retried. The affected callers are:

- `ingest/4` (about line 2076), behind `input/4`;
- `handle_call({:control, ...})` (about line 1902), behind `control/4`;
- the v1 `handle_info({:durable_unit_input, ...})` (about line 1946);
- the v2 outside-event path (about line 2205).

ELZ-433 changed only `accept_local_work_input/3`: after a non-halting error it
restores the state from before the call. That restores the PID of the stopped
Unit, so a write before the next `current/1` goes to a dead process. For
example, a queued `%Outbox.Item{}` (about line 1971) drains without calling
`current/1`. The ELZ-433 work found the other callers. This task fixes all of
them in place under the same ID (the rule of ELZ-415).

- When a replacement recovery in `current/1` fails without a halt, the engine
  keeps the returned state: the live replacement PID and every record that
  the recovery committed. It also records that the replacement recovery is
  unfinished.
- While recovery is unfinished, every path that would take input or drain
  first resumes the unfinished recovery steps. This covers `current/1` for
  each caller and the outbox-item path. The resumed recovery does not run
  `recover_local/1` again against the live replacement: work that the
  replacement started, such as a `local_work` task whose `:running`
  continuation is committed, is not reclassified as `local_restart`. A call's
  own input is committed only after the recovery has finished.
- A non-halting error on the same-Unit branch (no replacement) keeps the
  returned state, as today. A Run view that `sync_run/1` committed stays
  visible in `status/1`.
- After a halt, the returned state is kept, so `status/1` shows the halt. The
  reply to a failed call is unchanged.
- `accept_local_work_input/3` follows the same rule. Its ELZ-433 restore of
  the pre-call state is replaced.
- The README states the rule next to the ELZ-433 paragraph and adds a
  `## Changes` entry.

Paths: `pieces/assembly/run-engine/**`, its `entries` row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md` and
`docs/plans/views.md`. New external dependencies: none.

## Acceptance

- Tests with the ELZ-433 read-fault Store. `ReadFaultStore.new/1` exposes
  `:fold`, which `recover_snapshot/1` needs on the outside-event path. The v2
  fault is a source head read that fails for a ready `wait_event`. A v1
  non-halting fault is a pending resource input with a temporarily invalid
  pause deadline. For each of the four callers and for
  `accept_local_work_input/3`:
  - Stop the Unit, so that the next call recovers a replacement.
  - Make the recovery fail without a halt.
  - Assert that the failed call commits no record for its own ID.
  - Clear the fault and make the next call. Assert that the recovery resumes
    and finishes before the call's own input is committed, and that no
    recovery record is written twice.
- Between the failed recovery and the next call, a pending outbox item is
  delivered. The engine does not halt with `:delivery_unknown`, and the
  recovery resumes first.
- A `local_work` task that the replacement started before the failure
  completes after it. Its actual outcome settles it, not `local_restart`.
- A same-Unit non-halting failure after a committed Run view: `status/1`
  shows the committed view.
- After a halt in the same position, the call replies with the halt and
  `status/1` shows it.
- Negative controls, each recorded and reverted:
  - Drop the unfinished-recovery marker: the next call's own input is
    committed before the recovery.
  - Run `recover_local/1` again on the live replacement: the task's
    completion becomes `local_restart`.
  - Restore the pre-call state on a replacement failure: the outbox-item case
    halts with `:delivery_unknown`.
  - Restore the pre-call state on a same-Unit failure: `status/1` shows the
    previous view.
- The frozen-row and cold-recovery tests pass unchanged.
- `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, or the pull request records the exact reason a
  command cannot run on the host. The hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the Piece keeps durable state), and the exact-head automated review
  with its threads answered and resolved, or the authorized replacement review
  under `AGENTS.md` section 6.
