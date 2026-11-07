# ELZ-048 — Reconcile roadmap manifest hashes after the Cure pin migration

- Phase: P0 harness (planning metadata; `docs/plans/release-plan.json`, `docs/plans/roadmap.md`, generated views)
- Catalogue IDs: none changed
- Dependencies: ELZ-047 (#84, merged 230cc5b)

## Outcome

ELZ-047 moved the Cure pin to the `balungpisah/cure-lang` fork and changed the `upstream`
reference URL in 24 ready Piece manifests. `docs/plans/release-plan.json` stores a sha256 of each
ready manifest, so `python3 scripts/check-roadmap.py` now exits 1 with
`ready Contract changed: reconcile assembly/ingest-dedup-accumulate`. The checker is not part of
`mix check` or CI, so main stayed green, but the roadmap invariant is broken and the generated
views cannot regenerate.

## Scope

- Update the 24 stale `manifest_sha256` values to the bytes already merged on main. Nothing else in
  the manifests changed (only the provider reference URL and the pin named in prose), so no
  Contract summary (`note`), disposition, owner or status changes.
- Add a reconciliation note to `docs/plans/roadmap.md` that names the cause (ELZ-047) and states
  that no ready Contract changed.
- Regenerate `views.md` and `dependencies.mmd` with `--write`.
- No source, test, registry or CI change.

## Acceptance

- [ ] `python3 scripts/check-roadmap.py --write` then `python3 scripts/check-roadmap.py` exit 0.
- [ ] `python3 scripts/check-roadmap.py --self-test` exits 0.
- [ ] Diff of `release-plan.json` touches only `manifest_sha256` fields.
- [ ] Full `mix check` not required by the change (no source); CI PR run green.

## Limits

Planning metadata only. This is reconciliation of an inherited pin migration, not a new acceptance.
