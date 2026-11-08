# ELZ-023 focused amendment probe evidence

> Redacted before publication (ELZ-065): the password part of local test-database URLs (`ecto://user:…@localhost`) and role commands is replaced by an ellipsis; the recorded commands are otherwise exact.

Status: executed feasibility evidence; [independent review](ELZ-023-focused-review.md)
is CONDITIONAL at 82287ca; no production acceptance.
The reviewer reproduced the green checks but found an unsafe history-dependent
replay sequence outside these label laws: after replay-safe rearm, a later
adapter_no_send erases the horizon requirement. Monotone history G1 and root
restart-breadth acknowledgement A1 are required; see the
[decision/gates handoff](ELZ-023-focused-handoff.md).
Root decision R-A–R-F (~08:55 WIB, 2026-11-08) and amendment comment
[6715823301](https://github.com/balungpisah/elzoo/issues/37#issuecomment-6715823301)
are applied in the live/task Contract and [revised proposal](ELZ-023.md).

## Environment and exact commands

Worktree: `/Users/laptopdp/orca/workspaces/elzoo/elzoo-ELZ-023`.
Cure `208248063d64e621782cd26dd30698ee42850a89`, Elixir 1.20.4, OTP 29.1.2.
No dependency/configuration/production files changed since the recorded pinned setup
and full baseline check (32 + 564 passed); these new docs/probes do not claim a
fresh full production check. All final probe commands below exited **0**.

```sh
python3 docs/work/ELZ-023-probes/generate_provenance.py
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test elixir -pa '_build/test/lib/*/ebin' docs/work/ELZ-023-probes/provenance.exs
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test elixir -pa '_build/test/lib/*/ebin' docs/work/ELZ-023-probes/capacity.exs
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test elixir -pa '_build/test/lib/*/ebin' docs/work/ELZ-023-probes/recovery.exs
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test elixir -pa '_build/test/lib/*/ebin' docs/work/ELZ-023-probes/probe.exs
python3 scripts/check-roadmap.py --write
python3 scripts/check-roadmap.py
python3 scripts/check-roadmap.py --live
git diff --check
```

Generator output is byte-identical to the committed Cure source; the old `policy.cure`
and `probe.exs` are byte-identical to pre-amendment HEAD `3377360`.
Roadmap write/plain/live checks exited **0**, each checking 136 links; live Contracts match.
Issue #37 and task body compare bytewise at **16,210 bytes**, SHA-256
`52f2312c013f75a7ae98d8bbb2c5e076c38354ebc1d4646f5b31426d90a5e539`.
The only roadmap manifest change is that ELZ-023 issue-body hash.

## Results

| Probe | Exit | Exact result | Last output (WIB, 2026-11-08) |
| --- | --- | --- | --- |
| `provenance.exs` | 0 | `Result: 11 passed` | 09:09:30 |
| `capacity.exs` | 0 | `Result: 7 passed` | 09:09:30 |
| `recovery.exs` | 0 | `Result: 7 passed` | 09:09:19 |
| `probe.exs` | 0 | `Result: 8 passed` | 09:09:22 |

Provenance: seven quantified step-label laws plus their guard-instantiated entry
points pass Cure checking. Audit: axioms/holes/opaque/unresolved/unaudited/
not_proven_total all empty; absurd = 0. Eleven actual policy mutations are
rejected with **conversion_failure**, not parse/type-error stand-ins:
Pending, Expired, Resume, Lost, TimedOut, Failed silent returns; Groundless,
WrongGround, Reset, Count and StrayDispatch. Always-stop fails the positive
dispatch gate. Initial state, three valid rearm paths, guard boundaries, narrow
replay, permanent/schema disarm and read-only recovery have executable scenarios.

Capacity: actual candidate entry=426, complete evidence=512, model=706224,
checkpoint=870226, delta payload=68568 bytes. All declared numeric length/count
limits and limit+1 are exercised; the exact one-MiB opaque Store snapshot is
accepted and one additional byte refused (not a legal domain model, whose
maximum is smaller). Reserved slots/events survive optional saturation.
Worst-model cumulative checkpoint encoding upper bound: **3228983296 bytes**;
append log and DB/index/replica overhead are additional.

Recovery: fresh activation requires acknowledged durable-host marker semantics;
process restart and absent recovery state are read-only; uncertain activation
and contradiction writes halt; exact late-commit confirmation alone does not
clear the host obligation; explicit authoritative reconciliation advances a
CAS generation; stale/uncertain/unavailable results refuse. Finite completion
classification and recovery-deadline overflow checks also pass. The host fixture
uses existing Memory/Store, not a new CAS engine; it does not test machine death.

## Scope and limitations

- This is proposal/probe evidence, not the production Piece, owner, fold or SQL implementation.
- The checked laws are one-step labels over well-typed Cure inputs; the reachable-trace argument
  and initial condition are stated separately, not claimed as a checked induction theorem.
- Guard predicates are shared by runtime and expected labels. Boundary tests cover named numeric
  cases; no independent proof of native integer comparisons or host timestamps is claimed.
- Candidate encoding demonstrates arithmetic/layout, not full decoder/fold correspondence.
  Production must validate every field, preserve reserves and rerun sizes on any layout change.
- Host durability, authentication, physical old-owner fencing, Adapter no-send truth and provider
  replay/finality semantics remain Needs. Memory proves only the listed process-boundary cases.
- Baseline setup/check ran before this docs/probe amendment on unchanged runtime; final implementation
  must run fresh pinned setup/full check, copied exports and independent actual-diff review.
- The first direct-computed-guard proof attempt failed conversion. The final unconditional helper
  lemmas and actual-guard instantiations checked without an axiom or safety hypothesis.
  One initial ExUnit harness had an ambiguous `!=` token; corrected before these final runs.

## Source hashes

| File (under docs/work/ELZ-023-probes) | SHA-256 |
| --- | --- |
| `provenance.template` | `3384277ca0f46abbf58a2d7f160bcafdd151dd5aba618dc037d46b7eebe31cae` |
| `generate_provenance.py` | `ecc9cabc1817bee3c3bf13b35043a25fc92fce5664acf312a93ea6df4c3ee57e` |
| `provenance.cure` | `6f6f5ab9d6df03dc325a06b4d75c3f4fbe63512ba26103422e66338e07cf244b` |
| `provenance.exs` | `01b5c94dc391e46a8909a9c3ba96e006e83d5449dd1e040fe18e175a3b20ad91` |
| `capacity.exs` | `460190df58bac80b23c2aeb7256a0dd9216bc05c36946b1ea50e09d74fbf6895` |
| `recovery.exs` | `e3286681f1ec9d9b301e66957adad31daf1e693f2069e737c14c5799cfa81d9c` |
| `policy.cure` | `b0d0a263dba9de0da3e3361ed0f1108830e5b7357aae1f8f197b5da36d7b3a5f` |
| `probe.exs` | `7db4a6c85c8ef1ac4ee23a655f90e5226fec5fcb29b36203395a167423cc3265` |

Scratch logs: `/tmp/elz023-amendment/{provenance,capacity,recovery,probe}-final.log`.
Committed sources and commands above are the portable reproduction; scratch paths are not required.
