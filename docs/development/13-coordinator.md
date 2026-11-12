# Coordinator

`AGENTS.md` at the repository root is the workflow. This page adds the steps of the coordinator role.

"Coordinator" is a role, not a person or a service. "Step 3 of the index files" is in section 3 of `AGENTS.md`.

- One task is one Piece directory, or one change of shared paths. Never both.
  The body lists each path outside the Piece directory.
- Give parallel workers tasks with disjoint paths. Put a shared prerequisite
  in its own task and merge it first.
- Publish a batch of tasks in this order:
  1. Write each `tasks/ELZ-###-<slug>.md`. It must hold one line
     `- Dependencies: ELZ-..., ELZ-...`.
  2. Create each issue from its file, without the label `task`:
     `gh issue create -R balungpisah/elzoo --title "ELZ-### — <title>" --body-file <file>`.
  3. Open one pull request with only these documents: the task files, and in
     `docs/plans/release-plan.json` one job row for each task. Copy the row
     of a recent published task and set each field: `id`, `title`, `kind`
     (`published`), `release`, `stage`, `dependencies` (equal to the line in
     the file; each one is a job of the same or an earlier release), `status`
     (`published <date>`, no live state), `owner_role`, `paths` (the one task
     file), `outputs`, `acceptance`, `product_aims` (one or more product IDs),
     `issue`, `url` and `issue_body_sha256`. Delete `observed_issue_state`
     from the copy: it is live state. Move each output Piece ID from its
     `RC-##` job to the new job, and set `job` in its `entries` row. A new
     Piece ID also needs a row in `registry/catalogue.json` (copy a planned
     row: `id`, `summary`, `disposition`, `phase`, `status` `planned`,
     `reason`) and a row in `entries` (`id`, `job`, `note`, `baseline_status`,
     `disposition`, `catalogue_reference`). Then run step 3 of the index files.
     Use a branch that is not named `task/...`. The queue does not take it.
     Merge one such pull request at a time, and not while a queue run is
     active. Before the merge, run these three commands:

         main=$(gh api repos/balungpisah/elzoo/git/ref/heads/main --jq .object.sha)
         gh api "repos/balungpisah/elzoo/compare/$main...<green head SHA>" --jq .behind_by
         gh api "repos/balungpisah/elzoo/actions/workflows/symbolic-check.yml/runs?event=push&head_sha=$main&per_page=100" \
           --jq '[.workflow_runs[] | select(.head_branch == "main")] | max_by(.id) | "\(.status) \(.conclusion)"'

     - The second command must print `0`: the green head holds the current
       `main`. If it prints another number, `main` moved: run
       `gh pr update-branch <PR number> -R balungpisah/elzoo`, wait for green
       on the new head and start again.
     - The third command must print `completed success`: the newest push run
       of the check on the current `main` is green. For each other output (a
       run in progress, a re-run, no run, a red run, also a classified red
       run): do not merge. Wait for a green `main`.

     This is stricter than the freeze rule of `AGENTS.md` section 7, for each
     publication pull request except the one below. A publication with only
     documents (the allowlist in `scripts/ci-change-class.py`) gets the short
     check, and the short check runs no tests.

     Run the three commands again immediately before the merge. Then merge
     with
     `gh pr merge <PR number> -R balungpisah/elzoo --merge --match-head-commit <green head SHA>`.
     `main` can still move between the commands and the merge. The queue has
     the same window. The push run of `main` after the merge covers it.

     One exception. When the red run of `main` is classified as `defect` or
     `conflict` (see the [CI guide](10-symbolic-ci.md)), the repair needs a
     new task, and the rule above would block it. The owner authorizes up to two repair attempts before escalation. Publish only the repair task, and merge its
     pull request when the second command prints `0` and its own check is
     green. The queue does not accept a short check on a red `main`, so this
     merge is a known exception. The repair task adds no new Piece ID. If its
     check cannot be green (for example the red is in the index files), fix it before merging; do not waive a required check. Ask the owner if two repair attempts have not restored a green `main`.
  4. After the merge, wait until the push run of the merge commit is green.
     Then add the label `task` to the issues. Workers then start
     from a `main` that holds their task and their rows. If that run is red,
     classify it as the CI guide says and add no label until `main` is green.
     For the repair task of the exception, add the label immediately after
     the merge. Then classify the red push run of that merge also, so that
     the queue takes the repair.
- **Levels.** Publish a wave of tasks in levels. A task of a level depends
  only on tasks of earlier levels. A Piece-only pull request merges on the
  small gate, and the queue does not wait for the full check of `main` between
  two such merges. At the end of each level, wait until the third command of
  step 3 above prints `completed success` for the current `main`. Only then
  publish the next level, or add the label `task` to its issues. If the run is
  red, do the repair below first.
- **Repair of a red `main`.** The full check on `main` is the evidence of the
  small-gate merges. When it is red:
  1. Classify the red run on issue #98, as the
     [CI guide](10-symbolic-ci.md) says.
  2. Find the last green `main` and the pull requests merged after it:

         gh api 'repos/balungpisah/elzoo/actions/workflows/symbolic-check.yml/runs?event=push&branch=main&status=success&per_page=1' \
           --jq '.workflow_runs[0].head_sha'
         git log --merges --first-parent --format='%h %s' <last green SHA>..origin/main

  3. Give a repair agent the log of the red run and the body of each of those
     pull requests (`gh pr view <PR number> -R balungpisah/elzoo --json body`).
     The lines `Test:`, `Contract:` and `Limits:` of each body state what that
     pull request expected.
  4. The repair agent repairs forward in a new task: a new commit on top of
     `main`, not a revert and not a history rewrite. Publish the repair task as
     the exception in step 3 above says.
  5. Keep unrelated merges frozen until the current `main` push run is green. Each repair attempt is a proposed fix checked on its exact head and, if merged, on `main`; record its result on the repair issue. After two unsuccessful attempts, stop and ask the owner with the failing command, last green commit and remaining decision. Force pushes, history rewrites, deletion of unmerged work and branch-protection changes still need the owner's approval.
- `python3 scripts/check-roadmap.py --live` compares each issue body with
  `issue_body_sha256`. After you edit an issue body, update the task file and
  the hash in one commit. This prints the hash:

      gh issue view 123 -R balungpisah/elzoo --json body | python3 -c \
        "import sys,json,hashlib;print(hashlib.sha256(json.load(sys.stdin)['body'].encode()).hexdigest())"

- Change `AGENTS.md`, this page, CI or the queue only when the owner asks. Collect the
  `Friction:` lines from pull requests and bring them to the owner.
