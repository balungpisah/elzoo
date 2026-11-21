# ELZ-311 — A reviewer of another model family replaces an unavailable automated reviewer

- Dependencies: ELZ-307

## Outcome and scope

Record the owner's decision of 21 November 2026. When `AGENTS.md` section 6
lets the coordinator skip the automated reviewer, a reviewer of another model
family does the extra review that replaces its pass: GPT-6.1 Terra
(`openai/gpt-6.1-terra`) at high reasoning effort. A fresh session of the same
model does it only when that reviewer cannot run, and the record says why. The
trigger for a skip does not change. Builders and the main section 6 review are
unchanged.

This is a coordinator one-PR documents change. Owned paths: `AGENTS.md`
section 6 (the bullet "Do not wait on an unavailable automated reviewer" and
the bullet about the other-family recheck), `docs/development/13-coordinator.md`
(the "Skipped automated reviews" paragraph above its table), this task file,
its no-output job row in `docs/plans/release-plan.json`, and the generated
`LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No other
rule, Contract, Piece or catalogue entry changes.

## Required behavior

1. In `AGENTS.md` section 6, the extra review that replaces an unavailable
   automated reviewer's pass is done by a reviewer of another model family
   (GPT-6.1 Terra at high effort). A fresh session of the same model does it
   only when that reviewer cannot run, for example when its subscription is
   refused, and the record names the reason.
2. Before its verdict, that review reads `AGENTS.md`, the change's task file
   and its Contract (the issue body, and for a Piece its `piece.json` and
   README). Its findings cite the rule lines it checked: the `AGENTS.md`
   section and line numbers, and the task-file or Contract lines each
   finding, or its "none", rests on.
3. The section 6 bullet on the one-time other-family recheck of
   `domain/journal`, `domain/metering` and `delivery/dead-letter-store`
   names the same reviewer, under the same reading and citation rule. Each
   finding still becomes its own task.
4. In the coordinator guide, a listed range may also be rechecked by that
   other-family reviewer, under the same reading and citation rule. A row is
   removed only after the automated reviewer or that reviewer posts findings
   or an explicit no-findings result for the range. Each finding still
   becomes its own task.
5. The skip triggers, the 30-minute window, the five-line record, the weighted
   Piece rule and every other rule are unchanged.

## Acceptance and evidence

Documents-only classification (`scripts/ci-change-class.py`), live roadmap,
claims and diff checks, one independent review, a green exact-head docs-only
hosted check, and the PR marked ready. The coordinator merges on a green
`main`.
