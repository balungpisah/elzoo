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
  addressed. Source: PR #117 and PR #118 each disclose a full-check failure involving
  `too_many_connections` while another full check was running, and report a subsequent green
  full check; the decision record (#119) names the 100-connection limit as the reason for the
  cap.
- The main coordinator's decision record (#119) sets the caps per host: at most three task
  workers running Mix at once, one disposable database per worker; an idle, held worker does
  not count; the caps are re-measured whenever the CI lane or the host changes. Since ELZ-076
  the worker gate is the affected run, so the one-full-check-at-a-time cap applies only to the
  rare local full `mix check` after a dependency, configuration or toolchain change, and the
  host full-check slot granted by a coordinator is retired.
- Use the assigned disposable database. Before schema or data effects, verify the effective
  target with a fail-closed guard; the identification query itself precedes that verification.
  Source: the ELZ-028 and ELZ-031 task records.
- Edit shared files only within explicitly authorized, coordinated scope; regenerate derived
  views when required. Source: `AGENTS.md` ("include a necessary shared change explicitly in
  the issue and coordinate overlapping work") and the decision record.

## 2. Channel rule

- Use the coordinator's designated dispatch channel and end each delegated turn with a
  question, status, escalation or completion message. Source: the decision record (#119),
  which also states that a coordinator reads the cards addressed to its own dispatch and arms
  its own wake-up for each pending external result.

## 3. Review discipline

- Early independent Contract reviews found, among other issues, renewal timing, provider
  cleanup assumptions, missing classifier laws and registry identity concerns; reviewing before
  implementation can expose these before the design is built. Source: the ELZ-027, ELZ-028,
  ELZ-029 and ELZ-031 early-review records under `docs/work/`.
- A change to a live issue body is proposed as exact before/after text on the issue before the
  edit and decided by the main coordinator; the editing worker syncs the task copy bytewise
  and the roadmap hash in the same commit. Live-body edits are one per approved round per
  task. Source: `AGENTS.md` ("change the Contract and acceptance deliberately with review"),
  the ELZ-027 and ELZ-031 contract-proposed records, and the decision record (#119).
- When a live issue body changes before the matching manifest update merges, the live roadmap
  check on main can fail until they agree; coordinate and reconcile manifest changes before
  merge. A task whose live body changed queues its PR before other manifest-touching PRs, and
  every manifest-touching PR reconciles in its final step. Source: `scripts/check-roadmap.py
  --live` compares live bodies with the manifest; the decision record (#119) states the queue
  order and the reconciliation rule.
- After a conditional review, request confirmation of the changed points at the revised SHA.
  A separate reviewer inspects the actual diff and scope, as a separate agent session on a
  different model where possible; retain the review or a marked redaction with the original
  SHA-256. Source: the ELZ-027, ELZ-028 and ELZ-031 review and confirmation records and the
  decision record (#119).

## 4. Automated and independent review

- Independent review is required for the protected boundaries and evidence claims named in
  `AGENTS.md`, and whenever the task requires it; straightforward prose or mechanical test
  changes may not require it. Source: `AGENTS.md`, "Review, merge and cleanup".
- The decision record (#119) adds: every finding of the repository's automated reviewer on a
  PR (the task Contract names the Devin Review app) is answered or fixed with a one-line
  disposition before the queue is requested, recorded in the PR body. The decision record does
  not give an observed reason for this rule.

## 5. Public-repository writing

- For a review containing non-public operational details, publish a marked redaction and
  record the SHA-256 of the original. Keep credentials and connection strings out of public
  records and use the designated private channel to share them. Source: the ELZ-027 and
  ELZ-031 redaction records under `docs/work/` and the decision record (#119), which states the
  owner's rule for the public repository: no hostnames, addresses, domains, local filesystem
  paths, database names, credentials, agent-platform session identifiers or machine
  inventories in issues, PRs, comments or committed files; roles instead of identities; local
  evidence by repository path or SHA-256. The record adds that standard tool attribution lines
  and commit trailers are not private information. The record does not give an observed
  failure behind this rule; it is the owner's decision for the publication.

## 6. Agent identifier

- Do not derive the identifier from a hostname; the claim comment on the issue names the
  branch, the base SHA and the identifier (since ELZ-076 the pushed branch is the claim and no
  marker file or claim commit exists). Source: `AGENTS.md` claim procedure and the decision
  record (#119). Earlier claim commits remain in Git history, so public history can expose a
  hostname-derived identifier from before the rule (an inference, not a recorded quotation).

## 7. Evidence packet

- Record the evidence applicable to the task: its Contract and decisions, review findings and
  dispositions, any provider probes, exact executed commands and outcomes, task-copy and
  manifest synchronization where applicable, and the PR grounding categories and limits
  required by `AGENTS.md`. Distinguish failed checks and their diagnosed causes from passing
  runs. Source: `AGENTS.md`, "Verify the actual claim"; the ELZ-028 re-review record shows the
  risk of presenting planned or partial evidence as established.
- The decision record (#119, rule 8) names the packet a finished task leaves: proposal and
  Contract reading; exact review reports with dispositions; probe records for provider
  comparisons; the executed check record with exit codes, counts and the marker; the
  publication copy byte-equal to the live body; the PR body in the AGENTS report format with
  grounding categories kept separate; environment failures disclosed as such.

## 8. Merge queue operation

- Avoid dispatching a check by hand while the queue identifies its run; if the queue stops
  while its run is in progress, inspect or manually adopt the identified run before dispatching
  another; the queue retries certain transient reads but does not automatically resume from
  that run. Source: `docs/development/10-symbolic-ci.md` and `scripts/merge-queue.py`.
- Run measurement series on a slow or idle runner; while a merge queue is pending, run at most
  one series at a time. State the expected duration and stay under the backend job's 90-minute
  limit. Source: `docs/development/10-symbolic-ci.md` and the decision record (#119), whose
  rule 7 was amended on 2026-11-09 to this wording after a conflict between the two was found.
- The decision record (#119) states that only the main coordinator runs
  `scripts/merge-queue.py`, one PR at a time.
