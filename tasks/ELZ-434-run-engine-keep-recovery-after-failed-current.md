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

ELZ-433 fixed only `accept_local_work_input/3`: it keeps the state of a halt,
and otherwise the state from before the call. The ELZ-433 work found the
other callers. This task fixes them in place under the same ID (the rule of
ELZ-415).

- Every caller of `current/1` follows the ELZ-433 rule. After a halt (a state
  with `halted` set, a failed winner read included), it keeps the returned
  state, so `status/1` shows the halt. After any other error, it keeps the
  state from before the call, so the next call runs the replacement recovery
  again before it takes its own input. The reply to the failed call is
  unchanged.
- Records that the failed recovery already committed stay committed. Examples
  are a Run-view synchronization and a `local_restart` settlement. Running the
  recovery again must not duplicate them. The steps are idempotent for
  records already committed; if one is not, that is a finding of this task.
- The README states the rule next to the ELZ-433 paragraph and adds a
  `## Changes` entry.

Paths: `pieces/assembly/run-engine/**`, its `entries` row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md` and
`docs/plans/views.md`. New external dependencies: none.

## Acceptance

- For each of the four callers, a test with the ELZ-433 read-fault Store does
  the following:
  - Stop the Unit, so that the next call recovers a replacement.
  - Make the recovery fail without a halt, for example through a source head
    read that fails for a ready `wait_event`.
  - Assert that the failed call commits no record for its own ID.
  - Clear the fault and make the next call.
  - Assert that the replacement recovery runs again (for example, the
    `release_waiting` or `drain` effect is observed), that this happens before
    the call's own input is committed, and that no recovery record is written
    twice.
- After a halt in the same position, the call replies with the halt and
  `status/1` shows it.
- Negative controls, each recorded and reverted: for `ingest/4` and for
  `control/4`, keep the returned state after a non-halting error. In both, the
  next call's own input is committed before the recovery runs.
- The frozen-row and cold-recovery tests pass unchanged.
- `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, or the pull request records the exact reason a
  command cannot run on the host. The hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the Piece keeps durable state), and the exact-head automated review
  with its threads answered and resolved, or the authorized replacement review
  under `AGENTS.md` section 6.
