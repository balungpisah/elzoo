# Coordination rules for long-running parallel work

These rules were learned while four implementation tasks ran in parallel on 2026-11-08 and
2026-11-09 under one main coordinator and one pieces coordinator. Each rule names the reason
that was observed and what breaks when the rule is ignored. They are operating rules for the
people and agents running the workflow; they change no Contract, command or check. Task
records under `docs/work/` for ELZ-027, ELZ-028, ELZ-029, ELZ-031, ELZ-050 and ELZ-063 hold
the observations. The owner's priorities and the live task bodies still decide what is built.

## 1. Worker caps

- At most three task workers run Mix at the same time on one host. More than that drove the
  host load above its core count and slowed every check.
- At most one bare `mix check` runs at a time on one host. The shared local PostgreSQL server
  allows 100 connections; two concurrent full checks exhausted them, and both runs failed in
  the copied-consumer database tests with `too_many_connections` although no Piece test
  failed. Such a run is an environment failure, disclosed as such in the PR, never a test
  failure and never hidden.
- One disposable database per worker, named by role in any public text. A fail-closed guard
  verifies the effective target before the first statement; a supplied URL is not sufficient.
- Shared files are touched only with explicit authorization and only for the task's own row
  or entry: `registry/catalogue.json`, `docs/plans/release-plan.json`, `mix.exs`,
  `registry/providers.json`. `LEDGER.md` and the roadmap views are regenerated in the final
  merge step, and the main coordinator merges PRs that touch the manifest in an order that
  keeps the regenerated files consistent.
- An idle, held worker does not count against the cap.
- The caps are per host. They are re-measured whenever the CI lane or the host changes: a
  hosted CI lane removes the runner scarcity, not the local database limit.

## 2. Channel rule

- A coordinator reads the cards addressed to its own dispatch, which the plain inbox command
  shows. Replies on question threads and messages to a session inbox did not reach the
  coordinator; three decisions and four review requests sat unread for that reason.
- Every delegated agent ends each turn with a message to its coordinator: a question that
  blocks it, a status with the pushed revision and the next action it waits for, an
  escalation, or its completion report. A pushed branch without a message is invisible.
- The coordinator arms its own wake-up for every pending external result (a review, a CI run,
  a merge, a worker) instead of waiting to be woken. A single missed wake-up stalled the queue
  for an hour once.

## 3. Review discipline

- An independent early Contract review happens before implementation. In four of four tasks
  it found design defects the proposal author had not seen (a renewal that could commit after
  expiry, a process-group design that contradicted the provider's source, a proof that did
  not target the production function, a forgeable registry version).
- Any change to a live issue body is proposed as exact before/after text, posted on the issue
  before the edit, and decided by the main coordinator. The editing worker syncs the task copy
  bytewise and the roadmap hash in the same commit. Live-body edits are limited to one per
  approved round per task.
- Editing a live body makes `check-roadmap.py --live` red on main until that task's PR
  merges, because the new hash lives only on the task branch. Such PRs are queued before other
  PRs that touch the manifest, and every manifest-touching PR reconciles in its final step.
- After a conditional review, a narrow confirmation limited to the named points replaces a
  full round. Rewordings proposed by a reviewer go back to the main coordinator for approval
  even when the substance was already approved.
- The reviewer is a separate agent, on a different model where possible, and reviews the
  actual diff and the claimed scope. The reviewer's report is stored byte-exact in `docs/work/`
  with its redactions marked and the original's SHA-256 recorded.

## 4. Devin Review rule

- Every finding the Devin Review app posts on a PR is answered or fixed before the queue is
  requested, with a one-line disposition per finding on the PR and the line
  "Devin Review: N findings, all dispositioned" in the PR body under Grounding.
- The independent review stays required for protected surfaces, Contracts, evidence claims and
  storage or delivery boundaries. Documentation-only or mechanical changes need Devin plus the
  worker's own checks and no separate review session.

## 5. Public-repository writing rule

- Issue bodies, PR bodies, comments and committed files carry no hostnames, addresses,
  domains, local filesystem paths, database names, credentials, agent-platform identifiers or
  machine inventories. Machines, people and agents are named by role; local evidence by
  repository path or by SHA-256.
- Review copies committed under `docs/work/` are redacted to role words, with a header that
  records the SHA-256 of the unredacted original.
- Credentials and connection strings reach workers only through the private coordination
  channel, and the environment variable is named, never its value.

## 6. Agent identifier

- `ELZOO_AGENT` is role-based, for example `worker-` followed by a short random suffix. It is
  never derived from the hostname. Claim markers and claim comments carry only that identifier.

## 7. Evidence packet per task

A finished task leaves this packet, all written for a public reader:

- the proposal and Contract reading in `docs/work/<ID>.md`, with the gates adopted verbatim;
- every review report, byte-exact or redacted with the original's hash, and the author's
  disposition of each finding;
- probe records for provider comparisons, with versions, licenses, exact scenarios and outputs;
- the executed check record: commands, start and end times, exit codes, test counts and the
  `ELZOO CHECK PASSED` marker, with environment failures disclosed as such;
- the publication copy under `tasks/` byte-equal to the live issue body, and the roadmap hash;
- the PR body in the AGENTS report format, with proofs, type checks, tests, monitored behavior,
  upstream contracts and assumptions kept separate, and the limits stated.

## 8. Merge queue operation

- Only the main coordinator runs `scripts/merge-queue.py`, one PR at a time. Nobody dispatches a
  check by hand while the queue identifies its run.
- When the queue stops on a transport failure with its run still in progress, it is resumed by
  adopting that run; the queue's own retries reduce how often this is needed.
- Measurement series on runners are budgeted: one at a time, never while a queue run is
  pending, on the slow or idle runner, and under the 90-minute job limit.
