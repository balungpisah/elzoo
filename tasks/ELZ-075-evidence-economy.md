# ELZ-075 — Coordination rules: evidence economy and the redundancy audit of 2026-11-09

- Phase: P0 harness (documentation only; `docs/development/11-coordination-rules.md`, this task copy)
- Catalogue IDs: none
- Dependencies: ELZ-067 (#119) merged (the coordination rules document exists); ELZ-059 (#99) and ELZ-071 (#131) merged (the pull request run is the merge evidence; documentation-only pull requests take the short check).
- Review: documentation only; no independent review. Automated review findings dispositioned in the PR.

## Outcome

On 2026-11-09 the owner questioned a measurement rule of ELZ-073 ("three BEFORE and three AFTER runs") and asked that the lesson be stamped into the workflow and that other redundant steps be found. This task records the lesson as a coordination rule and lists the redundant steps found in the day's process, each with its source of truth and the decision that removes or keeps it. Rules that change `AGENTS.md` are not changed here; they are listed as pending owner decisions.

## Scope

1. Add section 9, "Evidence economy", to `docs/development/11-coordination-rules.md`:
   - Before a measurement is specified, the evidence that already exists is listed and used as the baseline; new runs are produced only for what has no history (a new run shape, or the changed code revision under measurement). Sample size follows the observed variance against the decision margin. Source: the ELZ-073 rule change of 2026-11-09 (#136): more than ten full hosted runs of the day already carried per-stage timings, so the planned BEFORE runs were dropped; the AFTER runs stay at three because the day's full runs spread from 17 to 24 minutes against a margin of about 4 minutes.
   - Reviewer sessions are spent on code and on new evidence claims; the transcription of already-reviewed claims into a work record, PR body or task copy is checked mechanically by the coordinator (byte equality, hashes, the required lines), not by a reviewer pass. Source: ELZ-028 (#123) needed nine review passes, of which three concerned only the transcription of the evidence record.
   - Where one fact lives in two places, the rule names the source of truth and the other copy is derived or dropped. The pairs found on 2026-11-09 and their disposition are listed in the section (see item 2).
2. The redundancy audit, recorded in the same section as a table (step, why it is redundant, source of truth, disposition):
   - Local full `mix check` before every push, beside the hosted full pull request run and the queue's exact-head run: three copies of one evidence. Pending owner decision (changes `AGENTS.md`): the local gate becomes `mix check --affected <base>` plus the Piece's own tests; CI owns the full run.
   - A narrow reviewer pass after every small fix, including record-only commits: replaced by the rule above (code only); fixes are batched into one review round where the Contract allows.
   - The PR body kept byte-identical to the work record's check section: the work record is the source; the PR body quotes the checked SHA, the exit codes, the marker and the review-records link, and links the record.
   - The task copy under `tasks/` kept byte-equal to the live issue body with a pinned hash: both are kept for now because `scripts/check-roadmap.py --live` enforces the pin and the public record needs the issue; pending owner decision whether the repository file becomes the source and the issue body a summary with a link.
   - The claim marker commit followed by a removal commit (two commits per task; the documentation-only PR #139 needed both for a one-file change): pending owner decision (changes `AGENTS.md`) whether the pushed branch name is the claim.
   - The host "full-check slot" granted by the pieces coordinator: it exists only because of the local full check; it goes with that rule.
   - The Gleam check on every push to `main` (about one minute): kept; it is cheap and the path gate already covers pull requests.
   - The exact-head rerun when `main` moved by a disjoint merge: kept; it is the evidence rule, and changing it ("merged after a green sibling") is an owner decision listed under ELZ-073's follow-ups.
3. Amend rule 8 (merge queue operation): the measurement sentence written for self-hosted runners ("run measurement series on a slow or idle runner") is replaced by the hosted-lane wording: measurement runs are free and parallel but are run one at a time per shape when they share a cache key, and never while they would be mistaken for queue evidence.

## Acceptance

- [ ] `docs/development/11-coordination-rules.md` has section 9 with the three rules and the audit table; rule 8 amended; every row names its source (a run, a PR, an issue or a decision).
- [ ] No hostname, address, local path, database name, credential or session id in the text (the public-repository rule).
- [ ] Documentation-only pull request merged through the short check and the queue's `mode=docs-only` line.
- [ ] Automated review findings dispositioned.

## Limits

This task records rules; it changes no command, check or `AGENTS.md` wording. The three pending owner decisions (affected gate, task copy as source, branch name as claim) are listed, not taken.
