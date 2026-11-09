# ELZ-012 early Contract and evidence-plan review

> Redacted before publication (ELZ-070): local paths, session, dispatch, task and message ids, the test database name and role, and runner and machine names are replaced by placeholders or role words; hashes and byte-equality records in this file refer to the unredacted text.

Reviewer: an independent review session.
Reviewed head: `2f74b817d05906307e29f2876bb8d4b690499e9b` on `task/ELZ-012` (`<worktrees>/elzoo-ELZ-012`).
Base `70cb2cbbe6ab005ed61edd01d37dee1131afef5a` = current `origin/main`. Claim `8e1d50e`. Local HEAD equals `origin/task/ELZ-012`.
This review reads documents and sources. **I executed no `mix setup`, no `mix check`, no acceptance run and no test.** I ran only read-only commands (`git`, `gh issue view`, `cmp`, `shasum`, `grep`, `python3` reading JSON). I changed no tracked file. This is permission to start the execution plan; it is not evidence that ELZ-012 passes.

## Verdict

**CONDITIONAL.** The Contract reading, the byte-exact sync, the path scope and the fresh-clone design are sound. I found no need for a Contract amendment. Three items must be changed in the proposal before it is treated as the plan (E1, E2, E3), and eight execution gates bind the run (G1-G8).

- E1 (required): ELZ-050 to ELZ-055 are named as next work, but they exist nowhere a future worker can read.
- E2 (required): the evidence matrix must say which Pieces have a per-ID consumer. P3 has none.
- E3 (required): the acceptance-run revision must be pushed, and its relation to the final PR head must be checked, not asserted.

## Evidence I read, and what it shows

| Claim in the proposal | What I checked | Result |
| --- | --- | --- |
| Live #12 equals the preflight | `gh issue view 12 --json body`; first 1723 bytes, `shasum -a 256` | `e6031ef6a8a93fefcf64ce097d49373f65e768e21540ada2b09db17165785962`. Matches `preflight.json` and `release-plan.json` `issue_body_sha256`. Issue state OPEN. (`gh` adds one extra newline: 1724 bytes printed.) |
| Local task is a strict prefix of live | `head -c 1527 live \| cmp - tasks/ELZ-012-…md`; `diff` | equal. The only difference is live lines 41-47: two blank lines, `## Repository references`, a `Source:` line and a `Dependency issues:` line. The live body ends with exactly one `\n` (`…/issues/11` then `0a`). |
| `core/grounding` stays planned; `verification/clean-check` is not an ID | `registry/catalogue.json` line 128; `grep verification/` in the registry | `core/grounding` has `"status": "planned"`; no `verification/` ID exists. The manifest job row for ELZ-012 has `"outputs": []` and a contribution to `core/grounding` described as "not the evidence-index owner or an executable ready Piece". |
| ELZ-033 owns the grounding index | `docs/plans/roadmap.md` lines 108-118; live #55 | roadmap text matches. #55 is CLOSED. (The manifest `status` for ELZ-033 still reads "implementation prepared; parent review and merge pending". That wording is stale. Do not copy it.) |
| Roadmap check passes | author's statement; the check source | `check-roadmap.py --live` compares `sha256(live body)` with the manifest hash and the dependency lists. It does **not** compare the local task file with live, except ELZ-033 (line 127). |

## Disposition of the questions asked

### 1. Historical headings `core/grounding` and `verification/clean-check`: CLEAR

Reading them as historical handoff terms is correct and needs no Contract change. Support: no `verification/clean-check` ID exists; the manifest gives ELZ-012 no outputs; the roadmap says "ELZ-012 still owns its published clean-check handoff; its task body and acceptance are unchanged" and that the grounding index is a planned deliverable of ELZ-033 with the registry entry staying planned. Conditions:
- The handoff document must state this reading in one sentence and must not use "ready", "promoted" or "verified" for `core/grounding`.
- No `registry/`, `LEDGER.md`, `piece.json`, plan or manifest edit. The proposal already says so; keep it as a gate (G7).

### 2. Bytewise sync of the local task file to live: CLEAR, no amendment

The live text above the new section is unchanged and the canonical hash already equals live, so the sync changes no Contract word and no hash. Notes:
- The local file would become the only task file with a `Repository references` section: `grep -l "Repository references" tasks/*.md` finds none today (0 of 47). That is acceptable. Do not add the section to other files.
- Nothing mechanical checks this sync, so it needs its own gate (G1): write the file with a method that adds no extra newline (for example `gh issue view 12 --json body -q .body` followed by `head -c 1723`, or `jq -j`), then require `wc -c` = 1723 and SHA-256 = `e6031ef6…5962`, and `cmp` with the live prefix. A plain `gh … -q .body > file` writes 1724 bytes and gives a different hash.
- The `Source:` link in that section points at `blob/main/tasks/ELZ-012-…md`, which resolves only after merge. This is live text; do not edit it. Mention it in the PR so a reviewer does not "fix" it.

### 3. Scoped documentation paths: CLEAR with two notes

The listed paths (`docs/work/ELZ-012*`, `docs/work/ELZ-012-evidence/`, `docs/development/clean-check-handoff.md`, a link in `06-toolchain.md`, the task file) are inside the Scope bullet "update only relevant handoff/development/catalogue docs". The task's "catalogue docs" is permissive and the proposal rightly declines it.
- Note A: `check-roadmap.py` scans links only in `docs/plans/*.md`, `AGENTS.md`, `GOAL.md`, `01-workflow.md`, `02-task-dag.md` and three capability/architecture files. The new handoff and `06-toolchain.md` are **not** scanned. The proposal already plans its own link check (step 7); make it explicit that it is a separate manual or scripted check of those two files (G6).
- Note B: `06-toolchain.md` keeps "Leave `MIX_ENV` unset" text and the pins. The link must not change a pin or a command. Keep it to one sentence.
- Optional: the handoff is reachable only from `06-toolchain.md`. A future worker reads `AGENTS.md` first. I do not recommend editing `AGENTS.md`. One line in `docs/development/02-task-dag.md` is acceptable if root agrees; not required.

### 4. True fresh clone, caches, pins, hashes, claim sequencing: CLEAR with gates

The design (new `git clone`, no `--shared`, no copied `deps/` or `_build/`, unset overrides) matches what the bootstrap record did (`docs/development/07-bootstrap-validation.md`). I read the sources the run depends on:
- `mix setup` = `deps.get`, `compile`, `elzoo.ash_spike --setup`. `mix.exs` pins Cure by `ref: 208248063d64e621782cd26dd30698ee42850a89` with `depth: 1`; `elixir: "== 1.20.4"`. `setup` and `check` prefer `MIX_ENV=test`.
- `mix check` stages: format, compile, ledger, ash_spike, registry_load, root_suite. It prints the selection report, then `ELZOO CHECK PASSED` through `System.at_exit` **only when the exit status is 0**. It does not run `check-claims.py` (that is a CI step).
- The Cure compile task skips only when a fingerprint matches. The fingerprint covers Elixir, OTP, ERTS, the compiler module hash, the **whole `mix.lock`**, a digest of every file in the loaded Cure `ebin`, the roots, `Cure.toml` files and every source. So a fresh clone cannot skip, and the digest is evidence of which Cure build produced the BEAMs. The Cure stdlib under `priv/` is not hashed (the source says so); the lock file covers it.
- The Ash spike runs `mix` in `spikes/ash_foundation` with `MIX_BUILD_PATH` and `MIX_DEPS_PATH` set to nil, so it has its own `deps/` and `_build/`. The proposal's "absent root and spike deps/_build" check is right.
- Machine state I observed: `~/.hex` (with `packages/hexpm`) and `~/.mix` exist on this host, so Hex packages and archives are cached; no `~/.cache/rebar3`. `elixir` is 1.20.4 on OTP 29 and `OTP_VERSION` reads 29.1.2. The shell has no `MIX_*`, `HEX_*`, `ERL_*` or `ELIXIR_*` variable set, but it does hold `ORCA_*` variables that include session tokens and a pairing code. **Never print the environment**; print only named, non-secret variables (G3).
- Claim removal: `check-claims.py` is not part of `mix check`, so the claim marker does not change the check. Removing it before the acceptance run is still right, because the acceptance revision should equal what is merged. Keep the original claim commit in history.

### 5. Command and evidence mapping; exemplar/P1/P2/P3; copied consumers versus cold install: CONDITIONAL (E2)

The matrix is mostly accurate. The gap: `CheckSelection.@consumer_ids` (25 IDs) is "the existing export-test inventory, not every ready Piece". It does **not** include `core/effect`, `delivery/effect-intent`, `assembly/http-job`, `integration/http` or `integration/json`. Those ready Pieces are covered by the root suite and by the **aggregate** consumer, which runs "every ready bundle's own tests plus copy/compile". The check prints the exact lists (`Ready IDs without a fixed per-ID consumer: …`). So:
- For P3, the matrix must say "root suite and aggregate consumer", not "individual consumers".
- The ELZ-011 standalone export utility (`docs/work/ELZ-011-export-check.exs`) is **not** part of `mix check`. If the handoff cites its 221-test result, it must label it a separate, previously recorded run on a different revision, and the acceptance run must not be described as having executed it. Either re-run it in the clone as an extra, labelled step, or cite it only as history.
- All consumers reuse root-built provider artifacts (already in the proposal, step 6). Keep that sentence next to every consumer claim.
- Counts (Ash 32, root 642 on main after ELZ-011) are expectations from the ELZ-011 record. They must be read from the new log, not copied (the proposal already says so).

### 6. Named future tasks without importing ELZ-050 scope: CONDITIONAL (E1)

Acceptance bullet 4 asks for "concrete/new task IDs". I searched for the IDs the proposal names:
- `release-plan.json` has no job `ELZ-050` to `ELZ-056` (the last published job rows stop before them), and `tasks/` on `origin/main` has only `ELZ-056-contabo-backend-runner.md` in that range.
- `gh issue list --state all --search "ELZ-050 in:title"` and the same for `ELZ-051` return nothing. The open issues are #12, #27-#31 family, #41, #44, #49, #57-#60 style CI tasks.
- So ELZ-050 and ELZ-052-055 are known only from the coordinator's message. A future worker "without oral context" cannot find them, and the manifest is not a complete list (ELZ-056 to ELZ-060 are also missing from it).

Required: see E1 below.

### 7. Other points checked

- Branch lock: `origin/task/ELZ-012` exists at the reviewed head; no force push needed.
- The proposal's own wording on "ELZ-033 owns the planned index" is right; just avoid the stale manifest status text.
- Memory note from the project: fast CI runners are scarce. The acceptance run is local and the PR adds no CI run, so nothing to change; do not add workflow edits (the proposal already excludes them).

## Required changes to the proposal

### E1 — name next work only where it can be read

Before (proposal, "Next work and decisions"): "After ELZ-012, the root-directed next task is ELZ-050 decision-ready catalogue records before new implementation. … ELZ-052–055 are draft IDs pending coordinator publication approval and ELZ-051 is reserved; no issues are published by this task."

After:
> The handoff lists next work in two separate groups. (1) **Published and readable now:** issues taken from a live `gh issue list -R balungpisah/elzoo --state open` snapshot, recorded with its UTC time, number and title only, each marked "recheck dependencies and remote claims; not a lock". (2) **Coordinator-communicated, not published:** ELZ-050 (catalogue admission and dispositions), described in one sentence as the coordinator's stated next task, with the words "no issue, task file or manifest row exists at this revision; the coordinator publishes it". ELZ-051 to ELZ-055 are not named in the handoff. The handoff does not describe ELZ-050's scope or decisions.

Reason: acceptance asks for concrete task IDs, but an ID with no issue or file does not let a future worker act; and describing draft scope would import ELZ-050 policy. If root prefers to name 051-055, root must publish or record them first. This is a coordinator decision only if root wants the longer list.

### E2 — evidence matrix: per-ID consumer wording

Before (table row "Copy"): "Aggregate/individual consumers, receipts and isolated runtime markers".

After:
> Aggregate consumer over all ready IDs; per-ID consumers only for the IDs the check prints in its selection report (core/effect, delivery/effect-intent, integration/http, integration/json and assembly/http-job have none); receipts; isolated runtime markers only where the log shows them. The ELZ-011 standalone export utility is outside `mix check` and is cited only as a separate recorded run unless it is re-executed and logged.

### E3 — acceptance revision

Before (execution plan step 1): "Check out the frozen task revision used for the evidence; claim marker removal occurs before the clean acceptance run…"

After:
> The frozen revision is pushed to `origin/task/ELZ-012` before it is cloned, and its SHA is recorded. It contains the claim-removal commit and the byte-exact task sync. After the run, `git diff --name-only <acceptance SHA> <final PR head>` is recorded and must list only `docs/` and `tasks/ELZ-012-…` paths. If it lists anything else, or if `origin/main` advanced with a change outside `docs/`, the full check is rerun at the new head.

Reason: the proposal says documentation added after the run "must name the earlier checked revision". This makes that statement verifiable.

## Binding execution gates

- **G1 Task sync.** File size 1723 bytes, SHA-256 `e6031ef6a8a93fefcf64ce097d49373f65e768e21540ada2b09db17165785962`, equal to the live body at sync time; re-read the live hash again before the PR (`check-roadmap.py --live` also does this).
- **G2 Clone.** `git clone` of the remote into an empty unique directory; no `--shared`, `--reference`, alternates or worktree. Record `git rev-parse HEAD`, `git status --short` (empty), `test ! -e deps -a ! -e _build -a ! -e spikes/ash_foundation/deps -a ! -e spikes/ash_foundation/_build`, and SHA-256 of root and spike `mix.lock`.
- **G3 Environment.** Unset `MIX_ENV`, `MIX_DEPS_PATH`, `MIX_BUILD_PATH`, `ERL_LIBS`; record by name only any `MIX_*`, `HEX_*`, `ERL_*`, `ELIXIR_*` variable found; never dump the environment or the database URL. Record Elixir 1.20.4, `OTP_VERSION` 29.1.2, ERTS, OS and architecture. Disclose `~/.hex`, `~/.mix` and the Git/Hex network access as limits: this is not a cold-machine or offline test.
- **G4 Commands and exit codes.** Run `mix setup` then bare `mix check` (no `--affected`) with output sent to log files, not through a pipe that hides the exit status; record each exit code, start and end UTC time (WIB for human tables), and the log SHA-256. `ELZOO CHECK PASSED` counts only with exit 0.
- **G5 Cure identity.** After setup record `git -C deps/cure rev-parse HEAD` = `208248063d64e621782cd26dd30698ee42850a89`, `git -C deps/cure status --short` empty, the root `mix.lock` Cure entry, the loaded Cure path (`:code.lib_dir(:cure)` inside the clone's `_build`), and the emitted Cure manifest with its fingerprint. A later "Cure sources unchanged" skip line is not a fresh compile.
- **G6 Docs checks.** Run `check-roadmap.py` plain and `--live`, `check-claims.py` (expects "No tracked claim metadata"), `git diff --check` on non-patch paths, and a separate link check of the two new or changed development docs. Record the results as docs checks, not as part of `mix check`.
- **G7 Scope.** `git diff --name-only origin/main HEAD` shows only the paths in the proposal. No change to `registry/`, `LEDGER.md`, any `piece.json`, `docs/plans/`, `mix.exs`, `mix.lock`, workflows, scripts, source, tests or pins. No new `ready`, `proved` or `verified` word for any Piece.
- **G8 Failure handling.** If setup or check fails, keep the first log, do not edit source to make it pass, and report the exact failure to root. A retry is recorded as a retry; a flaky-test rerun is named as one.
- **Wording limits for the handoff.** Say "selected laws pass", "listed scenarios pass", "relies on <pinned upstream>'s documented behavior". Do not claim: proof for finite tests; exactly-once or physical-send guarantees; TLS, DNS or a live vendor; cold provider installation; that consumers install providers independently; or that elapsed time is a result.

## What I did not do

- I did not run `mix setup`, `mix check`, any test, probe or the consumer export. No claim here says any of them pass.
- I did not read all sources of every Piece the matrix cites; I read `mix.exs`, `check.ex`, `compile_cure.ex`, `elzoo.ash_spike.ex`, `check_selection.ex` (selection, report, marker), `check-roadmap.py` (live and link logic), the catalogue and release-plan rows, `roadmap.md` (grounding text), `06-toolchain.md` and `07-bootstrap-validation.md`.
- I did not verify the Cure laws named in the matrix (for example `drop_has_no_output`); the acceptance run must show them in the log or the handoff must cite them from the manifests only.
- I did not check the live issue comments of #12 beyond the body.
