# ELZ-227 — The root README, the dependency register, the bot platform plan and one production record say what is true on `main`

- Dependencies: ELZ-033
- Output: none. No output Piece ID and no Piece Contract change.
- Change class: documents only; roadmap and claims checks and the docs-only hosted check. Published task or coordinator one-PR path.
- Allowed implementation path: `README.md` (root), `docs/dependencies.md`, `docs/plans/bot-platform.md` (one sentence), `docs/work/ELZ-023-production.md` (one line; this task names the file as a deliverable, as `AGENTS.md` section 4 requires). Not `docs/consuming.md`: code reads it, see ELZ-230.

Facts checked on `main` (confirm each when you start):

- The repository is public, and `main` is protected: required checks
  `check-hosted` and `gleam-hosted`, force pushes off, no required
  review (GitHub API, 2026-11-14).
- `README.md:34-35` says "an account with access to the private
  repository"; `:76-78` says the plan "does not support protected
  branches for this private repository"; `:80-81` names ELZ-002 as the
  first open task (issue #2 is closed); `:109` says "Private development
  repository"; `:112` says "The private repository's access permissions
  are unchanged."
- `mix.exs` has 26 direct dependencies. `docs/dependencies.md` names 12.
  Not named: `carbonite`, `crontab`, `decimal`, `ex_mcp`, `fuse`,
  `gen_smtp`, `pgvector`, `prometheus`, `req_llm`, `req_s3`,
  `server_sent_events`, `swoosh`, `text_chunker`, `tz`.
- `docs/dependencies.md:52-54`: "OpenTelemetry remains a candidate.
  Telemetry is transitive, with no adopted business-event contract."
  `mix.exs:72` pins `telemetry` 1.4.2 as a direct dependency (provider
  of `runtime/telemetry`, ELZ-052), and `:74` pins `prometheus` 6.1.3
  (ELZ-107). No `opentelemetry` package is in `mix.exs`.
- The test `scan_agrees_with_the_reader` of `workflow/skill` calls
  `:yamerl_parser.string/2` in test files only
  (`pieces/workflow/skill/test/elzoo/skill_differential_test.exs:76`;
  `piece.json` of the Piece states it). The register does not.
- `docs/plans/bot-platform.md:79` ends "RC-46 and RC-48 remain
  proposals." In `docs/plans/release-plan.json` RC-46 is superseded by
  the published ELZ-122 and RC-48 by ELZ-124.
- `docs/work/ELZ-023-production.md:163` says "Exact final commands, each
  exit 0:" over commands whose database URL is replaced by placeholders.

## Changes

**1. `README.md`.**

- Lines 34-35. Old: "install GitHub CLI and authenticate an account with
  access to the private repository:". New: "install GitHub CLI and
  authenticate an account that may push task branches:".
- Lines 76-78. Old: "The current GitHub plan does not support protected
  branches for this private repository, so agents must observe the
  documented review/check requirements before merging." New: "`main` is
  a protected branch: it requires the checks `check-hosted` and
  `gleam-hosted` and refuses a force push. The review rule and the merge
  queue are in [AGENTS.md](AGENTS.md), sections 6 and 7."
- Lines 80-81. Old: "The first open task is [ELZ-002: contracts and
  typed composition](...)." New: "Open tasks are the GitHub issues with
  the label `task`; [AGENTS.md](AGENTS.md) section 2 shows how to pick
  one."
- Line 109. Old: "Private development repository:". New: "Development
  repository:".
- Line 112. Delete the sentence "The private repository's access
  permissions are unchanged."

**2. `docs/dependencies.md`.**

- Add a section "Direct dependencies of `mix.exs`" with one table row
  for each of the 26: name, exact pin (from `mix.exs`), license (from
  `registry/providers.json`), the Pieces or the root test that use it
  (from the `providers` of each `piece.json` and the comments in
  `mix.exs`), and its use in one short phrase. Write no claim that a
  `piece.json` or a root test does not carry. Keep the existing prose.
- Replace the two sentences of lines 52-54 with: "OpenTelemetry is not
  a dependency; it remains a candidate. Telemetry 1.4.2 is a direct,
  pinned dependency, the provider of `runtime/telemetry`; Prometheus
  6.1.3 is the provider of `integration/observability`. See the table."
  Confirm the two Piece IDs against their `piece.json` first.
- At the end of the section "YAML reader for skill frontmatter" add:
  "Test only (ELZ-182, group `scan_agrees_with_the_reader`):
  `yamerl_parser:string/2` with the option `{token_fun, Fun}` (exported
  and on hexdocs of yamerl 0.10.0; the option is defined in the
  internal header `include/internal/yamerl_parser.hrl` and not expanded
  by the docs) gives the parser tokens as the oracle of the frontmatter
  scan. No product file calls it, and a pin change must run the positive
  control of the oracle again."

**3. `docs/plans/bot-platform.md:79`.** Old: "RC-46 and RC-48 remain
proposals." New: "RC-46 is admitted as
[ELZ-122](../../tasks/ELZ-122-dynamic-units.md) and RC-48 as
[ELZ-124](../../tasks/ELZ-124-bot-run-lifecycle.md)."

**4. `docs/work/ELZ-023-production.md:163`.** Old: "Exact final
commands, each exit 0:". New: "Final commands, each exit 0 (exact, but
the role, the password and the database name of the URL are replaced by
placeholders):".

## Acceptance

- Each old text is gone and each new text is in its place; the diff
  holds no other change of meaning.
- Evidence for the table, in the pull request body: a one-off listing
  that each name after `{:` in the dependency list of `mix.exs` occurs
  in the new section, and that each pin in the table equals `mix.exs`.
  The script is not committed.
- No word "private" about the repository remains in `README.md` (`grep
  -n -i private README.md`; a hit about another subject is explained in
  the body).
- `python3 scripts/check-roadmap.py`, `python3 scripts/check-claims.py`,
  `python3 scripts/test-ci-change-class.py` and `git diff --check` exit
  0; `python3 scripts/ci-change-class.py range origin/main HEAD` prints
  `true`; the docs-only hosted check is green.
- One independent review: it checks five rows of the table against
  `mix.exs`, `registry/providers.json` and the named `piece.json`.

## Review risk

Low. The table can state a use that no manifest carries; the reviewer
samples it.

## Not in scope

`docs/consuming.md:179` (ELZ-230). The record of `assembly/tenant-edge`
in `docs/plans/catalogue-dispositions.md:203`: that file is generated
from records of 2026-11-08 for 53 entries, 35 of which are still planned
or deferred, so it cannot be rendered again without a wider change; the
record is corrected when RC-40 is admitted. The stale Limits of
`workflow/agent-loop`, `workflow/graph-run` and `workflow/typed-decision`
(Piece tasks). The candidate tables of the register.
