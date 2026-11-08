# runtime/os-isolation

`Elzoo.OsProcess` runs one external OS command per request with bounded
concurrency, an absolute deadline and group-scoped termination. The command is
spawned, grouped, timed, signalled and reaped by **erlexec 2.6.0**'s port
program (BSD-2-Clause); Elzoo owns admission, the bounded queue, the deadline
conversion, the output bound, the group observation and the result schema.
**The Adapter never sends a signal itself.** Apache-2.0 for the Elzoo source.

Not security isolation: no sandbox, container, seccomp, path confinement or
network isolation. No shell parsing: the executable path and arguments are
passed as `argv`. Caller composition: supervise the instance in your own tree
(`runtime/supervision`), declare the Effect at your boundary (`core/effect`);
the `integration/agent-runner` task records the exact Claude Code CLI and
Codex CLI versions that run behind this boundary.

## Interface

```elixir
{:ok, sup} = Elzoo.OsProcess.start_link(max_concurrent: 2, queue_limit: 4, queue_timeout_ms: 5_000)
{:ok, ref} = Elzoo.OsProcess.submit(sup, %{executable: "/bin/sh", args: ["-c", "echo hi"],
                                             cwd: nil, env: %{inherit: ["HOME"], set: [{"KEEP", "yes"}]}},
                                   deadline_unix_ms: System.os_time(:millisecond) + 10_000)
receive do {Elzoo.OsProcess, ^ref, result} -> result end
{:ok, result} = Elzoo.OsProcess.run(sup, spec, max_run_ms: 5_000)          # submit + await (bound derived from the request)
{:ok, :requested} = Elzoo.OsProcess.cancel(sup, ref)                        # acceptance, not application
%{status: _, os_pid: _, owner: _} = Elzoo.OsProcess.info(sup, ref)
{:ok, delivery_result, result} = Elzoo.OsProcess.to_delivery_result(result, %{"message_id" => "m"})
```

Needs: the `erlexec` application started (a dependency application; its port
program is built from the pinned Hex package with the host C++ toolchain and
found through `:code.priv_dir(:erlexec)`), the host `pgrep` utility, the
executable path and version declared by the caller, a working directory and an
explicit environment allowlist. The child's environment is `set` plus the
`inherit` names present in the VM environment; everything else is unset. The
child's stdin is `/dev/null`. stdout and stderr are merged into `output` in
arrival order, bounded by `max_output_bytes` (`truncated: true` beyond it).

`run/3` waits `queue_timeout_ms + run limit + grace + observation + 5 s`
(`bounds/1` exposes the instance values); a shorter `await_ms` ends the wait
early, cancels the run (acceptance only) and returns `{:error, {:no_result,
ref}}`; the late result message still arrives. `cancel/2` returns
`{:ok, :requested}` once and `{:ok, :already_requested}` for a repeated cancel
of a running run. A queued run is settled at once by its cancellation
(`rejected{cancelled}`); a repeated cancel of one of the last 1024 refs so
settled answers `{:ok, :already_requested}` (it acknowledges the duplicate
request, not a run that is still alive). Every other finished or foreign ref
gets `{:error, :unknown_run}`. A slot stands for a running OS command: after an owner death it is
released only when the Adapter has observed the group empty or the observation
bound passed, so `max_concurrent` holds during the provider's grace; the
registry row of such a run stays (marked as observing) until that observation
ends, so a restarted Adapter still counts the slot and does not notify twice.

Config (construction, no hot update): `max_concurrent`, `queue_limit`,
`queue_timeout_ms`, `grace_s` (provider wait between SIGTERM and SIGKILL,
default 2), `observe_timeout_ms` (default 3000), `max_output_bytes` (default
1 MiB), `pgrep_path`, `now_unix_ms`, `name`. Per call: `deadline_unix_ms`
and/or `max_run_ms` (at least one; the earlier wins), `cwd`, `env`, `request`
(`message_id`, `correlation_id`, `attempt_id` echoed into the delivery result).

## Deadline

The absolute deadline is converted once at admission to a monotonic target.
A request whose deadline has passed is `expired`. In the queue, the timer is
`min(queue_timeout_ms, time to target)`; firing at or after the target gives
`expired`, before it `rejected{queue_timeout}`. At dispatch the remaining time
(capped by `max_run_ms`) is handed to the provider as its wall-clock watchdog,
so queue residence can only shorten a run, never restart its deadline.

## Results (Adapter result, atom keys)

| status | fields | when |
| --- | --- | --- |
| `completed` | `exit_code` (0..255, `128 + signal` for a self-ended child), `output`, `truncated`, `leftovers: :none \| :reaped`, `os_pid` | the leader exited and the group was observed empty afterwards |
| `rejected` | `reason: :queue_full \| :queue_timeout \| :spawn_failed \| :cancelled` | nothing was dispatched |
| `expired` | `deadline_unix_ms` | the deadline passed before dispatch |
| `terminated` | `cause: :deadline`, `stage: :term \| :kill`, `signal: :sigterm \| :sigkill`, `exit_code: nil`, `output`, `truncated`, `os_pid` | the provider's watchdog ended the leader and reported the ending signal; the group was observed empty |
| `unknown` | `reason`, `cause`, `os_pid`, `members`, `output`, `truncated`, `exit_code` | see below |

`stage` is the ending signal the provider reports (`term` = SIGTERM, `kill` =
SIGKILL). It is never derived from a request the Adapter made. A SIGTERM or
SIGKILL status reported before the deadline instant cannot be the provider's
and is `completed{exit_code: 128 + signal}`; one reported at or after that
instant is attributed to the provider's watchdog, which is indistinguishable
from a command that signals itself after its deadline (declared residual).
`unknown` reasons: `provider_masked_stop` (an explicit `cancel/2` or the
submitter's death made the provider stop the group; erlexec masks the ending
signal on that path, so a caller that needs a distinguished cancel outcome must
observe the group itself), `owner_exit` / `owner_exit_before_registration`
(the owning BEAM process died; the provider stopped the group through its
link; the Adapter observed `members`), `group_alive` (members still listed at
the observation bound, including a member that ignores SIGTERM after the
leader exited), `observation_failed` (`pgrep` failed twice),
`no_exit_notification` (the provider did not report within deadline + grace +
observation), `port_closed` (the provider's port program died; the child is
orphaned and its `members` are reported). `unknown` never establishes cleanup:
inspect or reconcile; do not retry blindly.

Pre-dispatch validation: absolute path to an existing regular file with an
execute bit, and an existing `cwd`; otherwise `rejected{spawn_failed}`. An exec
failure after that validation (file replaced, loader or interpreter error) is
reported by the provider as exit status 1 and appears as
`completed{exit_code: 1}`: a declared residual.

## Delivery mapping (core/envelope)

`to_delivery_result/2` returns `{:ok, map, result}`: the map is an exact
version-1 delivery result validated by `Elzoo.Envelope.validate_result/1`; the
Adapter result is the paired sidecar carrying stage and members.

| Adapter result | outcome / dispatch | error_class or value |
| --- | --- | --- |
| `completed` | completed / dispatched | `value` `%{"exit_code", "output", "truncated"}`, schema `elzoo/os-process-completed` v1 |
| `rejected{queue_full \| queue_timeout}` | rejected / not_dispatched | `unavailable` |
| `rejected{spawn_failed \| cancelled}` | rejected / not_dispatched | `permanent` |
| `expired` | timed_out / not_dispatched | `unclassified` |
| `terminated` | timed_out / dispatched | `unclassified` |
| `unknown` | unknown / dispatched | `unclassified` |

## Processes

One supervisor per instance owns an ETS registry of runs (`ref → owner,
submitter, os_pid, status`), a `DynamicSupervisor` of owners and the Adapter
GenServer. The Adapter admits (slots by `Elzoo.Backpressure`, zero-queue
counter; the FIFO is Adapter policy), queues and dispatches. Each run has one
owner GenServer that writes its registry row, calls `exec:run` with
`[{group, 0}, kill_group, link, stdout, stderr, {timeout, remaining},
{kill_timeout, grace_s}, {env, [clear | allowlist]}, {cd, cwd}]`, monitors the
provider proxy, accumulates output, observes the group with `pgrep -g` after
the exit notification and replies to the submitter itself. With `link`, erlexec
produces no synthetic `'DOWN'`; the proxy's exit reason (`normal`,
`{exit_status, S}`, `port_closed`) arrives through the link and the monitor
after all output messages. If an owner dies, the provider stops the group
through the link and the Adapter reports `unknown{owner_exit}` after its own
observation; if the Adapter dies, running owners finish and reply, queued
callers' calls exit, and the restarted Adapter rebuilds its slots from the
registry. If the VM exits, the port program's `finalize` stops every child.

## Transition table and tests

| Row | Transition | Caller receives |
| --- | --- | --- |
| T1 | malformed spec or option | `{:error, {:invalid_spec, field}}` |
| T2/T8 | deadline passed at admission or dispatch | `expired` |
| T3/T4/T5 | queue full / queue timer / deadline while queued | `rejected{queue_full}` / `rejected{queue_timeout}` / `expired` |
| T6/T7 | submitter dies queued / cancel queued | dropped / `rejected{cancelled}` |
| T9 | validation fails | `rejected{spawn_failed}` |
| T11/T12/T13 | leader exits: no members / members reaped by the provider's at-exit TERM / members survive the bound | `completed{leftovers: :none}` / `completed{leftovers: :reaped}` / `unknown{group_alive}` |
| T14/T15/T16 | deadline: SIGTERM honoured / ignored / with a member | `terminated{stage: :term}` / `terminated{stage: :kill}` / `terminated` |
| T17/T18/T19 | cancel / duplicate cancel / submitter dies running | `unknown{provider_masked_stop}` / `{:ok, :already_requested}` / dropped |
| T20 | provider stops reporting | `unknown{no_exit_notification}` |
| T21a/T21b | owner dies before / after `os_pid` is recorded | `unknown{owner_exit_before_registration}` / `unknown{owner_exit}` |
| T22/T23 | Adapter dies / Adapter and owner die | result still delivered, slots rebuilt / group stopped by the provider |
| T24/T25 | provider application stops / port program killed | group stopped / `unknown{port_closed, members}` |
| T26 | `pgrep` fails | `unknown{observation_failed}` |
| T27/T28 | output bound / environment allowlist and cwd | `truncated: true` / only allowlisted names |
| T29 | descendant leaves the group | residual: alive, not a member |
| C1/C2/C3 | SIGTERM ignored / observation tool lies / natural exit in grace | `stage: :kill` / Adapter reports its observation / `completed` |

Grounding: tests over the rows above with real `/bin/sh` processes and the
fixture `test/elzoo/os_process_fixture.sh`; group emptiness asserted by the
test's own `pgrep -g`; the delivery rows validated by
`Elzoo.Envelope.validate_result/1`. Upstream: erlexec 2.6.0 documented
options and the pinned observations named in `piece.json`; Elixir/OTP process
semantics. No Cure proof is claimed. Observations are finite and taken on
macOS and Ubuntu; no cross-platform or universal-cleanup claim.
