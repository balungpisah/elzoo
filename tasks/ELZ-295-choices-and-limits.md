# ELZ-295 — Document the owner choices and deliberate limits for users

- Dependencies: ELZ-286

## Outcome and scope

A person who uses Elzoo Pieces finds, in one plain page, each owner choice
and each deliberate limit that shapes what the Pieces do, why it was made,
what it means for them, and how to change it. The owner asked for this page.
This is a coordinator one-PR documents change: publication and
implementation share one `task/ELZ-295` pull request, and it takes the
documents check.

Owned paths:

- `docs/choices.md`: a new page, "Choices and limits";
- `README.md`: one link to that page in the "Design and scope" list.

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`. `docs/consuming.md` is not changed: the
export copies it, so it is not a documents-only path.

## Required behavior

1. Each entry has four short parts: what was chosen; why; what it means for
   someone who uses the Pieces; and how to change it, naming what they
   would swap or add and whether the change needs a new Piece ID. The page
   states the rule once: before the first release a ready Piece is changed
   in place under its ID; from the first release a change of a ready
   Piece's accepted inputs, outputs, state, delivery, failure guarantees or
   Needs gets a new Piece ID, and a fix that restores the Contract keeps the
   ID (`AGENTS.md` section 4). It also states that a consumer owns its
   copied source and can change its copy without an Elzoo task.
2. The page covers at least:
   - the Wave 5 owner choices: no identity provider in core, with OIDC or
     passkey login as a consumer recipe over `integration/token-verify` and
     `domain/principal`; `DENY` on an unavailable or unknown policy result,
     and `ASK` only for a declared typed abstention; erasure by per-subject
     (or per-tenant) keys and crypto-shredding, with logs never rewritten;
     only an agent's membership permissions are capped by its allowed
     scopes and spaces; AES-256-GCM only, one layer, no wrapped data keys;
     no fetch helper in `integration/egress-policy`, with redirects and
     response bounds as transport duties; one-use invitations in
     `workflow/tenant-lifecycle`; the reserved kill-switch reason prefix
     `lifecycle`; and the fixed `elzoo_app` test role;
   - the limits of the Wave 5 acceptance ELZ-286: no production identity
     provider (pinned test keys), no live public MCP endpoint, no Carbonite
     `state/audit-log` capture of its commands, and RunEngine Runs and their
     stores on the owner connection, outside `state/tenant-isolation`;
   - the request charge and payload caps of `assembly/run-engine` (RC-50),
     with the numbers taken from its `piece.json` and README;
   - the earlier owner decisions still in force, with their dates, from
     `docs/plans/bot-platform.md` ("Owner decisions" sections), including
     bearer-first runtime MCP servers with OAuth in Wave 9 (RC-59), the
     version-1 action kinds (RC-68), plain Elixir with no Ash wrapper in
     core, adopting a maintained library rather than writing a reader, and
     in-place change before the first release;
   - the owner decisions on flaky tests (#670) and on the `Amp-Thread-ID`
     trailer (ELZ-292).
3. Each entry links its source: the decision record in
   `docs/plans/bot-platform.md` or `docs/plans/bot-platform-wave5.md`, the
   task file or issue, the Piece's `README.md` or `piece.json`, or the
   ELZ-286 report. The page claims nothing beyond those sources, and it
   says that later waves add their choices to it.
4. Plain words, short entries, roles only: no person's name.

No Contract, task, Piece, catalogue row or other plan text changes.

## Acceptance and evidence

1. The diff changes only the owned paths, this task file, its job row and
   the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py --live`, `python3
   scripts/check-claims.py` and `git diff --check` pass.
4. One light independent review of each entry against its linked source, a
   green exact-head hosted documents check, and the PR marked ready. The
   coordinator merges on a green `main`.
