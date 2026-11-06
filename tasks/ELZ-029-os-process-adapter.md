# ELZ-029 — Specify the OS-process Adapter boundary

- Phase: demand-led runtime Adapter
- Catalogue IDs: runtime/os-isolation
- Dependencies: ELZ-006

## Outcome

Run one external OS command on behalf of a Run with bounded concurrency, a
deadline, group-scoped termination and an observed termination outcome. A
BEAM process and a process group are not a sandbox; this boundary owns the
state machine and result schema, not security isolation.

## Admission record

1. **Responsibility and caller.** Admit, run, observe and terminate one host
   command. Callers: C6 agent tool execution and C8 background transform; a
   deterministic build step challenges generality.
2. **Interface and invariant.** Inputs: command spec, working directory,
   deadline, grace period, limits `{max_concurrent, queue_limit,
   queue_timeout}`. Outputs: `completed{exit_code, output}` (a non-zero exit
   is a completed result, not an Adapter error), `rejected{queue_full |
   queue_timeout}` (not dispatched), `terminated{stage: term | kill,
   deadline}`, `unknown` when the liveness check itself fails; mapped to the
   core/envelope result matrix as `completed` (any exit code) →
   `completed/dispatched`, `rejected{…}` → `rejected/not_dispatched`,
   `terminated` on deadline → `timed_out/dispatched` carrying the stage,
   liveness-check failure → `unknown/dispatched`. Invariants: the
   spawned process is a process-group leader; termination signals the group,
   waits the grace period and escalates only if the group is still alive; the
   escalation stage reached is reported, never assumed; cleanup runs even if
   the owning BEAM process dies; a process that leaves its group is a
   declared residual. Non-goals: security isolation, shell parsing, path
   confinement (domain/authorization).
3. **Reuse check.** OTP `Port` and `System.cmd` spawn; no maintained library
   owns group-scoped termination with staged escalation across BSD and procps
   `kill` variants. Elzoo owns the state machine and result schema; signal
   delivery is OS behaviour.
4. **Split test.** Admission (slot pool: the ELZ-006 bounded receiver applied
   to host processes) and termination (group kill) can be chosen
   independently, but the result schema is one interface so a caller cannot
   confuse `rejected` with `terminated`.
5. **Failure and evidence.** Dangerous paths: a timed-out command keeps
   running after the Adapter returns; the collecting process is killed and
   the OS process leaks; a double-forked daemon escapes the group; `kill`
   reports success without delivering. Tests: timeout → group dead; brutal
   kill of the collector → group dead; escalation stage reported;
   `queue_full` vs `queue_timeout`; non-zero exit is `completed`. Upstream:
   POSIX signal semantics and OTP `Port` are named contracts; no proof.
6. **Composition record.** Depends on ELZ-006 admission results and
   core/envelope result schema; consumes a deadline from
   delivery/retry-timeout. Termination requests are at-most-once within a
   host. Command lines may carry secrets; redact in Telemetry.

## Scope

- define the result schema and termination state machine;
- implement the smallest Adapter and reaper with a test harness that spawns
  real processes on the symbolic runner;
- test the listed dangerous paths.

## Acceptance

- [ ] Timeout and collector death both leave no surviving process group
      (executable tests on the symbolic runner).
- [ ] Escalation stage is reported from observation, not assumed.
- [ ] Non-zero exit is `completed`; queue rejections are `not_dispatched`.
- [ ] Operational applicability is declared per docs/operational-contracts.md.

## Evidence and limits

Tests over listed scenarios on one OS; no sandbox or cross-host claim.

## Out of scope

Containers, seccomp, filesystem confinement, remote execution.

## Reference

Shape observed in pixir 0.1.17 bash tool and command boundary; see
docs/research/ecosystem-round-2.md. No code is copied.
