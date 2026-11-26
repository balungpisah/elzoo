# ELZ-415 — A ready Piece improves in place under its Piece ID

- Dependencies: ELZ-411

## Outcome and scope

Owner decision of 2026-11-26: an improvement of a ready Piece does not need a
new Piece ID. This replaces the rule "from the release commit on, a changed
ready Contract gets a new Piece ID".

The new rule:

- A Piece ID names one capability. From the release commit on, a ready Piece
  keeps its ID when it improves: a raised or removed limit, a new optional
  input or output, a new operation, a new storage design, a faster path, or a
  fix.
- A change that a copy would notice is a breaking change. Examples: an
  accepted input is refused; an output, a stored format, a delivery guarantee
  or a failure guarantee changes; a required Need is added. A breaking change
  keeps the ID too. Its pull request adds an entry to the `## Changes` section
  of the Piece README: the task, what breaks, and how to move. A changed
  stored format comes with a reader of the old format or a stated migration
  step.
- A new Piece ID is only for a new capability or a split. The capability model
  decides which.
- A consumer is safe because it owns a copy. The copy changes only when the
  consumer takes again. The receipt names the revision, and `## Changes` lists
  what moved since that revision.

State the new rule in each place that states the old one:

- `AGENTS.md`: the row "New or changed Piece Contract" of the table in
  section 1 (it also says "from the first release never reuse an old ID for a
  new Contract"), and the bullet "From the release commit on, a ready Piece ID
  is a stable Contract" of section 4.
- `docs/consuming.md`: the paragraph under "The first release" (line 52), the
  table row at line 70, and the paragraph at line 172.
- `docs/choices.md`: the summary under "How a change works" (lines 16–19), the
  rule under "Deferred options" (lines 591–594), and the line "For you" at line
  1251. Add one dated decision record for 2026-11-26; earlier records stay as
  they are.
- `docs/catalogue.md`, line 4: an entry is a stable capability ID.
- Each Piece README sentence that states the old rule for a later change of
  that Piece: `core/assembly` (line 84), `core/envelope` (74), `core/port`
  (83), `core/edge` (58), `workflow/approval` (592, 594), `workflow/budget`
  (380), `assembly/http-job` (102), `delivery/effect-intent` (113),
  `domain/authorization` (109, 439, 459) and `integration/text-chunking` (38).
  Each says instead that such a change is a later change of the same Piece
  under the rule above, or a new Piece only where the capability model calls
  it a new capability. A README is not in its manifest's `files`, so no
  manifest changes for these.
- The `limits` sentence that says "needs a new Piece ID" in the manifests of
  `core/edge`, `domain/authorization` and `workflow/approval`, with the same
  meaning as their README sentences. Only that wording changes, never the
  limit itself. Each of these three manifests gets its new `manifest_sha256`
  in the `entries` row of `docs/plans/release-plan.json`.

Records of past decisions (`docs/plans/`, `docs/work/`, `tasks/`) do not
change.

This is a coordinator-owned task on the one-PR path (`AGENTS.md` section 1),
release V2, stage `later`. It changes no Piece Contract, release selector or
executable code: the Piece texts above change in wording only, and no limit
or behavior changes. `docs/consuming.md` is read by code (`Elzoo.Export`
copies it into each export), and Piece files change, so the change is not
documents-only and the full gate applies. New external dependencies: none.

- Commit this task file, its new job row with the live issue-body hash in
  `docs/plans/release-plan.json`, the three new manifest hashes, and the
  resulting generated view changes.

## Acceptance

- Each listed place states the new rule. `rg -n -i "new piece id|new id\b|reuse
  an old id|stable contract" AGENTS.md README.md CONTEXT.md docs/consuming.md
  docs/catalogue.md docs/capability-model.md pieces/*/*/README.md
  pieces/*/*/piece.json` finds no statement of the old rule; in
  `docs/choices.md` only dated records of earlier decisions keep it.
- `mix elzoo.ledger`, `python3 scripts/check-roadmap.py --write`, the plain and
  `--live` roadmap checks, `python3 scripts/check-claims.py`, `git diff --check`
  and `git diff --check origin/main...HEAD` exit 0.
  `python3 scripts/ci-change-class.py range origin/main HEAD` prints `false`.
- `mix check --affected origin/main` exits 0, or the pull request records the
  exact reason that it cannot run on the host. The full hosted check is green
  on the exact head.
- One independent review, and the exact-head automated review with all threads
  answered and resolved before the coordinator takes over.
