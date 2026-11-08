# ELZ-068 — Record the public flip, the hosted measurements and the fallback in the CI guide

- Phase: P0 harness (docs only: `docs/development/10-symbolic-ci.md`, the CI policy sentence of `AGENTS.md`)
- Catalogue IDs: none
- Dependencies: ELZ-066 (#115, PR #121) merged; the flip done by the coordinator on 2026-11-09 (WIB).
- Review: docs only; Devin Review findings dispositioned in the PR.

## Outcome

The repository is public and CI runs on the hosted lane. The CI guide still describes the flip as planned and the hosted jobs as untested. This task records what happened and what was measured, and writes down the fallback.

## Scope

- **Flip record** in the "Lanes" section (replaces "Planned flip"): the order that was executed and the settings read back from the GitHub API: visibility public; 0 self-hosted runners; `ELZOO_CI_LANE=hosted`; default workflow token `read` and no pull request approval by workflows; fork pull request approval policy `all_external_contributors`; branch protection on `main` has no required status checks (the coordinator removed the rule for `check-hosted` and `gleam-hosted` at about 04:05 WIB because the queue relies on a `workflow_dispatch` run, which GitHub does not count as a pull request status; ELZ-059 is the path back), no force pushes, no deletions, not enforced for administrators, no review requirement.
- **Fallback.** If the hosted lane fails, make the repository private again and register runners again; there is no self-hosted lane on a public repository.
- **Measured figures** from the rehearsal in this repository (hosted run 1 cold, hosted run 2 warm, a hosted pull request run), with run and job IDs.
- **Status notes**: the self-hosted roles section is history (all four runners were unregistered at the flip); `AGENTS.md` policy sentence in the present tense.
- Not in scope: removal of the self-hosted jobs and of the Contabo and MacBook sections (the later cleanup PR).

## Acceptance

- [ ] `check-hosted` and `gleam-hosted` green on the PR (the PR check itself runs on the hosted lane).
- [ ] Every figure in the new text has a run or job ID.
- [ ] `check-roadmap.py` and `check-claims.py` exit 0.

## Limits

Docs only. The settings are the ones read on 2026-11-09 (UTC 20:49); the guide does not promise they stay.
