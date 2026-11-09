# ELZ-029 — provider probe: muontrap 2.0.1, then erlexec 2.6.0

Ordered by the main coordinator (2026-11-08): exercise muontrap first, then
erlexec, against the four process-ownership points; a hand-written `/bin/sh`
wrapper only if both are unfit. This record is **probe evidence on one host**
(the implementation worker's macOS arm64 machine, Elixir 1.20.4, OTP 29.1.2), not implementation acceptance.
Scratch Mix project in the implementation worker's scratch directory outside the
repository (not committed); targeted `mix test` only;
no `mix check`; host load observed before each run (3.4–6.9, never above 8
during a run; 8.47 was observed once right after `mix deps.compile`, and no
test was started until it fell). Logs: `muontrap_probe2.log`,
`erlexec_probe.log`, `erlexec_probe2.log` kept in that scratch directory; the
`PROBE` lines below are copied from them.

## Versions and licenses (Hex, read 2026-11-08)

| Package | Version | License | Build | Transitive |
| --- | --- | --- | --- | --- |
| muontrap | 2.0.1 | Apache-2.0 | `elixir_make` 0.10.1 compiles `c_src/muontrap.c` (needs a C compiler and `make`) | elixir_make |
| erlexec | 2.6.0 | BSD-2-Clause | rebar3 `make` compiles `c_src/*.cpp` to `priv/<arch>/exec-port` (needs a C++ compiler and `make`) | none |

## What each library defines (from source, pinned versions)

### muontrap 2.0.1

- **Spawn:** `Port.open({:spawn_executable, priv/muontrap}, [:exit_status, …, args: ["--capture-output" … "--", cmd | args]])`; the binary `fork()`s the command and `execvp`s it (`c_src/muontrap.c` `fork_exec`). The child inherits the binary's process group (the group OTP's `erl_child_setup` created for the binary); muontrap itself calls neither `setsid` nor `setpgid`.
- **Cleanup:** on `POLLHUP` of its stdin (Erlang closed the Port: timeout, owner death, VM death) the binary runs `kill_child_nicely(child)`: SIGTERM to the **direct child pid**, wait `--delay-to-sigkill` (default 500 ms) for SIGCHLD, then SIGKILL to the direct child. Descendants are killed only when a cgroup v2 path is configured (`cleanup_all_children` iterates `cgroup.procs`, Linux only, requires a writable delegated cgroup).
- **Port ownership:** `MuonTrap.cmd/3` opens the Port in the caller; `MuonTrap.Daemon` is a GenServer owning it; both rely on the binary's stdin-HUP watchdog.
- **Result:** `{output, exit_status | :timeout}`; `:timeout` after `Port.close`; the signal that ended the child is not reported (`128 + signal` only for a child that died on its own, M5).

### erlexec 2.6.0

- **Spawn:** one `exec-port` C++ program per VM (owned by the `exec` GenServer of the `erlexec` application) forks and `execve`s each command; the child pid is registered in the port program's own table before `exec:run/2` returns `{ok, ProxyPid, OsPid}` (`c_src/exec.cpp` case `RUN`). `{group, 0}` puts the child in a new process group equal to its pid; `kill_group` makes every stop/kill target `-gid`.
- **Deadline:** `{timeout, Ms}` is a wall-clock watchdog **inside the port program** from spawn: SIGTERM to `-gid`, then SIGKILL to `-gid` after `{kill_timeout, Sec}` if `kill(pid, 0)` still succeeds (`exec_impl.cpp` `stop_child`, `check_children`). A timeout kill is reported with the real wait status (`timed_out` flag prevents masking).
- **Owner death:** a **linked** owner (`link` option / `run_link`) that dies makes the `exec` server send `{stop, OsPid}` → staged `-gid` termination (`do_unlink_ospid`). A monitor-only owner's death does nothing (E13).
- **Port program death / VM death:** on stdin EOF the port program runs `finalize()`: `stop_child` for every registered child (TERM, then KILL after `kill_timeout`), bounded by `FINALIZE_DEADLINE_SEC` and an `alarm`. SIGKILL of `exec-port` itself leaves children (E16).
- **Exit report:** `{'DOWN', OsPid, process, ProxyPid, normal | {exit_status, Status}}`; `exec:status/1` decodes `{status, N}` or `{signal, Name, Core}`. **`exec:stop/1` masks the status to `normal`** (`PidStatusT ps(…, sigterm && !timed_out ? 0 : …)`); the watchdog timeout does not mask.
- **At-exit group kill:** when the leader exits, one SIGTERM to `-gid` (`check_children`); no KILL escalation for leftover members after the leader is gone.
- **Signals from Erlang:** `exec:kill(OsPid, Sig)` targets the pid only; negative pids are refused (`"Not allowed to send signal to all processes"`, E9).
- **Environment:** `{env, [clear | {Name, Value} | …]}`; `clear` empties the inherited environment (E10). `{cd, Dir}`; `stdout`/`stderr` capture as `{stdout | stderr, OsPid, Data}` messages to the owner.
- **Exec failure:** `execve` failure in the child exits 1 and is reported as `{exit_status, 256}` (E11b), indistinguishable from a command that exits 1.

## Probe scenarios and outputs

Helpers: `pgrep -g PGID` (members), `pgrep -P PID` (children), `ps -o pgid=`.
"group empty" = `pgrep -g` exit 1.

### muontrap (`test/muontrap_probe_test.exs`, 5 passed, 0.7 s)

| ID | Scenario | Output (PROBE lines) | Reading |
| --- | --- | --- | --- |
| M1 | `sh -c 'echo hello; echo err 1>&2; exit 7'`, `stderr_to_stdout` | `{"hello\nerr\n", 7}` | exit code and merged output ✓ |
| M2 | `sh -c 'sleep 30 & echo started; wait'`, Port closed by the caller (timeout path) | `muontrap os_pid/pgid: {35409, 35409}`; `children of muontrap (the sh): [35410]`; `grandchildren (sleep): [35411]`; `sh dead within 1500ms: :ok`; `grandchild alive after close: [true]`; `group members after close: {:ok, [35411]}` | direct child killed; **grandchild survives** without cgroup ✗ |
| M3 | `trap '' TERM; sleep 30`, `timeout: 500` | `{"ignoring\n", :timeout}` | no stage information ✗ |
| M4 | `MuonTrap.Daemon` killed with `:kill` | `sh dead within 1500ms: :ok` | owner death → direct child killed by the binary ✓ |
| M5 | child sends itself TERM | `143` | `128 + signal` for a self-ended child ✓ |

### erlexec (`test/erlexec_probe_test.exs` 11/13 passed; `test/erlexec_probe2_test.exs` 6 passed)

Options unless stated: `[{:group, 0}, :kill_group, :monitor, {:kill_timeout, 1}]`.

| ID | Scenario | Output (PROBE lines) | Reading |
| --- | --- | --- | --- |
| E1 | `echo hello; echo err 1>&2; exit 7`, `:stdout, :stderr` | `{"hello\nerr\n", {:exit_status, 1792}}` → `exec:status` `{:status, 7}` | exit code and both streams ✓; leader pgid == os_pid (E2 line) |
| E2 | `sleep 30`, `{:timeout, 400}` | `os_pid/pgid/members: {38406, 38406, {:ok, [38406]}}`; `reason: {:exit_status, 15}` → `{:signal, :sigterm, false}`; `group empty: :ok` | deadline → TERM honoured → **observed sigterm**, group empty ✓ |
| E3 | `trap '' TERM; sleep 30`, `{:timeout, 400}` | `reason: {:exit_status, 9}` → `{:signal, :sigkill, false}`; `elapsed ms: 1508` | TERM ignored → KILL after `kill_timeout` → **observed sigkill** ✓ |
| E4 | `sleep 30 & wait`, `{:timeout, 400}` | `members before: {:ok, [38574, 38576]}`; `reason: {:exit_status, 15}`; `group empty within 2500ms: :ok` | grandchild in the group killed at the deadline ✓ |
| E5a | `sleep 30 >/dev/null 2>&1 & exit 0` | `reason: :normal`; `group empty within 1500ms: :ok` | lingering member reaped by the at-exit group TERM ✓ |
| E5b | inner `sh -c 'trap "" TERM; sleep 30'` lingering | `reason: :normal`; `group empty within 3000ms: :ok`; test asserted the opposite (expected single TERM) → **1 failure, by my expectation** | the member died; whether the inner `trap` took effect is **inconclusive** (see E5c) |
| E5c | inner TERM-ignoring loop | `reason: {:exit_status, 256}`; members empty 300 ms after DOWN | leader exited 1 (quoting?), member absent → **inconclusive**; to be settled by a deterministic test in the Piece |
| E6 | owner spawned with `:link`, killed with `:kill` | `members before: {:ok, [38598, 38600]}`; `group empty within 2500ms: :ok` | linked owner death → group stopped by the port program ✓ |
| E7 | `exec:stop(OsPid)` | `reason after exec:stop: :normal` | **status masked**; stage of a stop is not reported ✗ |
| E8 | `exec:kill(OsPid, 15)` on `sh -c "sleep 30"` | no DOWN in 20 s → **1 failure** | TERM to a waiting `sh` leader only is deferred by the shell; pid-only signals do not terminate a tree |
| E8b | `exec:kill(OsPid, 15)` on `/bin/sleep 30` | `members 300ms after: []`; `reason: {:exit_status, 15}` | pid-only kill works for a leaf; status unmasked ✓; `exec:kill(ErlangPid, 15)` → `{:error, :no_process}` |
| E9 | `exec:kill(-gid, 9)` | `{:error, ~c"Not allowed to send signal to all processes"}` | group signals from Erlang are refused ✗ |
| E10 | `env` with `{:env, [:clear, {"KEEP","yes"}]}` while `ELZ_PROBE_SECRET` set in the VM | `"PWD=…\nKEEP=yes\nSHLVL=1\n_=/usr/bin/env\n"` | inherited environment cleared; allowlist works ✓ (`PWD`/`SHLVL`/`_` come from `sh`/`env`) |
| E11/E11b | missing executable, non-executable file, genuine `exit 1` (monitor and sync) | all `{:exit_status, 256}` / `{:error, [exit_status: 256]}` | exec failure **indistinguishable** from exit 1 ✗ → pre-dispatch validation needed |
| E12 | `Application.stop(:erlexec)` with a running group | `group empty within 3000ms after app stop: :ok` | port program EOF → `finalize` kills children ✓ (VM-death analogue) |
| E13 | owner with `:monitor` only, killed | `group empty within 2500ms (monitor only): :timeout`; member `sleep 30` still alive | monitor-only owner death does **not** stop the process; `:link` is required |
| E15 | `sleep 30 & echo started; exit 0` (member holds stdout) | `ms until DOWN: 5`; `reason: :normal`; `group empty within 2500ms: :ok` | completion is reported on **leader exit** (waitpid), not on pipe EOF ✓; holder reaped by the at-exit TERM |
| E16 | `exec-port` killed with SIGKILL | `members after: ["46013 1 /bin/sleep 30"]`; `DOWN reason: :port_closed` | death of the port program itself orphans children (declared limit, same class as VM death for muontrap/OTP Ports) |

## Fit against the four ownership points

| Point | muontrap 2.0.1 | erlexec 2.6.0 |
| --- | --- | --- |
| 1 Port owner / link / failure handoff | Binary-side stdin watchdog kills the **direct child** on any Port closure (M2, M4); descendants only with a Linux cgroup; no registration gap (the binary forks) | Port program registers the child before `run` returns; linked-owner death → staged group stop (E6); VM/port EOF → `finalize` (E12); monitor-only owners are not protected (E13); `exec-port` SIGKILL is the residual (E16) |
| 2 Original PGID identity, no blind KILL | No process-group handling at all | Group = leader pid (`{group,0}`); every signal is sent by the port program that reaps the leader, immediately after its own liveness check (`kill(pid,0)` each tick); the KILL after `kill_timeout` to `-gid` carries the same inherent check-to-signal gap as any `kill(-pgid)` (upstream behaviour) |
| 3 Stage as observed fact | Not reported (M3) | Deadline: the ending signal is in the exit status (E2 sigterm, E3 sigkill); `exec:stop` and owner-death stops **mask** it (E7) |
| 4 Cleanup owner and bound after `unknown` | Binary until its child dies; descendants unowned without cgroup | Port program: deadline watchdog bounds the child's lifetime even if every BEAM process dies; `finalize` on EOF; leftovers after leader exit get one TERM (E5a); KILL escalation for post-exit leftovers is not provided (E5b/E5c inconclusive) |

**Disposition proposed:** muontrap is **unfit** for the Contract without a
delegated Linux cgroup (no group-scoped termination, no stage). erlexec is
**fit as the provider** for spawn, group, deadline escalation, owner-death and
VM-death cleanup, exit-status observation and environment clearing. Elzoo adds
what it does not define: pre-dispatch executable validation (E11b), bounded
output accumulation, absolute-deadline → remaining-ms conversion, group
observation with `pgrep` after the exit notification, the result schema, the
delivery-result mapping and the honest labels for the two provider gaps
(masked stage on stop; leftovers after leader exit). No `/bin/sh` wrapper, no
`setsid` Need.
