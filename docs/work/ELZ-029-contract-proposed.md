# ELZ-029 — proposed Contract amendments (exact before/after text, revision 2)

> Redacted before publication (ELZ-070): local paths, session, dispatch, task and message ids, the test database name and role, and runner and machine names are replaced by placeholders or role words; hashes and byte-equality records in this file refer to the unredacted text. This file quotes exact before-texts for replacement; the runner name inside one quoted before-text is redacted too, so that quote is no longer byte-exact.

Status: **approved wording (A1–A7), not yet applied in this form; A7″ and A8 proposed in revision 4, A7′ withdrawn.** The main
coordinator approved A2 and A3 as written in revision 1 and the **reworded**
A1, A4, A5, A6 and A7 below (byte-exact before-texts from the focused re-review
[ELZ-029-early-rereview.md](ELZ-029-early-rereview.md), section "Exact
suggested wording"; A7 in the reviewer's sentence form naming
`integration/agent-runner`). The reworded texts replace the revision-1 wording.

**Current live state (important):** issue #46 and
`tasks/ELZ-029-os-process-adapter.md` currently carry the **revision-1
wording**, applied at commit `8dd1038` on the pieces coordinator's earlier
instruction before the re-review arrived (issue comment
[6723359800](https://github.com/balungpisah/elzoo/issues/46#issuecomment-6723359800);
plan hash `dd6d715b…`). Nothing is reverted. When the pieces coordinator gives
the go, the second edit is computed as: original body (git `64acad7`, sha256
`f844ecc1…`) → apply the exact replacements below in order (A1, A4, A5, A2, A3,
A6, A7) → set as live body → resync the task copy bytewise and the plan hash in
one commit. The before-texts below are substrings of the **original** body, as
the reviewer wrote them.

All replacements apply to section **2. Interface and invariant**.

## A1 — rejected set (reviewer wording)

Replace this exact issue substring:

```text
`rejected{queue_full |
   queue_timeout}` (not dispatched)
```

with:

```text
`rejected{queue_full | queue_timeout | spawn_failed | cancelled}` (not dispatched; `spawn_failed` only where no command was dispatched; `cancelled` only where a queued command was not dispatched)
```

## A4 — deadline expiry before dispatch (reviewer wording), after A1

Replace this exact substring:

```text
`rejected{queue_full | queue_timeout | spawn_failed | cancelled}` (not dispatched; `spawn_failed` only where no command was dispatched; `cancelled` only where a queued command was not dispatched)
```

with:

```text
`rejected{queue_full | queue_timeout | spawn_failed | cancelled}` (not dispatched; `spawn_failed` only where no command was dispatched; `cancelled` only where a queued command was not dispatched), `expired{deadline}` when the declared deadline passed before dispatch (not dispatched)
```

And replace this exact substring:

```text
`rejected{…}` → `rejected/not_dispatched`,
```

with:

```text
`rejected{…}` → `rejected/not_dispatched`, `expired` → `timed_out/not_dispatched`,
```

## A5 — stage `none` (reviewer wording)

Replace this exact issue substring:

```text
`terminated{stage: term | kill,
   deadline}`
```

with:

```text
`terminated{stage: none | term | kill, deadline}` (`none` only when a reliable observation establishes that the original group is empty before any termination signal; `none` does not claim signal delivery)
```

## A2 — stage travels in the paired Adapter result (approved as written)

Replace:

```text
`terminated` on deadline → `timed_out/dispatched` carrying the stage
```

with:

```text
`terminated` on deadline → `timed_out/dispatched`, paired with the Adapter result carrying the observed stage; the shared delivery-result map remains unchanged and has no stage field
```

## A3 — cancellation and owner death (approved as written)

Add directly after the A2 text (before the `, liveness-check failure` that
follows it in the original):

```text
; `terminated` on explicit cancellation, caller death or death of the collecting BEAM process → `failed/dispatched`, paired with the Adapter result carrying the observed stage; only report definitive termination when it is observed, and partial external Effects remain possible
```

## A6 — `unknown` after a surviving group (reviewer wording)

Replace this exact issue substring:

```text
`unknown` when the liveness check itself fails
```

with:

```text
`unknown` when the liveness check itself fails or the group is still observed alive after the kill stage and the bounded reap wait; `unknown` does not establish cleanup or relax the termination invariant or acceptance criteria
```

Also replace:

```text
liveness-check failure → `unknown/dispatched`
```

with:

```text
`unknown` → `unknown/dispatched`
```

## A7 — Needs (reviewer sentence form; `integration/agent-runner` named per main)

Insert after the exact issue anchor:

```text
   confinement (domain/authorization).
```

this text (as a continuation of the same list item):

```text
   Needs: an executable path and declared executable version, a working directory, an explicit environment allowlist (names inherited from the host plus names set per call; everything else is unset for the child), and declared host `kill` and `pgrep` utilities for signalling and group observation. The `integration/agent-runner` task records the exact Claude Code CLI and Codex CLI versions.
```

## A7′ — WITHDRAWN (revision 4)

The `/bin/sh` wrapper of revision 3 is withdrawn: the main coordinator ruled
that a library is exercised first, and the probe
([ELZ-029-provider-probe.md](ELZ-029-provider-probe.md)) found erlexec 2.6.0
fit. No `/bin/sh` or `setsid` Need.

## A7″ and A8 — superseded by the B-series below (revision 5)

The round-4 re-review graded A7″ ACCEPTABLE (conditional on the provider and
its anchor) and **rejected A8** as a weakening. A7″ is kept as B8 below,
anchored against the intermediate body. A8 is withdrawn: provider-masked stops
are reported as `unknown`, not as a `terminated` with an unobserved stage.

## B-series — Contract amendment packet (option A; revision 5; drafts for the main coordinator)

Base for every before-text: the **intermediate body** (original live body of
2026-11-08 with the approved A1–A7 rewordings applied in the documented order),
not the current live body, which carries the revision-1 wording. The final edit
of #46 is therefore one ordered rewrite computed from the original body:
A1, A4, A5, A2, A3, A6, A7, then B1–B9. Every weakened sentence names the
residual it leaves.

Anchoring: every before-text below is an exact substring, occurring once, of
the **intermediate body** = original #46 body (SHA-256
`f844ecc1000034daac0a7b9d245c63797e4f811f5690d17fb72340cd7bf09ebb`) with the
approved A1, A4, A5, A2, A3, A6, A7 applied in that order (SHA-256
`a9a1daa0b8b6fcfae7abd78a7688365744089276032efbce772b8a0a0a5046dd`, equal to
the round-4 reviewer's own computation). Applying B1–B9 in order to that body
gives the final draft (SHA-256 `c256b771513d1b6aa0beb9f799afcf198d30afb9115a631d576d7df7993c56a2`). Each entry names the provider
behaviour that forces it and the erlexec 2.6.0 source lines (local pinned copy
of the Hex package), so the main coordinator can judge each change as a
deliberate reviewed amendment, not a silent weakening. Nothing is applied to
#46 until the main coordinator decides.

### B1 — stage is the provider-reported ending signal; `none` removed; masked stops are `unknown`

Replace this exact substring:

```text
`terminated{stage: none | term | kill, deadline}` (`none` only when a reliable observation establishes that the original group is empty before any termination signal; `none` does not claim signal delivery)
```

with:

```text
`terminated{stage: term | kill, deadline}` (`stage` is the ending signal the selected provider reports for the group leader after a termination it performed: `term` for SIGTERM, `kill` for SIGKILL; it is never derived from timing or from the Adapter's own requests; when the provider reports no signal for a termination it performed, the result is `unknown`, never `terminated`)
```

**Provider behaviour that forces it:** erlexec reports the leader's wait status in `{exit_status, Status}` and `exec:status/1` decodes `{signal, sigterm|sigkill, _}`; after `exec:stop/1` and after a linked owner's death the status is masked to `normal`, so no signal is reported on those paths. With this provider the Adapter sends no signal, so a `none` observation before any signal cannot occur: a group empty at the deadline means the leader has exited (`completed`).

**Source:** `c_src/exec_impl.cpp` 1512–1521 (`PidStatusT ps(… (sigterm && !timed_out) ? 0 …)`), `src/exec.erl` 1368–1374 (`{'DOWN', OsPid, {exit_status, Status}}` → `normal` for 0)

**Residual left by this sentence:** a termination the provider performed on request or on owner death has no observable ending signal; such runs are `unknown`, so a caller cannot distinguish a stopped-by-TERM from a stopped-by-KILL cancellation.


### B2 — `unknown` also for provider-masked stops and for a survivor after leader exit

Replace this exact substring:

```text
`unknown` when the liveness check itself fails or the group is still observed alive after the kill stage and the bounded reap wait; `unknown` does not establish cleanup or relax the termination invariant or acceptance criteria
```

with:

```text
`unknown` when the liveness check itself fails, when the group is still observed alive after the provider's termination sequence or after the leader's exit and the bounded reap wait, when the provider performed a termination (explicit stop or owner death) and reports no ending signal, or when the provider's port program stopped reporting; `unknown` does not establish cleanup or relax the termination invariant or acceptance criteria
```

**Provider behaviour that forces it:** erlexec sends one SIGTERM to the group when the leader exits and does not escalate for members that ignore it; its stop masks the status; its port program death yields `port_closed`.

**Source:** `c_src/exec_impl.cpp` 1524–1525 (at-exit `erl_exec_kill(-(gid), SIGTERM)`), 1512–1521 (masking), `src/exec.erl` 1385–1387 (`port_closed`)

**Residual left by this sentence:** a member that ignores SIGTERM after the leader has exited is not killed by anyone; a stuck or dead port program leaves children; both are reported, not resolved.


### B3 — invariants follow the provider's documented sequence; the Adapter never signals

Replace this exact substring:

```text
termination signals the group,
   waits the grace period and escalates only if the group is still alive; the
   escalation stage reached is reported, never assumed; cleanup runs even if
   the owning BEAM process dies; a process that leaves its group is a
   declared residual.
```

with:

```text
termination is performed by the selected provider's port program in its documented sequence: SIGTERM to the group, then SIGKILL to the group after the configured kill timeout if the leader is still alive, and SIGKILL at once if the SIGTERM request itself fails; the Adapter itself never sends a signal; the stage reported is the ending signal the provider reports, otherwise the result is `unknown`; when the owning BEAM process dies, the provider's port program stops the group through the link it holds to that process, and when the VM exits, the port program's own finalize stops every child it started; a process that leaves its group, a group member that ignores SIGTERM after the leader has exited, and the death of the port program itself are declared residuals reported as `unknown`, never as `terminated` or `completed`.
```

**Provider behaviour that forces it:** erlexec `stop_child` sends SIGTERM to `-gid`, arms `kill_timeout`, and on a failed SIGTERM request sends SIGKILL immediately (no grace, no liveness observation on that path); `check_children` escalates after the deadline when `kill(pid, 0)` still succeeds; `do_unlink_ospid` stops the group when a linked owner dies; `finalize()` stops every child on port-program stdin EOF, bounded by `FINALIZE_DEADLINE_SEC` and an `alarm`; SIGKILL of the port program leaves children.

**Source:** `c_src/exec_impl.cpp` 1370–1392 (`stop_child`), 1618–1632 (`check_children` deadline), `src/exec.erl` 1481–1495 (`do_unlink_ospid`), `c_src/exec.cpp` 952–990 (`finalize`)

**Residual left by this sentence:** the provider sends SIGKILL at once when its SIGTERM request fails (no grace on that path); its post-exit SIGTERM is sent after the leader was reaped, so PGID reuse before that signal is not excluded; port-program death orphans children.


### B4 — reuse check names the probed providers

Replace this exact substring:

```text
OTP `Port` and `System.cmd` spawn; no maintained library
   owns group-scoped termination with staged escalation across BSD and procps
   `kill` variants. Elzoo owns the state machine and result schema; signal
   delivery is OS behaviour.
```

with:

```text
erlexec 2.6.0 (BSD-2-Clause) owns spawning through its port program, process-group creation (`{group, 0}`), the staged SIGTERM→SIGKILL escalation on the group (`kill_group`, `kill_timeout`), the wall-clock deadline (`timeout`), owner-death and VM-exit cleanup, environment clearing and output capture; muontrap 2.0.1 was probed and rejected (it kills only its direct child unless a Linux cgroup is configured and reports no ending signal). Elzoo owns admission, the deadline conversion, the output bound, the group observation after the exit notification, the result schema and the delivery mapping; signal delivery and escalation timing are the provider's and the OS's behaviour.
```

**Provider behaviour that forces it:** probe record ELZ-029-provider-probe.md (M2, M3, E1–E16).

**Source:** `src/exec.erl` option docs 300–345; `c_src/muontrap.c` `kill_child_nicely` 629–647

**Residual left by this sentence:** none (specification of the reuse decision).


### B5 — exec failure after validation is a declared residual in the result mapping

Replace this exact substring:

```text
mapped to the
   core/envelope result matrix as `completed` (any exit code) →
   `completed/dispatched`,
```

with:

```text
mapped to the
   core/envelope result matrix as `completed` (any exit code) →
   `completed/dispatched` (pre-dispatch validation requires an absolute path to an existing regular file with an execute bit and an existing working directory, otherwise `rejected{spawn_failed}`; an exec failure that occurs after that validation is reported by the provider as exit status 1 and therefore as `completed{exit_code: 1}`, indistinguishable from a command that exits 1: a declared residual),
```

**Provider behaviour that forces it:** erlexec's child exits 1 when `execve` fails; the owner sees `{exit_status, 256}` for a missing file, a non-executable file and a genuine `exit 1` alike (probe E11, E11b).

**Source:** `c_src/exec_impl.cpp` 1236–1245 (`execve` failure path)

**Residual left by this sentence:** an exec failure after validation (file replaced or removed, loader or interpreter error) is reported as `completed{exit_code: 1}` although nothing ran.


### B6 — dangerous-path tests include the provider controls

Replace this exact substring:

```text
Tests: timeout → group dead; brutal
   kill of the collector → group dead; escalation stage reported;
   `queue_full` vs `queue_timeout`; non-zero exit is `completed`.
```

with:

```text
Tests: timeout → group observed empty; brutal
   kill of the collector → group observed empty through the provider's owner-death stop; escalation stage reported from the provider's ending signal (SIGTERM honoured → `term`, SIGTERM ignored → `kill`); a signal request accepted without effect (SIGTERM ignored) never yields `term`; a member that ignores SIGTERM after the leader exits → `unknown`; exec failure after validation → `completed{exit_code: 1}`; provider stopped reporting → `unknown`; `queue_full` vs `queue_timeout`; non-zero exit is `completed`.
```

**Provider behaviour that forces it:** the controls the reviews asked for (G6 signal success without delivery, TERM-ignoring survivor, exec failure, stuck provider) become named scenarios.

**Source:** —

**Residual left by this sentence:** none (test list).


### B7 — acceptance: cleanup through the provider, observed; stage from the provider's report

Replace this exact substring:

```text
- [ ] Timeout and collector death both leave no surviving process group
      (executable tests on the first fast runner).
- [ ] Escalation stage is reported from observation, not assumed.
```

with:

```text
- [ ] Timeout and collector death both stop the group through the selected provider's port program, and the group is observed empty after the bounded reap wait; a member that ignores SIGTERM after the leader has exited is reported as `unknown`, never as `terminated` or `completed` (executable tests on the Linux CI runner).
- [ ] The reported escalation stage is the provider-reported ending signal; when the provider reports none, the result is `unknown`, never an assumed stage.
```

**Provider behaviour that forces it:** as B1–B3.

**Source:** as B1–B3

**Residual left by this sentence:** the first acceptance item no longer promises an empty group in every case: the TERM-ignoring survivor after leader exit is reported as `unknown`.


### B8 — Needs sentence (A7″ as graded ACCEPTABLE, applied to the intermediate anchor)

Replace this exact substring:

```text
and declared host `kill` and `pgrep` utilities for signalling and group observation.
```

with:

```text
the erlexec 2.6.0 port program (`exec-port`, built from the pinned Hex package with the host C++ toolchain) for spawning, group creation, deadline escalation and owner-death cleanup, and the declared host `pgrep` utility for group observation.
```

**Provider behaviour that forces it:** the Adapter sends no signal, so `kill` is not a Need; the port program and `pgrep` are.

**Source:** —

**Residual left by this sentence:** none (Needs).

### B9 — owner death before registration, owner death after it, Adapter restart (composition record)

Replace this exact substring:

```text
6. **Composition record.** Depends on ELZ-006 admission results and
   core/envelope result schema; consumes a deadline from
   delivery/retry-timeout. Termination requests are at-most-once within a
   host. Command lines may carry secrets; redact in Telemetry.
```

with:

```text
6. **Composition record.** Depends on ELZ-006 admission results and
   core/envelope result schema; consumes a deadline from
   delivery/retry-timeout. Termination requests are at-most-once within a
   host. Command lines may carry secrets; redact in Telemetry. Owner death and recovery: the Adapter records a registry row for a run before it asks the provider to spawn and records the provider's OS pid as the owner's first action after the spawn returns; if the owning BEAM process dies before that pid is recorded, the provider still stops the child through the link it established at spawn, but the Adapter cannot name the group and reports `unknown{owner_exit_before_registration}`; if it dies after, the provider stops the group, the Adapter observes the group with `pgrep` and reports `unknown{owner_exit, members}` with the last observed members, because the provider reports no ending signal on that path; after an Adapter restart, runs whose owner is alive continue and reply to their callers, runs whose owner is dead are reported as above, and queued requests are lost (their callers' calls exit with the Adapter's exit reason); in every `unknown` case the caller must inspect or reconcile the external outcome and must not retry blindly.
```

**Provider behaviour that forces it:** with `link`, erlexec links the proxy to the owner inside the proxy's init and, when the owner dies, the `exec` server sends `{stop, OsPid}` to the port program, whose stop masks the exit status; the Adapter therefore observes emptiness with `pgrep` but no ending signal. The provider's own child list has no caller reference, so replies after a restart need the Adapter's registry.

**Source:** `src/exec.erl` 1341–1349 (`ospid_init` link), 1481–1495 (`do_unlink_ospid`), `c_src/exec_impl.cpp` 1512–1521 (masking).

**Residual left by this sentence:** owner death before the pid is recorded leaves the group unnamed to the Adapter; owner death after it leaves the stage unobservable; a restart loses queued requests.


## B10–B11 — amendments forced by the final diff review (drafts for the main coordinator; NOT applied)

Base for every before-text: the **current live #46 body**, SHA-256
`c256b771513d1b6aa0beb9f799afcf198d30afb9115a631d576d7df7993c56a2` (A1–A7 and
B1–B9 applied). Each before-text occurs exactly once. Applying B10.1–B10.6 and
B11 in this order gives SHA-256 `c2c4b26947e2763d4ff771faf9ab23c2162fa46aa94258b85358d7b105e86ce8`.

**Unreachable rows with erlexec 2.6.0 (stated plainly):** `terminated` is never
produced. Therefore the A2 mapping row (`terminated` on deadline →
`timed_out/dispatched`) and the A3 mapping row (`terminated` on cancellation,
caller death or collector death → `failed/dispatched`) are unreachable; their
text stays for a provider that reports who sent a signal, and B10.3/B10.4 mark
them unreachable. Every deadline termination maps to `unknown/dispatched` via
`unknown{signal_after_deadline}`; cancellation and owner death map to
`unknown/dispatched` via `unknown{provider_masked_stop}` / `unknown{owner_exit}`.

**Residual of B10:** a caller cannot tell a deadline termination from a command
that signalled itself (or was signalled by another actor) after its deadline;
it receives `unknown/dispatched`, not `timed_out/dispatched`, and must inspect
or reconcile. **Residual of B11:** children run as `provider_user` when the VM
is root; file permissions must allow that user; the VM's `SHELL` is set when
unset; a consumer's own erlexec configuration is kept as is.

Provider facts behind them (erlexec 2.6.0): the exit report is
`{exit_status, Status}` with no cause field (`src/exec.erl` 1368–1374;
`c_src/exec_impl.cpp` 1512–1521 only masks, it does not report who stopped);
the port program exits with "Not allowed to run as root without setting
effective user (-user option)!" and also exits when `SHELL` is unset
(`c_src/exec.cpp` 784–795); `root` and `user` are read from the `erlexec`
application environment (`src/exec_app.erl` 76–80, `src/exec.erl` 979–988).

### B10.1

Replace this exact substring:

```text
when the provider reports no signal for a termination it performed, the result is `unknown`, never `terminated`)
```

with:

```text
when the provider reports no signal for a termination it performed, the result is `unknown`, never `terminated`; the selected provider erlexec 2.6.0 reports the leader's ending signal but not who sent it, so a SIGTERM or SIGKILL reported at or after the deadline instant (taken before the spawn request) is `unknown{signal_after_deadline, signal}` and one reported before that instant is `completed{exit_code: 128 + signal}`: with erlexec 2.6.0 `terminated` is never produced)
```

### B10.2

Replace this exact substring:

```text
or when the provider's port program stopped reporting;
```

with:

```text
when a SIGTERM or SIGKILL is reported at or after the deadline instant (`signal_after_deadline`, carrying the reported signal as an observation, not a stage), or when the provider's port program stopped reporting;
```

### B10.3

Replace this exact substring:

```text
`terminated` on deadline → `timed_out/dispatched`, paired with the Adapter result carrying the observed stage; the shared delivery-result map remains unchanged and has no stage field;
```

with:

```text
`terminated` on deadline → `timed_out/dispatched`, paired with the Adapter result carrying the observed stage; the shared delivery-result map remains unchanged and has no stage field (this row is unreachable with erlexec 2.6.0: a deadline outcome is `unknown{signal_after_deadline}` → `unknown/dispatched`);
```

### B10.4

Replace this exact substring:

```text
`terminated` on explicit cancellation, caller death or death of the collecting BEAM process → `failed/dispatched`, paired with the Adapter result carrying the observed stage;
```

with:

```text
`terminated` on explicit cancellation, caller death or death of the collecting BEAM process → `failed/dispatched`, paired with the Adapter result carrying the observed stage (this row is unreachable with erlexec 2.6.0, whose stop reports no ending signal: `unknown{provider_masked_stop}` or `unknown{owner_exit}` → `unknown/dispatched`);
```

### B10.5

Replace this exact substring:

```text
the stage reported is the ending signal the provider reports, otherwise the result is `unknown`;
```

with:

```text
the stage reported is the ending signal the provider reports for a termination it can be shown to have performed, otherwise the result is `unknown` (with erlexec 2.6.0 no stage is ever reported);
```

### B10.6

Replace this exact substring:

```text
- [ ] The reported escalation stage is the provider-reported ending signal; when the provider reports none, the result is `unknown`, never an assumed stage.
```

with:

```text
- [ ] The reported escalation stage is the provider-reported ending signal for a termination the provider can be shown to have performed; when the provider reports none, or reports a SIGTERM or SIGKILL at or after the deadline instant that it cannot be shown to have sent, the result is `unknown`, never an assumed stage; with erlexec 2.6.0 every deadline termination is therefore `unknown{signal_after_deadline}` carrying the reported signal.
```

### B11

Replace this exact substring:

```text
and the declared host `pgrep` utility for group observation.
```

with:

```text
the declared host `pgrep` and `id` utilities for group observation and for detecting a root VM, and, when the VM's effective user is root and the consumer has not configured erlexec's `root`/`user` settings, erlexec started with `root: true` and the unprivileged effective user `provider_user` (Config, default `nobody`), with `SHELL=/bin/sh` set for the VM when `SHELL` is unset, because the port program refuses to run as root without an effective user and requires `SHELL`; a consumer that already configured or started erlexec keeps its configuration; residual: the port program and every child then run as that user and need read and execute permission on the executable, the working directory and every file they use, and the VM's `SHELL` is changed when it was unset.
```
