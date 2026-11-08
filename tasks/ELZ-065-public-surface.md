# ELZ-065 — Remove private infrastructure details and third-party personal data before publication

- Phase: P0 harness (docs only: `docs/development/10-symbolic-ci.md`, `docs/development/01-workflow.md`, `docs/work/*.md`,
  `docs/work/research/*.json`)
- Catalogue IDs: none
- Dependencies: ELZ-058 (#96) merged (same docs file). Precedes the visibility change.
- Review: Devin Review plus the worker's own checks (docs-only, mechanical). Findings dispositioned in the PR.

## Outcome

Owner decision 2026-11-09: the repository becomes public. Before that, the MUST-REDACT class is removed from the
tree and from issue and PR comments: addresses, credentials, production inventories, third-party personal data,
and disk, container and virtual-machine listings. The SHOULD-REDACT class (host names, runner names, local
paths, session ids) is a second pass after publication. Git history is not rewritten.

## Done before this PR (no repository change)

- A read-only inventory covered the tree, every blob reachable from the 8 branches and 51 pull refs that GitHub would
  expose (487 commits, 1,721 blobs), and all 933 issue, PR, comment and review texts. No IP address, no credential and
  no secret-shaped string was found; the test-database URLs with a disposable user and password on `localhost`
  are not secrets and stay.
- One comment that named the owner's storage domain was re-posted without it and the original deleted (an edit
  would keep the old text in the public edit history).

## Scope

1. `docs/development/10-symbolic-ci.md`: replace the provider instance id, the storage domain, the production
   container names, the co-tenancy inventory, the disk and free-space figures and the names of the other CI system
   by role names ("the slow VPS runner", "the owner's production services", "the owner's object-store host", "an unused
   runner install of another repository"). Facts that matter for the CI design stay (core count, memory caps,
   measured times).
2. `docs/work/research/*.json`: remove the `email` fields and replace e-mail addresses inside quoted license and
   readme text by `[email removed]` (names, package handles and URLs stay). The files are recorded research data
   that no code, test or manifest reads, and none of their hashes is pinned anywhere (checked with a search for the file
   names and for their SHA-256 values).
3. Local test-database passwords: in `docs/development/01-workflow.md` and 18 historical work reports under
   `docs/work/` (the recorded commands and their outputs) the password part of `ecto://user:password@localhost` URLs and of one
   role command becomes an ellipsis or a placeholder, and each changed report gets one line saying so; the commands are
   otherwise exact. The functional test-database URL in the workflow file and in test fixtures stays.
4. Verify with the inventory scanner (kept outside the repository because its patterns name private hosts): zero
   MUST hits in the tree, and report the residual SHOULD list for the second pass.

## Acceptance

- [ ] The scan of the merge result reports zero MUST hits in the tree.
- [ ] The research JSON files still parse, and only e-mail data changed (a script compares the files before and after).
- [ ] `mix check` passes on the PR head and the merge commit (docs-only change).
- [ ] Devin Review: findings dispositioned.

## Limits

Git history keeps older versions of the edited files (instance id and domain in earlier versions of the CI guide), the
owner's commit author e-mail addresses and 447 workflow run logs with host names. The owner accepted these on 2026-11-09.
