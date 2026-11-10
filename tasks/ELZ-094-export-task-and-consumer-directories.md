# ELZ-094 — Reproduce and fix `mix elzoo.take` "argument error", and make copied-consumer directories host-unique

- Phase: defect investigation (consumer path; test support)
- Catalogue IDs: none (export tooling and test support)
- Dependencies: ELZ-091

## Outcome

Two findings reported by a coder's gate on 2026-11-10 (ELZ-087, PR #167), outside that task's scope:

1. `MIX_ENV=test mix elzoo.take <piece-id> --to <dir>` (and `core/envelope --dry-run`) printed "Cure sources
   unchanged ... skipping 35 modules" and then `** (Mix) argument error`, exit 1, at a commit containing main
   339c1edb, while calling `Elzoo.Export.plan!/3` and `write!/1` directly through `mix run` with the same arguments
   succeeded. The task rescues `ArgumentError` into `Mix.raise/1`, so the bare message hides a BIF badarg before the
   "Pieces:" line. Unverified by the coordinator; reproduced once by the coder. `docs/consuming.md` documents
   `mix elzoo.take` as the consumer path, and CI does not exercise the Mix task itself (the harness calls Export
   directly), so a defect here would be invisible to CI.
2. The copied-consumer harness names its directories `/tmp/elzoo-consumer-<System.unique_integer>`, unique only per
   VM; several worker VMs on one host collided and `ExportTest` "conflict found late writes nothing" failed on a
   stray `.elzoo`. CI's single VM cannot see it.

Reproduce (1) on current main, find its cause, fix it, and add a test that runs the Mix task itself; make (2)
host-unique.

## Admission record

1. **Responsibility and caller.** The documented consumer path and reliable local gates. Callers: every consumer
   following docs/consuming.md; every coder running gates in parallel.
2. **Interface and invariant.** `mix elzoo.take` behaves exactly as `Elzoo.Export.plan!/3` plus `write!/1` with the
   same arguments, and on failure prints the underlying error, not a bare "argument error" (keep the rescue but
   include the original exception and stack location). Consumer directories are created exclusively with a
   host-unique name (for example `System.tmp_dir!/0` plus a random suffix, refusing an existing path).
   No change to export output bytes or receipts.
3. **Reuse check.** Mix task conventions; `File.mkdir/1` exclusive creation; no new library.
4. **Split test.** Both touch the export path and its tests and share one reviewer; one PR. If (1) does not
   reproduce on a clean checkout at main, record the evidence (commands, environment, outputs) and keep only the
   error-message improvement and the Mix-task test.
5. **Failure and evidence.** Reproduce (1) in a fresh worktree with the coder brief's environment; name the badarg
   site from the full stack. Tests: a test that invokes the Mix task (`Mix.Task.rerun` or a subprocess) for one ready
   Piece into a temporary directory and compares the result with `Export.write!/1`'s; a failure-path test showing the
   original error text; a test that two concurrent consumer-directory creations never share a path. Independent
   review (export tooling and test support are protected-adjacent; `test/export_test.exs` assertions unchanged unless
   main approves an exact before/after).
6. **Composition record.** No Piece changes; documentation line in docs/consuming.md only if behaviour changes.

## Scope

`lib/mix/tasks/elzoo.take.ex` (or the module that implements the task), `lib/elzoo/export.ex` only if the cause is
there, `test/support/cure_consumer_case_test_helper.exs` (directory naming), new tests, work record.

## Acceptance

- [ ] (1) reproduced with recorded evidence and fixed, or recorded as not reproducible with evidence; in both cases
      the task reports the original error and a Mix-task test passes.
- [ ] (2) consumer directories are host-unique with a concurrency test.
- [ ] Existing export assertions unchanged; independent review; hosted full check passes at the PR head.

## Reference

PR #167 (ELZ-087) gate observations; ELZ-091 (#165).
