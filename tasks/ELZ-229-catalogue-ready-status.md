# ELZ-229 — Each ready Piece has `"status": "ready"` in its catalogue row

- Dependencies: ELZ-033
- Output: none. No Piece Contract changes; no Piece becomes ready or stops being ready.
- Change class: non-Piece root/shared change. `registry/catalogue.json` is an index file, but a change of it alone is neither documents only nor Piece-only for `scripts/ci-change-class.py`. Local gate `mix check --affected origin/main` and `git diff --check`; full hosted check.
- Allowed implementation path: `registry/catalogue.json` only. `LEDGER.md` and the plan views only if step 3 of the index files changes them (expected: no change).

Why. `AGENTS.md` section 3 says that the row of a ready Piece holds
`"status": "ready"` and its `manifest`. 25 rows hold a `manifest` and no
`status`. They are ready all the same, because the Registry takes the
status from the manifest. A reader of the file, or a tool that reads
only the catalogue, sees 83 ready rows where 108 exist.

Facts checked on `main` (confirm each when you start):

- `registry/catalogue.json` has 143 rows: 83 with `status` `ready` and a
  `manifest`, 25 with a `manifest` and no `status`, 28 `deferred` and 7
  `planned` with no `manifest`.
- `Elzoo.Registry.load!/1` (`lib/elzoo/registry.ex:20-26`) merges the
  manifest over the row, so `status` comes from `piece.json`. Each of the
  25 manifests has `"status": "ready"` (`scripts/check-roadmap.py:100`
  requires it for every entry with a manifest, and passes).
- 24 of the 25 were ready at the baseline of the plan; one
  (`delivery/effect-intent`) became ready later.
- `scripts/check-roadmap.py` compares only `manifest` between the plan
  and the catalogue (`:96`); it reads the baseline catalogue from Git,
  not this file, for `baseline_status`.

## Task

Add `"status": "ready"` to each of the 25 rows, in the key order of the
other ready rows (after `phase`, before `manifest`). Change no other key
and no other row. Edit in place; do not write the file again as a whole.
Then run step 3 of the index files and commit a generated file only if
it changed.

## Acceptance

- Every row with a `manifest` has `"status": "ready"`: 108 rows. The
  count of rows (143), and of `planned` (7) and `deferred` (28), is
  unchanged. Quote the one-line count before and after.
- `git diff --stat` shows 25 added lines in `registry/catalogue.json`
  (plus a comma change where the format needs one) and nothing else,
  unless a generated file changed; then say why.
- `mix elzoo.ledger` leaves `LEDGER.md` unchanged (the ledger reads the
  merged status).
- `mix check --affected origin/main` exits 0 (the one slot of the
  database server); `python3 scripts/check-roadmap.py` and `git diff
  --check` exit 0; the full hosted check is green on the exact head.
- One independent review.

## Review risk

Low. The Registry result is the same before and after. The cost is one
full hosted run. The coordinator may hold this task and give its one
path to the next full-check task that already changes the catalogue.

## Not in scope

`docs/plans/release-plan.json` (ELZ-228); any `summary`, `phase`,
`disposition` or `reason` text; any `piece.json`.
