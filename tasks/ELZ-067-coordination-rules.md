# ELZ-067 — Record the coordination rules for long-running parallel work

- Phase: documentation (workflow hygiene)
- Catalogue IDs: none
- Dependencies: ELZ-050

## Outcome

Record in `docs/development/` the operating rules the coordinators learned while running four
implementation tasks in parallel on 2026-11-08 and 2026-11-09, so a future coordinator does not
relearn them: the worker caps and their reasons, the message channel a coordinator must read,
the review discipline for Contracts and evidence, the Devin Review rule, the public-repository
writing rule, the role-based agent identifier, and the shape of a task's evidence packet. This
is documentation only. It changes no Contract, command, check or pin. `AGENTS.md` changes only
where a sentence is wrong today (the hostname-based agent identifier; the hosted-runner ban once
CI moves to hosted runners), and that diff goes to the main coordinator before it is applied.
The owner closed the build queue on 2026-11-09; this task is the last before the queue reopens.

## Scope

- Add `docs/development/11-coordination-rules.md` with these sections, each stating the rule,
  the reason observed, and what breaks when it is ignored:
  1. Worker caps: at most three task workers running Mix at once; one local full `mix check` at
     a time because the shared PostgreSQL server allows 100 connections and two concurrent full
     checks exhaust it (observed as `too_many_connections` failures in the copied-consumer
     tests); one disposable database per worker, verified by a fail-closed guard before any
     statement; shared files (`registry/catalogue.json` own row, `docs/plans/release-plan.json`
     own entry, `LEDGER.md`, roadmap views, `mix.exs`, `registry/providers.json`) touched only
     with explicit authorization and regenerated in the final merge step; idle held workers do
     not count against the cap. The caps are per host and are re-measured whenever the CI lane
     or the host changes: a hosted CI lane removes the runner scarcity but not the local
     database limit.
  2. Channel rule: a coordinator reads the cards addressed to its own dispatch (the plain
     inbox), not question-thread replies or a session inbox; every delegated agent must end
     each turn with a message (ask, status, escalation or done), and the coordinator arms its own
     wake-up for every pending external result instead of waiting to be woken.
  3. Review discipline: early independent Contract review before implementation; exact
     before/after text for any issue-body change, posted on the issue before the edit, decided
     by the main coordinator; live-body edits one per approved round per task; the live roadmap
     check is red for a task whose body changed until its PR merges, so such PRs queue before
     other manifest-touching PRs and every manifest-touching PR reconciles in its final step;
     narrow confirmations after a conditional review instead of full rounds; the reviewer is a
     separate agent on a different model where possible.
  4. Devin Review rule: every finding on a PR is answered or fixed with a one-line disposition
     before the queue is requested, recorded in the PR body; our independent review stays
     required for protected surfaces, Contracts, evidence claims and storage or delivery
     boundaries, and is not needed for documentation-only or mechanical changes.
  5. Public-repository writing rule: no hostnames, addresses, domains, local filesystem paths,
     database names, credentials, agent-platform identifiers or machine inventories in issues,
     PRs, comments or committed files; roles instead of identities; local evidence by repository
     path or SHA-256; review copies redacted with the original's hash recorded; credentials only
     through the private coordination channel.
  6. Agent identifier: `ELZOO_AGENT` is role-based (`worker-<random>`), never derived from the
     hostname.
  7. Evidence packet shape per task: proposal and Contract reading, exact review reports with
     dispositions, probe records for provider comparisons, the executed check record with exit
     codes, counts and the marker, the publication copy equal to the live body, and the PR body
     in the AGENTS report format with grounding categories kept separate; environment failures
     (for example connection exhaustion from concurrent checks) are disclosed as such, never as
     test failures and never hidden.
  8. Merge queue operation: only the main coordinator runs `scripts/merge-queue.py`, one PR at
     a time; nobody dispatches a check by hand while the queue identifies its run; when the
     queue stops on a transport failure with its run still in progress, it is resumed by
     adopting that run (the queue's own retries reduce this); measurement series are budgeted:
     at most one at a time while a merge queue is pending, on the slow or idle runner, under
     the 90-minute job limit.
- Link the new document from `docs/development/01-workflow.md` with one sentence.
- Propose the `AGENTS.md` diff (agent identifier sentence; the hosted-runner sentence if the
  hosted lane has merged by then) as exact before/after to the main coordinator; apply only the
  approved text.

## Acceptance

- [ ] `docs/development/11-coordination-rules.md` exists with the eight sections and a link from
      the workflow document.
- [ ] Every rule names the observed reason and the failure it prevents; no rule claims a
      guarantee the tooling does not enforce.
- [ ] `python3 scripts/check-roadmap.py`, `python3 scripts/check-claims.py` and `git diff --check`
      pass; no path outside `docs/`, `tasks/` and the approved `AGENTS.md` lines changes.
- [ ] One narrow independent review confirms the rules match what the task records of
      ELZ-027, ELZ-028, ELZ-029, ELZ-031, ELZ-050 and ELZ-063 show.

## Evidence and limits

Documentation checks only; the rules are observations from one night of work and from the
decisions the main coordinator and the owner took, not a guarantee of future tooling behavior.

## Out of scope

Workflow or script changes, CI lane changes, new Pieces, any change to task Contracts.
