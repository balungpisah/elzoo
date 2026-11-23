# ELZ-355 — Plan Wave 9, More tools, doors, models and money, and record that Wave 8 is accepted

- Dependencies: ELZ-349

## Outcome and scope

Write the planning input for Wave 9 ("More tools, doors, models and money")
of the P13 track, in the form that `docs/plans/bot-platform-wave8.md` used
for Wave 8 (ELZ-342), so that its levels can be published as tasks after the
owner answers its questions. Wave 8 is accepted: its root consumer
acceptance ELZ-349 is merged on `main` (`2a02e1e5`). The owner gave a
standing go to plan and build the remaining waves. The plan publishes no
Piece task and promotes nothing to ready.

Wave 8's closure is not yet recorded in the form that ELZ-341 used for
Wave 7, so this task also records it. This is a coordinator one-PR
documents change: publication and implementation share one `task/ELZ-355`
pull request, and it takes the documents check.

Owned paths:

- `docs/plans/bot-platform-wave9.md`: a new page;
- `docs/plans/bot-platform-wave8.md`: a new section, "Wave 8 closure and
  open handoff", after "Status and scope";
- `docs/plans/bot-platform.md`: the heading and the Wave 8 and Wave 9
  sentences of the "Waves 4 to 9" paragraph, a plan link in the Wave 9 rows
  of its two wave tables, and the row "The language of model-written code"
  of its decision table, which points to the Wave 9 question;
- `docs/choices.md`: a new section, "Limits of the Wave 8 acceptance
  (ELZ-349)", after "Wave 8 owner choices (2026-11-23)".

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

If the automated reviewer is skipped for this pull request (`AGENTS.md`
section 6), the skip comment is posted on the pull request and the
coordinator files its row in a later change of the coordinator guide; this
task does not edit `docs/development/13-coordinator.md`.

## Required behavior

### The Wave 9 plan

1. The page has "Status and scope" with "Settled owner decisions",
   "Source boundaries checked" (facts read from ready manifests and sources
   at a named `main` commit), "All candidate handles" (one disposition for
   each handle of the Wave 9 rows of both tables in `bot-platform.md`: new,
   extend in place, reuse, absorbed or deferred), "Deferred items folded
   in", "Dependency levels", "Provider prerequisites and open questions",
   and "What remains after Wave 9".
2. It starts from the pruned Wave 9 core in `bot-platform.md` as a proposal,
   not a decision, and does not turn each handle into a Piece. A handle that
   ready Pieces already serve is marked reuse or composition, with the
   Pieces named. A new Piece is proposed only for policy that is missing,
   and an in-place extension of a ready Piece is preferred before the first
   release (`AGENTS.md` section 4).
3. The plan carries these owner decisions as settled, and asks no question
   about them: the Wave 9 saga rules of 2026-11-21 for
   `assembly/ledger-checkout` and `domain/payment-lifecycle` (each
   compensation registered with the step that succeeded, reverse order by
   default, parallel only where declared, each idempotent with its own key,
   a failed compensation its own recorded outcome); the retry delay taken
   from the failure, which `delivery/retry-timeout` gains in place for
   results that were not dispatched only, with optional jitter and
   `delivery/model-routing` as first caller, through a published task that
   changes the ready Contract; subscriptions in Wave 9 (`domain/plan`,
   `domain/invoice`) composing the Wave 6 metering, pricing, quota and money
   Pieces, with pay-as-you-go, quota-capped and prepaid staying
   compositions; RC-59's bearer-first runtime MCP servers, with OAuth
   through `integration/oauth-client` in Wave 9; and the standing "no
   corner" rule.
4. "Deferred items folded in" decides each deferred item that the plans,
   `docs/choices.md` or the open issues map to Wave 9, at least RC-24,
   RC-25, RC-28 and RC-41, the open decision "the language of model-written
   code", the individual channel adapters, and the Wave 8 handoff items
   (#821, #834, #843 and the kept-open ELZ-351 option) where they touch
   Wave 9.
5. Each proposed job names its dependencies (task IDs), its new external
   dependency or "none", a Contract sketch, its acceptance with negative
   controls sized to its risk, and the options that it keeps addable in
   place under the "no corner" rule. A Contract sketch that depends on an
   open question says so.
6. The last level is a mandatory root consumer acceptance with no Piece
   output, in the form of ELZ-338 and ELZ-349.
7. Each product or provider choice that needs the owner is one numbered
   question with lettered options and a recommendation; the language of
   model-written code is one of them unless the sources show it answered. A
   new dependency or changed pin is its own provider task that merges
   first.
8. "What remains after Wave 9" lists, without planning it, what remains for
   Elzoo to be complete after the last wave of the table: at least the first
   release with its frozen record fixtures (owner decision of 2026-11-21),
   the deferred, demand-led rows, and the open repairs carried forward.

### The Wave 8 closure

9. The closure section lists the merged Wave 8 tasks by level with the
   `main` commit whose push check is green: the plan ELZ-342 (#818); Level 1
   ELZ-344 (`delivery/durable-mailbox`, #829), ELZ-345
   (`workflow/turn-policy`, #830), ELZ-346 (`workflow/delegation`, #827) and
   ELZ-347 (`workflow/work-item`, #828), published in #826; Level 2 ELZ-348
   (`delivery/room`, #832, #833); Level 3 the root acceptance ELZ-349 (#836,
   #837, merged at `2a02e1e5`; the push run 45226804167 on `2a02e1e5` is
   green and reused the exact-head full check 45221792663, because the merge
   tree equals the reviewed head `8b1677cb`). It names the repairs merged
   during the wave, ELZ-343 (#819, #820) and ELZ-350 (#839, #840), and the
   coordinator corrections set in the published task texts.
10. It repeats the Limits of the ELZ-349 task file and its report
    (`docs/research/wave8-bots-talk.md`) and claims no more than that
    report's finite tested composition.
11. It records the open handoff, none of it blocking Wave 9 planning:
    #821, #834, #843, the in-place run-engine option ELZ-351 (#841) and the
    role-guard repairs ELZ-352 to ELZ-354 (#845 to #847), with their state
    on `main` when this task merges.
12. `bot-platform.md` states that Waves 4 to 8 are merged, points to the
    closure section and to the Wave 9 plan, and keeps the serial rule.
13. `docs/choices.md` gains "Limits of the Wave 8 acceptance (ELZ-349)" in
    the form of the Wave 7 limits section.

The Wave 4 to Wave 7 closures are unchanged. No Contract, task, Piece or
catalogue row changes, and no other plan text changes.

## Acceptance and evidence

1. The diff changes only the owned paths, this task file, its job row and
   the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py` (plain, `--write` and `--live`),
   `python3 scripts/check-claims.py` and `git diff --check` pass.
4. One independent review of the dispositions, the source facts against the
   ready manifests, each Contract sketch under the "no corner" rule and the
   closure claims against the merged pull requests, a green exact-head
   hosted documents check, the PR marked ready and the automated reviewer's
   gate of `AGENTS.md` section 6. The coordinator merges on a green `main`.
