# ELZ-337 — The same-model Reviewer line keeps the role and model

- Dependencies: ELZ-311

## Outcome and scope

Repair defect #793, by the owner's decision of 22 November 2026. `AGENTS.md`
section 6 asks that the review comment names the model of the reviewer. But
the first line of the five-line record template,
`Reviewer: <role>; <model> | same model, different session (no other model family available)`,
gives the same-model case as an alternative to `<role>; <model>`, and
elsewhere in the template `|` separates exclusive alternatives. The fallback
sentence of the same section says that the Reviewer line then reads
`same model, different session (<why the other-family reviewer could not run>)`,
and shows no role or model. Read that way, a same-model record may leave out
both.

This is a coordinator one-PR documents change. Owned paths: `AGENTS.md`
section 6 (the template's first line, the fallback sentence of the bullet "Do
not wait on an unavailable automated reviewer", and any other line of section
6 that implies a same-model record may leave out the role or model), this
task file, its no-output job row in `docs/plans/release-plan.json`, and the
generated `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No other
rule, Contract, Piece or catalogue entry changes.

## Required behavior

1. The template's first line reads
   `Reviewer: <role>; <model>[, same model, different session (no other model family available)]`.
2. The fallback sentence shows the role and model: the Reviewer line then
   reads
   `<role>; <model>, same model, different session (<why the other-family reviewer could not run>)`
   instead of the template's parenthesis.
3. Any other line of section 6 that implies a same-model record may leave out
   the role or model is repaired the same way. No other wording changes.

## Acceptance and evidence

Documents-only classification (`scripts/ci-change-class.py`), live roadmap,
claims and diff checks, one independent review, a green exact-head docs-only
hosted check, the PR marked ready and the automated reviewer's gate of
`AGENTS.md` section 6. The coordinator merges on a green `main`.
