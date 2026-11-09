# Change-class flow: the coordinator's map

Source: owner decision of 2026-11-09 ("the flow is guided by the coordinator; conditions can
alter the flow without sacrificing quality"), coordination rule 9 (evidence economy), the
redundancy audit (ELZ-075, #140), the worker gate and claim rule (ELZ-076, #142), the
documentation-only path (ELZ-071, #131) and the pull request run as merge evidence (ELZ-059,
#99). This page is the map the main coordinator reads before it orders a task; a worker
follows the order it receives. It changes no command or check.

## Two layers

1. **The coordinator decides the path.** For each task it names the change class, the
   sequence, what is combined into one PR and what is split, the review depth and the
   evidence it will accept. Judgement is the coordinator's job.
2. **The machines verify the path.** The classifier (`scripts/ci-change-class.py`), the
   workflow guard (`scripts/check-ci-runners.py`), the merge queue (`scripts/merge-queue.py`)
   and the push-skip decision (`scripts/ci-skip-decision.py`) compute the class and the
   evidence from the diff and the run, never from a message. When an order and a machine
   disagree, the machine wins and the order was wrong. A class that no machine can verify
   yet stays coordinator-only and is marked so below.

## The floor: steps no class skips

- Exact-head evidence before a merge: the pull request's own hosted run, adopted by the queue
  (dispatch only as a logged fallback). Source: `AGENTS.md`, `docs/development/10-symbolic-ci.md`.
- Every automated-review finding dispositioned and its thread resolved; the coordinator
  re-checks open threads immediately before the queue (PR #141 was queued with one open).
- The public-repository writing rule; no force-push; no history rewriting.
- One source of truth per record; transcription is checked mechanically (rule 9).
- Branch protection: `check-hosted` and `gleam-hosted` required on `main`.

## The graph

    diff of the PR against main
      |
      +-- documentation only (docs/**, tasks/**, README.md, GOAL.md, PLAN.md) ---> class D
      |     machine: classifier (ELZ-071); queue accepts the docs-only marker only when its
      |     own path list agrees
      +-- tests only (test/**, pieces/*/test/**; no lib, no scripts, no workflow) -> class T
      |     coordinator-only today (the hosted run is still the full run)
      +-- one Piece (pieces/<family>/<name>/** plus its own records, shared files only in
      |   the final step) ----------------------------------------------------------> class P
      |     machine: the affected selection; queue: full run
      +-- protected surface (.github/**, scripts/**, lib/mix/tasks/check.ex,
      |   lib/elzoo/check_selection.ex, test/export_test.exs, AGENTS.md acceptance text) -> class S
      |     machine: guard pins; queue: full run; independent review required
      +-- Contract amendment (a live issue body, a Cure law, a typed boundary) --------> class C
      |     coordinator-only: exact before/after on the issue first
      +-- dependency or toolchain (mix.exs, mix.lock, config/**, the Cure, Elixir, OTP pins) -> class X
            machine: full run; a local full `mix check` is required before the push

## The orders per class

| Class | Local gate before a push | CI shape | Review depth | Combine or split | Queue evidence | Observed cost today |
| --- | --- | --- | --- | --- | --- | --- |
| D documentation | plain checkers (`check-roadmap.py`, `check-claims.py`, `git diff --check`) | short check, about 1 min (ELZ-071) | none independent; automated review dispositioned | combine small docs changes of one task into one PR; a task copy may travel with its implementation PR | `mode=docs-only` adoption | PR #139: 57 s |
| T tests only | the changed tests plus `mix check --affected <base>` | full run (the classifier has no test-only class yet) | one narrow independent pass when a merged test changes (owner approval of the edit stays required) | one test repair per PR | full-run adoption | ELZ-072, ELZ-074: about 20 min each |
| P single Piece | `mix check --affected <base>` plus `mix test pieces/<family>/<name>/test` (ELZ-076) | full run | early Contract review, then one batched review round per revision; transcription checked mechanically | shared files only in the final step; one PR | full-run adoption | ELZ-027 to ELZ-031: 17 to 25 min per run |
| S protected surface | guard and script tests, actionlint, `git diff --check`; no local full check | full run | independent review required; re-review only of post-review commits that touch code | split a trust change from a mechanical change (ELZ-059 part A and ELZ-071 were split) | full-run adoption, from the branch's own queue script when the evidence rule itself changes | ELZ-059, ELZ-069, ELZ-071 |
| C Contract amendment | none (text) | as the carrying PR | exact before/after posted on the issue, decided by the coordinator, then the editing worker syncs the task copy and the pin in one commit | one amendment per approved round per task | as the carrying PR | ELZ-027, ELZ-031 |
| X dependency or toolchain | local full `mix check` (the only class that keeps it) | full run, caches cold once | independent review (toolchain pins are protected) | never combined with a Piece change | full-run adoption | ELZ-060 (Gleam download route) |

## When the coordinator departs from the table

- Combine: two documentation changes of the same task, or a task copy with its PR.
- Split: a protected-surface change that adds a new trust decision gets its own PR and review
  (ELZ-059 part A and ELZ-071).
- Skip a step only when the table says the step is not required for the class, or when the
  evidence already exists (rule 9: a recorded run is a baseline; a reviewed claim is not
  reviewed again for its transcription).
- Never skip a floor step. A departure is written in the task record with its reason.

## Candidates for new machine checks (each needs a measured saving first)

- `AGENTS.md` and other policy text in the documentation-only allowlist: no test reads them;
  the saving is 20 minutes per policy PR (ELZ-076 paid it four times for review fixes).
  Folded into ELZ-073 (#136) on 2026-11-09 because that task already changes the classifier
  integration and the guard.
- A test-only CI class was considered and withdrawn: tests are code and must run, so no
  shorter CI shape exists; the class differs only in review depth, which the table states.
- Parallel job set (ELZ-073, #136): adopted by measurement (median wall 1250 s to 642 s);
  halves the full run for classes P, S, T and X.
- Combine items into one lifecycle when they share files and reviewers (one review round, one
  run, one queue step); keep them apart when they share only a calendar or carry separate
  trust decisions, because one blocking finding then delays everything in the PR.
