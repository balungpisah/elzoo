Redacted for publication; SHA-256 of the reviewer's original report: e1d4e9c6f82d1453548509e5119181a929198fb8e212b2b80481358e11095785 (no identifier needed redaction)

# ELZ-029 final diff review

Reviewer: the independent reviewer (Codex), final diff review

Reviewed revision: `b08ebd9f62999390802283e4fe6e39efc22a2f9c`  
Base revision: `e62ce1843836f7ed1fd3587ba54b0355b25dccc5`  
Recorded checked revision: `683dfa1ae4f3142a6b6edcff6fef19e80c668499` is an ancestor, not the reviewed head.

## Commands

| Command | Exit | Result |
| --- | ---: | --- |
| `git fetch origin --prune` | 0 | Reviewed refs resolved to the revisions above. |
| `git diff origin/main...origin/task/ELZ-029` and read-only `git show` inspection | 0 | 31 changed paths reviewed, including the committed ELZ-029 records and implementation. |
| `git diff --check origin/main...origin/task/ELZ-029` | 0 | No whitespace error. |
| `gh pr view 120 --json body,files,comments` | 0 | No PR comments; the body retains a generated-platform footer and review badge. |
| `gh pr checks 120` | 1 | `check-fast` failed, `gleam` passed, `check-any` skipped, and Devin Review reported passed. |
| `gh issue view 46 --json body` with byte/hash comparison | 0 | `tasks/ELZ-029-os-process-adapter.md` is byte-equal to live #46: `c256b771513d1b6aa0beb9f799afcf198d30afb9115a631d576d7df7993c56a2`. |
| `python3 scripts/check-roadmap.py` | 0 | Passed. |
| `python3 scripts/check-roadmap.py --live` | 1 | Live mismatch reported for ELZ-027, not the stated expected ELZ-028 row. |
| `python3 scripts/check-claims.py` | 0 | No tracked claim metadata. |

No `mix` command was run by the independent reviewer.

## Findings

### BLOCKING

1. `pieces/runtime/os-isolation/lib/elzoo/os_process/owner.ex` classifies a SIGTERM or SIGKILL reported at or after `dispatched_at + timeout_ms` as `terminated` solely from elapsed time. The live #46 B1 Contract says stage is never derived from timing and requires the provider to have performed the termination; `pieces/runtime/os-isolation/README.md` now admits that a self-signalled command after the instant is indistinguishable. Return `unknown` for that ambiguity or amend the live Contract before asserting `terminated`; the current F4 test only covers a self-signal before the deadline.

2. A cancel or submitter-death race before `os_pid` registration is not safe. `pieces/runtime/os-isolation/lib/elzoo/os_process/owner.ex` accepts cancel with `os_pid: nil`, attempts `exec:stop(nil)`, marks cancellation, then continues to `exec:run`; no later stop is issued for the newly spawned group. The same gap exists for submitter death, so an accepted cancel can dispatch and finish `completed`, contrary to the required provider stop and `unknown{provider_masked_stop}` outcome; no transition test covers this race.

3. Current-head CI is red. `check-fast` on `b08ebd9f62999390802283e4fe6e39efc22a2f9c` fails at `mix check` because erlexec's `exec-port` refuses the root job container without an effective-user option, so the required Linux real-process checks do not run. The recorded green full check is only `683dfa1ae4f3142a6b6edcff6fef19e80c668499`; the head subsequently changes Adapter, Owner, public API, manifest, README, release-plan metadata, and tests.

4. The PR body violates the stated public-repository rule: it contains a generated-platform footer and a Devin Review badge. Remove both before merge.

### REQUIRED

1. The promised T1–T30 coverage is incomplete. No test exercises T10 (`exec:run` returning an error before fork), T30 (late timer or DOWN ignored after settlement), or the distinct T8 dispatch-time deadline race; T2/T8 only tests an already-expired admission deadline.

2. The PR evidence is stale at the reviewed revision. The committed executed record and PR body report 40 Piece tests and the 32/682 full-check counts at `683dfa1ae4f3142a6b6edcff6fef19e80c668499`, while the current sources contain 44 Piece tests and substantive post-check changes. Rerun the named targeted, copied-consumer, and full checks on the exact head after resolving CI; correct the PR evidence rather than describing the later source commit as documentation-only.

3. Devin Review findings are not listed with dispositions. The PR body says `pending`, has no disposition section, and `gh pr view` reports no comments; the F1–F5 labels in the source are not a PR finding/disposition record.

### LOW

1. `pieces/runtime/os-isolation/lib/elzoo/os_process/result.ex` permits `cwd: nil`, which inherits the Adapter process working directory. Clarify that inherited directory as a declared Need or require the caller-supplied existing `cwd` named by #46.

2. The T24 test permits `:no_result` after provider application stop. A stricter asserted outcome or an explicit Contract limit would keep the advertised result vocabulary honest on that provider-loss path.

## Gate review

| Gate | Result | Review basis |
| --- | --- | --- |
| G1 Contract and amendment alignment | FAIL | B1 stage attribution contradicts the unchanged live B1 sentence. |
| G2 ownership, handoff, bounded observation | FAIL | Pre-registration cancel/caller-death race can dispatch without a valid provider stop request. |
| G3 authorized scope and protected paths | PASS | Diff changes no workflow, script, root test, or other protected path; shared pin and metadata paths are task-scoped. |
| G4 reuse and declared Needs | PARTIAL | erlexec 2.6.0, port program, pgrep, executable, and allowlist are declared; optional inherited cwd remains ambiguous and CI cannot start the provider. |
| G5 outcomes, mapping, and races | FAIL | B1 timing inference and missing T8/T10/T30 evidence. |
| G6 Linux dangerous-path evidence | FAIL | Current Linux `check-fast` fails before the real-process suite. |
| G7 operational declarations and grounding | PARTIAL | Telemetry, Config, and Control are declared with test references, but current-head evidence and Devin dispositions are incomplete. |
| G8 exact-head setup/check and independent review | FAIL | Only the ancestor has a recorded full check; the reviewed head has a failed check. |

## Shared-path review

| Path or group | Result | Review basis |
| --- | --- | --- |
| `mix.exs`, `mix.lock` | PASS | Only `{:erlexec, "== 2.6.0"}` and one erlexec lock entry were added. |
| `registry/providers.json`, `docs/dependencies.md` | PASS | Hex erlexec 2.6.0, BSD-2-Clause, reference, and retained-notice location are recorded. |
| `registry/catalogue.json`, `docs/plans/release-plan.json`, `LEDGER.md`, `docs/plans/views.md` | PASS | Only the runtime/os-isolation readiness path changed; manifest path and `36f4f72bd958a4407f78509112cbcd83ed12adf5f016a5b6ac5ba2563a012c68` match the committed manifest, and the job hash matches live #46. |
| `docs/work/ELZ-050-records/records_part1.py`, `docs/plans/catalogue-dispositions.md`, `docs/work/ELZ-050-evidence/coverage-check.json`, `docs/work/ELZ-050-evidence/hex-reverify.json` | PASS | erlexec is ADOPTED, muontrap is REJECTED, and the regenerated coverage record is internally consistent. |
| `tasks/ELZ-029-os-process-adapter.md` | PASS | Byte-equal to live #46 at `c256b771513d1b6aa0beb9f799afcf198d30afb9115a631d576d7df7993c56a2`. |
| PR body | FAIL | Footer, badge, stale exact-head evidence, and missing Devin dispositions. |

## Grounding limits

The structural design uses one owner per run under a DynamicSupervisor, a supervisor-owned ETS registry written before `exec:run`, provider `link`, proxy monitor handling, pgrep-only observation, and post-observation replies; these aspects match the intended design on inspection. Finite tests remain tests, not proofs; current CI failure and absent exact-head full-check evidence prevent relying on the recorded test counts.

NOT CLEAR — repair the stage and pre-registration cancellation violations, make erlexec run on the approved Linux CI environment, add the missing transition/race tests, rerun and record exact-head evidence, remove the PR footer and badge, and list Devin findings with dispositions.
