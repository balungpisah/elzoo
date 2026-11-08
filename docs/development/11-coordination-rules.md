# Coordination rules for long-running parallel work

These rules come from running four implementation tasks in parallel on 2026-11-08 and
2026-11-09 under one main coordinator and one pieces coordinator. Each rule names its source:
a repository record (a task record under `docs/work/`, a PR body, `AGENTS.md`,
`docs/development/10-symbolic-ci.md`) or the main coordinator's decision record posted on the
ELZ-067 issue (#119, comment "Operating decisions of the main coordinator, 2026-11-08/09"). A rule with a decision as its source is a chosen operating rule, not a
guarantee that tooling enforces it. These rules change no Contract, command or check; the
owner's priorities and the live task bodies decide what is built.

## 1. Worker caps

- Run local full checks sequentially when they share a database server. Record a failing check
  as failed and disclose any diagnosed environment cause; rerun it after that cause is
  addressed. Source: the PR #117 and PR #118 bodies disclose two full checks that ran at the
  same time on 2026-11-08 and failed in the copied-consumer database tests with PostgreSQL
  `too_many_connections` errors, and their green reruns after serialization.
- The main coordinator's decision record (#119) sets the caps per host: at most three task
  workers running Mix at once, one bare `mix check` at a time, one disposable database per
  worker; an idle, held worker does not count; the caps are re-measured whenever the CI lane
  or the host changes.
- Use the assigned disposable database. Before schema or data effects, verify the effective
  target with a fail-closed guard; the identification query itself precedes that verification.
  Source: the ELZ-028 and ELZ-031 task records.
- Edit shared files only within explicitly authorized, coordinated scope; regenerate derived
  views when required. Source: `AGENTS.md` ("include a necessary shared change explicitly in
  the issue and coordinate overlapping work") and the decision record.

## 2. Channel rule

- Use the coordinator's designated dispatch channel and report the revision and next action
  when handing work back; confirm receipt of decisions and review requests. Source: the
  decision record (#119), which also states that a coordinator reads the cards addressed to
  its own dispatch and arms its own wake-up for each pending external result.

## 3. Review discipline

- Early independent Contract reviews found, among other issues, renewal timing, provider
  cleanup assumptions, missing classifier laws and registry identity concerns; reviewing before
  implementation can expose these before the design is built. Source: the ELZ-027, ELZ-028,
  ELZ-029 and ELZ-031 early-review records under `docs/work/`.
- A change to a live issue body is proposed as exact before/after text on the issue before the
  edit and decided by the main coordinator; the editing worker syncs the task copy bytewise
  and the roadmap hash in the same commit. Source: `AGENTS.md` ("change the Contract and
  acceptance deliberately with review"), the ELZ-027 and ELZ-031 contract-proposed records,
  and the decision record (one edit per approved round; the main coordinator decides).
- When a live issue body changes before the matching manifest update merges, the live roadmap
  check on main can fail until they agree; coordinate and reconcile manifest changes before
  merge. Source: `scripts/check-roadmap.py --live` compares live bodies with the manifest; the
  decision record orders such PRs before other manifest-touching PRs.
- After a conditional review, request confirmation of the changed points at the revised SHA.
  A separate reviewer inspects the actual diff and scope; retain the review or a marked
  redaction with the original SHA-256. Source: the ELZ-027, ELZ-028 and ELZ-031 review and
  confirmation records.

## 4. Automated and independent review

- Independent review is required for the protected boundaries and evidence claims named in
  `AGENTS.md`, and whenever the task requires it; straightforward prose or mechanical test
  changes may not require it. Source: `AGENTS.md`, "Review, merge and cleanup".
- The decision record (#119) adds: every finding posted by the Devin Review app on a PR is
  answered or fixed with a one-line disposition before the queue is requested, and the PR
  body states the count under Grounding. Reason recorded there: findings left open at queue
  time were observed to become stale against later pushes on PR #118.

## 5. Public-repository writing

- For a review containing non-public operational details, publish a marked redaction and
  record the SHA-256 of the original. Keep credentials and connection strings out of public
  records and use the designated private channel to share them. Source: the ELZ-027 and
  ELZ-031 redaction records under `docs/work/` and the decision record (#119), which states the
  owner's rule for the public repository: no hostnames, addresses, domains, local filesystem
  paths, database names, credentials, agent-platform identifiers or machine inventories in
  issues, PRs, comments or committed files; roles instead of identities; local evidence by
  repository path or SHA-256. The record adds that standard tool attribution lines and
  commit trailers are not private information.

## 6. Agent identifier

- Do not derive the identifier from a hostname; include the other claim metadata required by
  `AGENTS.md` (stable ID, issue number, login, time, base SHA, and branch and claim SHA in the
  issue comment). Source: `AGENTS.md` claim procedure and the decision record (#119), which
  records the owner's reason: claim markers and claim commits become public with the
  repository.

## 7. Evidence packet

- Record the evidence applicable to the task: its Contract and decisions, review findings and
  dispositions, any provider probes, exact executed commands and outcomes, task-copy and
  manifest synchronization where applicable, and the PR grounding categories and limits
  required by `AGENTS.md`. Distinguish failed checks and their diagnosed causes from passing
  runs. Source: `AGENTS.md`, "Verify the actual claim"; the ELZ-028 re-review record shows the
  risk of presenting planned or partial evidence as established.

## 8. Merge queue operation

- Avoid dispatching a check by hand while the queue identifies its run; if the queue stops
  while its run is in progress, inspect or manually adopt the identified run before dispatching
  another; the queue retries certain transient reads but does not automatically resume from
  that run. Source: `docs/development/10-symbolic-ci.md` and `scripts/merge-queue.py`.
- Run measurement series on a slow or idle runner; while a merge queue is pending, run at most
  one series at a time. State expected duration and stay under the backend job's 90-minute
  limit. Source: `docs/development/10-symbolic-ci.md`.
- The decision record (#119) states that only the main coordinator runs
  `scripts/merge-queue.py`, one PR at a time.
