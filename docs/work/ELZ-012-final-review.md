# ELZ-012 final independent review

> Redacted before publication (ELZ-070): local paths, session, dispatch, task and message ids, the test database name and role, and runner and machine names are replaced by placeholders or role words; hashes and byte-equality records in this file refer to the unredacted text.

Reviewer: an independent review session.
Reviewed head: `8594a3b79e988a951b1716caaea3b700447d6e58` on `task/ELZ-012` (`<worktrees>/elzoo-ELZ-012`). Local HEAD equals `origin/task/ELZ-012`. Diff base `origin/main` = `b62c26a229fc86fa7700376d4cb6a21be536baa7`.
Earlier report: `docs/work/ELZ-012-early-review.md` is byte-equal to `/tmp/elz012-early-review-report-0f974e4c.md` (`cmp` exit 0).
I changed no tracked file, issue, branch or pin. `git status --short` was empty after every command and HEAD stayed `8594a3b`. I did not run `mix setup` or `mix check` (the author's logs are the evidence; I re-verified them, below). This is a review, not merged acceptance.

## Verdict

**CONDITIONAL on one documentation fix (R1). I found no blocking finding in the evidence, scope or claims.** R1 is docs-only. By E3 it needs no new Mix run: the final PR head may differ from the checked revision `907c37f` only in `docs/` and the task copy, and R1 stays inside that.

## Scope and revision checks (all mine)

| Check | Command or source | Result |
| --- | --- | --- |
| Files changed vs main | `git diff --name-only origin/main HEAD` (30 paths) filtered to the allowed set | none outside `docs/work/ELZ-012*`, `docs/development/clean-check-handoff.md`, `docs/development/06-toolchain.md`, `tasks/ELZ-012-clean-check-…md`. No change to source, tests, pins, `registry/`, `LEDGER.md`, plans, workflows, scripts. Inherited ELZ-060 and ELZ-049 arrive only through normal merges `d70bee6` (parents `36e0978`, `65601de`) and `907c37f` (parents `d70bee6`, `b62c26a`). |
| Docs-only distance from the checked revision | `git diff --name-only 907c37f HEAD` | 27 paths, all under `docs/` or the task copy. Code and test bytes after `907c37f` are unchanged. |
| Claim marker | `git ls-files .claims`; `scripts/check-claims.py` | none tracked; "No tracked claim metadata". The claim commit `8e1d50e` stays in history. |
| Task copy equals live | `wc -c`, `shasum -a 256`; live `gh issue view 12` first 1723 bytes | 1723 bytes, `e6031ef6a8a93fefcf64ce097d49373f65e768e21540ada2b09db17165785962` both. |
| Roadmap | `check-roadmap.py` plain and `--live` | both pass (139 links; live Contracts match) |
| Whitespace | `git diff --check origin/main HEAD` | exit 0 |
| Local links | my own script over the handoff, `06-toolchain.md`, `ELZ-012.md` | 4, 2 and 24 relative links, none missing |
| Secrets in the docs | `grep` for database URL, credentials, token, `ORCA_` | none. Only the test database name appears, as the plan allowed. |
| `06-toolchain.md` change | `git diff b62c26a HEAD` | two added lines: one sentence and a link. No pin or command change. |

## Execution evidence re-verified from the retained logs

Logs are in `/tmp/elz012-acceptance-i02p01gy/` (outside the repository).
- **Hashes.** I recomputed SHA-256 of all six logs and the Cure inspection files. They equal the values in `results.json`, `post-merge-results.json`, `consumer-main-results.json` and the headers of the extracts. Cure manifest `3a2bb8e8…f784` equals `cure-identity.json`.
- **Extract fidelity.** I parsed every numbered line in the six extracts (32 + 178 + 1 + 178 + 1 + 178 lines) and compared it with the same line number in the original log: 0 mismatches.
- **Counts and marker.** All three check logs contain `Result: 32 passed` (Ash), `Result: 642 passed` (root) and exactly one `ELZOO CHECK PASSED`; none has a failure header. `results.json` records exit 0 for all six commands. Times are consistent with the log stage stamps; the WIB conversions in `ELZ-012.md` are UTC+7.
- **Fresh clone.** `initial.json`: revision `36e0978`, empty status, `deps`, `_build` and the spike's two directories absent, no alternates, `MIX_ENV`/`MIX_DEPS_PATH`/`MIX_BUILD_PATH`/`ERL_LIBS` unset, only `ERL_FLAGS` present by name, OS arm64, Elixir 1.20.4, `OTP_VERSION` 29.1.2, ERTS 17.1.1, machine `~/.hex` and `~/.mix` disclosed. The retained clone has no `.git/objects/info/alternates`.
- **Cure identity.** `setup.log` has 29 `Compiled … -> Cure.Elzoo.*` lines (the "29 project modules" claim) after "Compiling Cure standard library (80 modules)". The clone's `deps/cure` HEAD is `208248063d64e621782cd26dd30698ee42850a89` with clean status; the root `mix.lock` entry carries the same SHA; both lock hashes (`811e4888…`, `59205712…`) are unchanged in all three states. The later "Cure sources unchanged … skipping 29 modules" line at the start of each check is correctly treated as a skip, not a fresh compile.
- **Failure handling (G8).** The diagnostic typo (extra parenthesis, exit 1) is preserved: `cure-inspection-attempt1.log` hashes to `0d4373c9…`, equals the identity record, and it was a diagnostic command, not setup or check.
- **Source relationship.** I recomputed every path hash in `source-hashes.json` (307, at `36e0978`) and `source-hashes-current.json` (311, at `907c37f`) from Git: 0 mismatches. The changed set is exactly `test/export_test.exs` and `test/test_helper.exs`; the added set is `test/consumer_group_{a,b,c}_test.exs` and `test/support/cure_consumer_case_test_helper.exs`; none removed. This matches "2 changed, 4 added" and the ELZ-049 description.
- **Retained clone.** It sits at `907c37f`, clean, `deps/cure` at the pinned SHA and clean.

## Disposition of my early findings and gates

- **E1 (next work):** applied in substance. The handoff names ELZ-050 only as "coordinator-communicated, not published" with no scope, and names no ELZ-051 to ELZ-055. See R1 for the remaining defect in the published list.
- **E2 (per-ID consumers):** applied and confirmed in the logs. All three selection reports print 26 selected per-ID consumers and "Ready IDs without a fixed per-ID consumer" including `assembly/http-job`, `core/effect` and `delivery/effect-intent`; the aggregate shows `aggregate(44)` with runtime stage lines. The handoff counts P3 as "root suite plus aggregate" and states that the ELZ-011 export utility (221 tests) is outside `mix check` and is not counted. Correct.
- **E3 (revisions):** the clone revision `36e0978` was pushed before the clone; two normal main merges were each followed by setup and a full check; the final distance `907c37f..8594a3b` is docs and the task copy only. The follow-ups are labelled warm rechecks, not new fresh clones. Correct.
- **G1-G8:** G1 (1723 bytes, hash) holds; G2-G5 are in `initial.json`, `cure-identity.json` and the results; G6 (docs checks) I reproduced; G7 holds; G8 holds. Wording limits: the handoff says "selected laws", "finite", "loopback", "no live vendor/TLS/DNS", and "not a cold machine"; I found no unbounded-proof wording and no upstream contract described as local ownership.
- **Historical headings:** the handoff opening states that `core/grounding` stays a planned index owned by ELZ-033 and that no Piece or promotion is created. Correct.

## Findings

### R1 — required, docs-only: the published-issue list contradicts the handoff and is stale

The "Next work" table of `docs/development/clean-check-handoff.md` is the snapshot taken at 2026-11-08T12:09:41Z. It lists #100 (ELZ-060) and #89 (ELZ-049) as open published tasks and lists #12 (this task) itself. But:
- the same handoff records ELZ-060 and ELZ-049 as already merged into the tested revisions (`d70bee6`, `907c37f`), and
- `gh issue list --state open` now (my read) no longer contains #100 or #89. It still lists #99, #98, #96, #95, #76, #70, #48, #46, #45, #44 and #12.
A future worker would be pointed at finished work. The snapshot is dated and says "recheck", so it is not a false statement, but it defeats the purpose of E1.

Fix, either one:
- Regenerate the snapshot at PR time (`gh issue list -R balungpisah/elzoo --state open`), save it as `open-issues.json` with the new UTC time, drop #12 (itself), and update the table and the time in the text; or
- keep the 12:09 snapshot but add a sentence before the table:
  > Issues #89 (ELZ-049) and #100 (ELZ-060) were merged after this snapshot and appear in the recorded follow-up runs; #12 is this task. Treat none of the rows as a claim lock.

The first option is better. Either way the change is under `docs/`, so by E3 no new Mix run is required; the PR must still name `907c37f` as the checked revision.

### L1 — LOW: law and test names are not all visible in the retained log

The handoff table "Grounding reached by the full check" names `drop_has_no_output`, `drop_keeps_downstream` and the size-guard mutation scenario. The retained check logs show the module compiling and the suite passing (`composition.cure` compiled; 642 passed), and show the request-route-retry negatives by name (`ELZ-008 negative rejected: FalseLabelLaw`, `MutatedLabelStep`, `WrongLabelOperator`). They do not print the two `drop_*` law names or the size-guard test (dots only; `grep` of the full log finds 0 hits). Those names come from the Cure source, manifests and test source, which the evidence directory ties to the run by source hashes. Suggest one sentence under the table:
> Law and test names in this table come from the hashed sources and manifests; the log proves that those sources compiled and that the counted suites passed, not that each named law printed a line.

### L2 — LOW, disclosed limits to keep

- The three runs are sequential on one host with varying load; no timing comparison is claimed (the text says so).
- The two follow-up runs are warm (same clone, retained builds). The fresh-clone claim rests on the first run only. The text says so.
- Full logs live in `/tmp` and are not in the repository; the checked-in extracts carry hashes and line numbers. If `/tmp` is cleaned, the full logs cannot be re-read. Acceptable; it is disclosed.
- The first run's check log starts with "Cure sources unchanged", which is correct after setup, but a reader may expect a compile line there; the handoff already explains it.
- `ELZ-012.md` still lists `ELZ-012-final-review.md` as a planned path. This report is the content for it; the author adds it to `docs/work/` unchanged.

## What I did not do

- I did not rerun `mix setup`, `mix check`, the consumers or any test. The evidence in this report for those commands is the author's retained logs, which I checked for hash, line fidelity, counts, exits and markers.
- I did not verify the Cure laws or tests named in the matrix by execution (L1).
- I did not compare the live issue comments, only the body.
- Other limits: loopback only; Hex and Git network access and warm machine caches were present; this proves reproducibility of the selected exemplar at the recorded revisions, not of any other revision, host, deployment or future Assembly.
- Scratch: none created in the repository. I wrote only this report.
