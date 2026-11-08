# ELZ-063 independent review

Reviewer: Codex, Orca session `orca_session_id:37180079-1b7b-4fd1-89d4-25258d6fbe9b` (task `task_695617a45d20`).
Reviewed HEAD: `6c69aad73dad806b2fd187a0fc2aecb0b3e58096`; base `origin/main` `f4e328319ec23fa7bc6d8c8f0a19c2a3122bd938`.

CONDITIONAL: reword rows 1, 2, 5, 6, 7, 8 and 9 as below and obtain review of the updated diff. The table currently introduces claims or requirements beyond its source text. This is a narrow read-only review, not acceptance of a later SHA.

## Scope and checks

- `git status --short --branch`, `git rev-parse HEAD origin/main`, `git diff --name-only origin/main HEAD`, `git log --oneline origin/main..HEAD`, `git ls-files .claims`, and `git diff origin/main HEAD -- docs/consuming.md tasks/ELZ-063-consuming-responsibility-table.md`: exit 0. The only changed paths are the two requested paths; the worktree reports clean. Claim commit `a481293` remains in history and no `.claims` file is tracked.
- `git show --stat --oneline a481293 && git show a481293:.claims/ELZ-063.md && git ls-files .claims`: exit 0; the claim marker is present in the claim commit and absent from the tracked tree.
- `gh issue view 107 -R balungpisah/elzoo --json body` piped into Python JSON decoding and byte comparison with `tasks/ELZ-063-consuming-responsibility-table.md`: exit 0; both are 1,456 bytes and byte-equal.
- `python3 scripts/check-roadmap.py`: exit 0; ROADMAP CHECK PASSED, 97 catalogue IDs, 77 jobs and 277 local links checked.
- `python3 scripts/check-claims.py`: exit 0; `No tracked claim metadata`.
- `git diff --check origin/main`: exit 0; no output.
- Python split of the `Who provides what` table on unescaped `|`: exit 0; header, separator and all ten body rows each have two columns (12 rows total). This checks consistent column count, not a screenshot of a rendered page.
- No Mix commands were run, as instructed.

## Per-row verdicts

Line references to `docs/consuming.md` are the reviewed HEAD; `docs/catalogue.md` and `AGENTS.md` are existing references. Exact suggested replacements are full rows.

| Row | Verdict | Evidence and reason |
| --- | --- | --- |
| 1. Source bundles | Reword | `docs/catalogue.md:133-135` says each bundle contains whichever source/test/example paths it needs; `docs/consuming.md:66-68` says library recipes do not pull in Cure. The row reads as if every ready Piece supplies Cure laws and all listed artifacts. |
| 2. Receipt | Reword | `docs/consuming.md:58-73` describes one receipt for a selection and pinning the recorded versions for exact reproduction. `lib/elzoo/export.ex:225-232` returns a nil revision and dirty=true if Git provenance cannot be read; claiming an origin commit unconditionally overstates copier behavior. The existing text requires boundary tests after updates; it does not require all consumers to pin or update providers. |
| 3. Install snippets | Supported | `docs/consuming.md:58-64,94-97`; the copier generates instructions (`lib/elzoo/export.ex:70-73,153-222`) and refuses to replace conflicting existing files. |
| 4. Cure compiler | Supported | `docs/consuming.md:66-68,89-90`; baseline applies to the recorded proof results. |
| 5. Evidence | Reword | `docs/consuming.md:10-16,116-121` and `docs/catalogue.md:73-76` distinguish claim-level grounding and say proof is not a badge. The list as written can imply all evidence categories exist for every Piece. |
| 6. Needs | Reword | `AGENTS.md` requires Needs to be explicit and Effects in Adapters, but does not say every listed example is a Need on each Piece, nor that every Need is supplied through configuration and never through copied source; clocks in particular may be passed as inputs (`docs/catalogue.md:179`). |
| 7. Operators and Effects | Reword | `docs/consuming.md:94-112` and `AGENTS.md` support pure Operators, explicit Adapters and application choices, but do not promise a delivery-result mapping for every Effect. `docs/consuming.md:103-104` expressly says the listed selection does not execute delivery; the blanket mapping claim should be removed. |
| 8. Namespace and record tags | Reword | `docs/consuming.md:75-88` requires renaming modules/imports/MFA or atom references/tests for library redistribution and says rename public record tags **or** translate at an Adapter and test the boundary. The row requires both tag renaming and translation wherever copies meet and omits the boundary test. |
| 9. Conflicts | Reword | `docs/consuming.md:123-126` limits pre-write detection to known conflicts and warns that copying is not a multi-file transaction; `lib/elzoo/export.ex:87-99,115-151` rechecks paths but a filesystem failure or race can occur after writes begin. Unqualified conflict detection before any write omits that limit. |
| 10. Contract IDs | Supported | `docs/consuming.md:128-135` and `AGENTS.md` section “Evolving a ready Contract” require new IDs for changed ready behavioral Contracts, migration notes, deliberate opt-in, and overlap resolution. |

## Exact replacement rows

1. `| Ready Piece bundles with the applicable source, tests, examples, README Contract and limits, piece.json claims, and Apache-2.0 license and NOTICE | Its own Mix project, mix.exs, mix.lock and dependency resolution, including transitive packages |`
2. `| A receipt per selection under .elzoo/receipts/: origin revision when available, dirty-source indicator, original file hashes, selected claims and the provider versions tested in Elzoo | Pinning recorded versions for exact reproduction and rerunning boundary tests after any update |`
5. `| Claim-level grounding and limits, including selected laws, tests, upstream contracts or assumptions where recorded in the README and piece.json | Evidence for its own edits and composition; copied evidence does not survive edits automatically |`
6. `| Explicit Needs where declared by a Piece | Supplying the external capabilities a selected Piece declares it needs |`
7. `| Pure Operators and explicit Effect and Adapter boundaries where provided | Its effects, delivery policy and persistence, and an OTP shell where a lifecycle needs a process |`
8. `| The default Elzoo.* / Cure.Elzoo.* namespace for application-owned copies and documented public record tags | Before redistributing copied source as a library, renaming modules, Cure imports, Elixir MFA/atom references and tests; explicitly renaming public record tags or translating them at an Adapter and testing the boundary |`
9. `| Known conflicts detected before writing, identical files left intact and no force replacement; copying is not a multi-file transaction | No concurrent writers against a destination, and deliberate merging of updates through a scratch project |`

Backticks may be retained around code identifiers in the final Markdown; they are omitted above for readability. The suggested rows preserve the original documents' scope and do not establish any new proof, delivery, compatibility or atomicity guarantee.
