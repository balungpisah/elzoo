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
     - The third command shows the newest push run of the check on that
       `main`. For a pull request with the full check, the freeze rule of
       `AGENTS.md` section 7 applies: do not merge while that run is red and
       not classified.
     - A pull request whose changed paths are all on the documents list of
       `scripts/ci-change-class.py` gets the short check, and the short check
       runs no tests. For that pull request the third command must print
       `completed success`. A run in progress or no run: wait. A red run: do
       not merge, also when the red run is classified. Wait for a green
       `main`. This is stricter than the freeze rule of `AGENTS.md` section 7,
       and it applies only to a pull request with the short check.

     Run the three commands again immediately before the merge. Then merge
     with
     `gh pr merge <PR number> -R balungpisah/elzoo --merge --match-head-commit <green head SHA>`.
  4. After the merge, add the label `task` to the issues. Workers then start
     from a `main` that holds their task and their rows.
- `python3 scripts/check-roadmap.py --live` compares each issue body with
  `issue_body_sha256`. After you edit an issue body, update the task file and
  the hash in one commit. This prints the hash:

      gh issue view 123 -R balungpisah/elzoo --json body | python3 -c \
        "import sys,json,hashlib;print(hashlib.sha256(json.load(sys.stdin)['body'].encode()).hexdigest())"

- Change `AGENTS.md`, this page, CI or the queue only when the owner asks. Collect the
  `Friction:` lines from pull requests and bring them to the owner.
