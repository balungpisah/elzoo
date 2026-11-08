# ELZ-063 — Add the provider/consumer responsibility table to docs/consuming.md

- Phase: documentation
- Catalogue IDs: none (consuming contract documentation)
- Dependencies: ELZ-050

## Outcome

Add one table to `docs/consuming.md` that states, row by row, what the Elzoo catalogue
provides to a consumer (source bundles with contracts, tests, examples and licenses; receipts
with origin commit, hashes and tested provider versions; install snippets; the Cure compiler
source and its registration instructions; evidence recorded at the origin revision) and what
the consuming application provides itself (its Mix project and lockfile resolution, its
Application and supervisor tree, configuration and test helper, every declared Need such as
databases, credentials and endpoints, its effect, delivery and persistence choices, namespace
and record-tag renaming when redistributing, and rerunning boundary tests after edits or
updates). The table summarizes the existing text of that document; it changes no Contract,
command or claim. Documentation only: no source, test, pin, registry, manifest or ledger
change. Acceptance: the table is present and consistent with the surrounding sections;
`python3 scripts/check-roadmap.py`, `python3 scripts/check-claims.py` and `git diff --check`
pass; one narrow independent review records that no new claim is introduced. This closes
the main coordinator's condition recorded on the ELZ-050 queue (2026-11-08).
