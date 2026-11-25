# ELZ-398 — delivery/dead-letter-store: bind resolve to an optional record generation

- Dependencies: ELZ-301, ELZ-397
- Release: V1B
- Output: no new Piece ID; prevent a guarded retry from resolving a replacement record for #701.
- Change class: Piece-only implementation.
- Owned paths: `pieces/delivery/dead-letter-store/**`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No root or dependency changes.

## Contract

Each inserted row gets a positive PostgreSQL `bigint` generation from a noncycling identity sequence owned by the table. An equal `put/3` duplicate does not change the row's generation; purging and inserting again gets a new value. `list/3` returns `generation` in each entry; cursors, ordering and counts stay unchanged. Add an optional `generation` key to the `resolve/3` request. A value outside 1..2^63−1 or not an integer is `{:error, :invalid}` before I/O. With a generation, the tenant/source/message ID **and** generation must match for both the update and the duplicate/already-resolved read. An absent or different generation is `{:error, :unknown_record}` and does not touch or disclose the replacement. Without the key the behavior is unchanged, including the stated limit on retry after purge and key reuse.

The Piece owns the column via its migration; document how a consumer-owned migration adds and populates it for existing rows before serving the revised Piece, without losing open or resolved records. The host must not reset or reuse generation values for a table that can still receive outstanding resolves. No change to `purge/3` or ELZ-397's purge retry exception.

## Acceptance

- On disposable PostgreSQL as the non-bypass application role, list an open record and use its generation to resolve it, then show an equal retry is `:duplicate` and a different resolution is `:already_resolved`. After purge and key reuse, the replacement has a different generation. The original guarded request now returns `:unknown_record`, and the replacement remains listed. Resolve the replacement with its own generation; the old guarded request is still `:unknown_record`, not `:duplicate`, even when the stored resolution fields match. The unguarded key-reuse case still holds. An equal put keeps generation unchanged; another tenant's generation does not cross the tenant floor.
- Exercise adding the column to a table with previously stored open and resolved rows. Preserve them and check generations for the existing rows and a later insertion. Malformed generation input fails before a query.
- Negative controls: remove the generation predicate from the update (the stale retry hides the open replacement), then separately remove it from the duplicate lookup (the old request adopts the resolved replacement as a duplicate). Restore both before the final gate.

Durable state, tenant isolation, concurrency and unknown outcomes: local small gate and full review. No new dependency.
