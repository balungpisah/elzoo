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
   is a completed result, not an Adapter error), `rejected{queue_full | queue_timeout | spawn_failed | cancelled}` (not dispatched; `spawn_failed` only where no command was dispatched; `cancelled` only where a queued command was not dispatched), `expired{deadline}` when the declared deadline passed before dispatch (not dispatched), `terminated{stage: term | kill, deadline}` (`stage` is the ending signal the selected provider reports for the group leader after a termination it performed: `term` for SIGTERM, `kill` for SIGKILL; it is never derived from timing or from the Adapter's own requests; when the provider reports no signal for a termination it performed, the result is `unknown`, never `terminated`; the selected provider erlexec 2.6.0 reports the leader's ending signal but not who sent it, so a SIGTERM or SIGKILL reported at or after the deadline instant (taken before the spawn request) is `unknown{signal_after_deadline, signal}` and one reported before that instant is `completed{exit_code: 128 + signal}`: with erlexec 2.6.0 `terminated` is never produced), `unknown` when the liveness check itself fails, when the group is still observed alive after the provider's termination sequence or after the leader's exit and the bounded reap wait, when the provider performed a termination (explicit stop or owner death) and reports no ending signal, when a SIGTERM or SIGKILL is reported at or after the deadline instant (`signal_after_deadline`, carrying the reported signal as an observation, not a stage), or when the provider's port program stopped reporting; `unknown` does not establish cleanup or relax the termination invariant or acceptance criteria; mapped to the
   core/envelope result matrix as `completed` (any exit code) →
   `completed/dispatched` (pre-dispatch validation requires an absolute path to an existing regular file with an execute bit and an existing working directory, otherwise `rejected{spawn_failed}`; an exec failure that occurs after that validation is reported by the provider as exit status 1 and therefore as `completed{exit_code: 1}`, indistinguishable from a command that exits 1: a declared residual), `rejected{…}` → `rejected/not_dispatched`, `expired` → `timed_out/not_dispatched`,
   `terminated` on deadline → `timed_out/dispatched`, paired with the Adapter result carrying the observed stage; the shared delivery-result map remains unchanged and has no stage field (this row is unreachable with erlexec 2.6.0: a deadline outcome is `unknown{signal_after_deadline}` → `unknown/dispatched`); `terminated` on explicit cancellation, caller death or death of the collecting BEAM process → `failed/dispatched`, paired with the Adapter result carrying the observed stage (this row is unreachable with erlexec 2.6.0, whose stop reports no ending signal: `unknown{provider_masked_stop}` or `unknown{owner_exit}` → `unknown/dispatched`); only report definitive termination when it is observed, and partial external Effects remain possible,
   `unknown` → `unknown/dispatched`. Invariants: the
   spawned process is a process-group leader; termination is performed by the selected provider's port program in its documented sequence: SIGTERM to the group, then SIGKILL to the group after the configured kill timeout if the leader is still alive, and SIGKILL at once if the SIGTERM request itself fails; the Adapter itself never sends a signal; the stage reported is the ending signal the provider reports for a termination it can be shown to have performed, otherwise the result is `unknown` (with erlexec 2.6.0 no stage is ever reported); when the owning BEAM process dies, the provider's port program stops the group through the link it holds to that process, and when the VM exits, the port program's own finalize stops every child it started; a process that leaves its group, a group member that ignores SIGTERM after the leader has exited, and the death of the port program itself are declared residuals reported as `unknown`, never as `terminated` or `completed`. Non-goals: security isolation, shell parsing, path
   confinement (domain/authorization).
   Needs: an executable path and declared executable version, a working directory, an explicit environment allowlist (names inherited from the host plus names set per call; everything else is unset for the child), the erlexec 2.6.0 port program (`exec-port`, built from the pinned Hex package with the host C++ toolchain) for spawning, group creation, deadline escalation and owner-death cleanup, the declared host `pgrep` and `id` utilities for group observation and for detecting a root VM, and, when the VM's effective user is root and the consumer has not configured erlexec's `root`/`user` settings, erlexec started with `root: true` and the unprivileged effective user `provider_user` (Config, default `nobody`), with `SHELL=/bin/sh` set for the VM when `SHELL` is unset, because the port program refuses to run as root without an effective user and requires `SHELL`; a consumer that already configured or started erlexec keeps its configuration; residual: the port program and every child then run as that user and need read and execute permission on the executable, the working directory and every file they use, and the VM's `SHELL` is changed when it was unset. The `integration/agent-runner` task records the exact Claude Code CLI and Codex CLI versions.
3. **Reuse check.** erlexec 2.6.0 (BSD-2-Clause) owns spawning through its port program, process-group creation (`{group, 0}`), the staged SIGTERM→SIGKILL escalation on the group (`kill_group`, `kill_timeout`), the wall-clock deadline (`timeout`), owner-death and VM-exit cleanup, environment clearing and output capture; muontrap 2.0.1 was probed and rejected (it kills only its direct child unless a Linux cgroup is configured and reports no ending signal). Elzoo owns admission, the deadline conversion, the output bound, the group observation after the exit notification, the result schema and the delivery mapping; signal delivery and escalation timing are the provider's and the OS's behaviour.
4. **Split test.** Admission (slot pool: the ELZ-006 bounded receiver applied
   to host processes) and termination (group kill) can be chosen
   independently, but the result schema is one interface so a caller cannot
   confuse `rejected` with `terminated`.
5. **Failure and evidence.** Dangerous paths: a timed-out command keeps
   running after the Adapter returns; the collecting process is killed and
   the OS process leaks; a double-forked daemon escapes the group; `kill`
   reports success without delivering. Tests: timeout → group observed empty; brutal
   kill of the collector → group observed empty through the provider's owner-death stop; escalation stage reported from the provider's ending signal (SIGTERM honoured → `term`, SIGTERM ignored → `kill`); a signal request accepted without effect (SIGTERM ignored) never yields `term`; a member that ignores SIGTERM after the leader exits → `unknown`; exec failure after validation → `completed{exit_code: 1}`; provider stopped reporting → `unknown`; `queue_full` vs `queue_timeout`; non-zero exit is `completed`. Upstream:
   POSIX signal semantics and OTP `Port` are named contracts; no proof.
6. **Composition record.** Depends on ELZ-006 admission results and
   core/envelope result schema; consumes a deadline from
   delivery/retry-timeout. Termination requests are at-most-once within a
   host. Command lines may carry secrets; redact in Telemetry. Owner death and recovery: the Adapter records a registry row for a run before it asks the provider to spawn and records the provider's OS pid as the owner's first action after the spawn returns; if the owning BEAM process dies before that pid is recorded, the provider still stops the child through the link it established at spawn, but the Adapter cannot name the group and reports `unknown{owner_exit_before_registration}`; if it dies after, the provider stops the group, the Adapter observes the group with `pgrep` and reports `unknown{owner_exit, members}` with the last observed members, because the provider reports no ending signal on that path; after an Adapter restart, runs whose owner is alive continue and reply to their callers, runs whose owner is dead are reported as above, and queued requests are lost (their callers' calls exit with the Adapter's exit reason); in every `unknown` case the caller must inspect or reconcile the external outcome and must not retry blindly.

## Scope

- define the result schema and termination state machine;
- implement the smallest Adapter and reaper with a test harness that spawns
  real processes on the symbolic runner;
- test the listed dangerous paths.

## Acceptance

- [ ] Timeout and collector death both stop the group through the selected provider's port program, and the group is observed empty after the bounded reap wait; a member that ignores SIGTERM after the leader has exited is reported as `unknown`, never as `terminated` or `completed` (executable tests on the Linux CI runner).
- [ ] The reported escalation stage is the provider-reported ending signal for a termination the provider can be shown to have performed; when the provider reports none, or reports a SIGTERM or SIGKILL at or after the deadline instant that it cannot be shown to have sent, the result is `unknown`, never an assumed stage; with erlexec 2.6.0 every deadline termination is therefore `unknown{signal_after_deadline}` carrying the reported signal.
- [ ] Non-zero exit is `completed`; queue rejections are `not_dispatched`.
- [ ] Operational applicability is declared per docs/operational-contracts.md.

## Evidence and limits

Tests over listed scenarios on one OS; no sandbox or cross-host claim.

## Out of scope

Containers, seccomp, filesystem confinement, remote execution.

## Reference

Shape observed in pixir 0.1.17 bash tool and command boundary; see
docs/research/ecosystem-round-2.md. No code is copied.
