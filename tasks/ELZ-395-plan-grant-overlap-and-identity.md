# ELZ-395 — domain/plan: refuse overlapping replacement grants and qualify grant IDs by tenant

- Dependencies: ELZ-366, ELZ-399
- Release: V2
- Output: no new Piece ID; enforce the replacement boundary for #885 and prevent cross-tenant grant ID collisions of the present format for #884.
- Change class: Piece-only implementation.
- Owned paths: `pieces/domain/plan/**`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. Do not change `domain/entitlement`, `domain/quota`, or any other store or root code.

## Contract

- `create/3` keeps same-ID duplicate and `:conflict` behavior first, and keeps `{:error, :subscription_exists}` for a different ID while the tenant has an open subscription, overlapping or not. Otherwise refuse with `{:error, :grant_overlap}` and commit nothing when the new first grant intersects any nonempty grant interval of a canceled subscription of the same tenant. Intervals are half-open, from `valid_from_ms` to the earlier of `valid_to_ms` and a returned `revoked_at_ms`, if present. Count trial and renewed periods already granted; do not count a withdrawn grant revoked at or before its own start. Use the stored period/anchor and cancel facts, not just whether a row is canceled or its nominal latest end. The overlap decision and successful creation must be atomic with respect to concurrent creates and a cancellation that frees the open slot.
- `domain/entitlement` is a pure resolver, not a store. It checks uniqueness of `grant_id` across the *whole* facts list before filtering by tenant, so a wording change would not suffice. Use `plan1.` followed by lowercase hex SHA-256 of the bytes `elzoo-plan-grant/1:` followed by tenant and subscription ID each prefixed by its byte length as an unsigned big-endian 32-bit integer, then the period index as an unsigned big-endian 64-bit integer. This gives a fixed 70-byte UTF-8 identifier, independent of delimiters in IDs and within entitlement's 128-byte bound. State the digest assumption, not a mathematical guarantee of no collisions. Use that one format for emitted grants and revocations, including duplicate results and `get/3`'s stored cancel result for rows written by the revised Piece. No fee-line or subscription ID format change.
- The consumer owns its copy and its grant facts. Document the format cutover: a consumer with old Plan rows and exported grants must migrate their grant and revocation references together (including the IDs in stored cancel results) or stay on its old copy. Do not mix old grant IDs and new revocations or add a dual-ID mode. The Piece does not write the host's grant store.
- The new check applies to the replacement's first grant, not its future renewals. If that first period ends at the start of an older grant, the host must still avoid renewing into that older grant. Keep that host limit in the README; do not forbid earlier nonoverlapping first periods.

**Coordinator decision (owner can veto):** ELZ-399 lands first so the root acceptance checks composition without pinning the format. The exact new format vector remains required in Plan's test lane.

## Acceptance

- On disposable PostgreSQL as the non-bypass application role, a backdated first period that intersects a canceled subscription's grants is refused with `:grant_overlap`, leaves no row, and does not block a valid replacement. Starting exactly at the old effective end or after it succeeds; a period ending at an old grant's start does not intersect it. Include cancel-now inside a renewed-ahead window and period-end cancellation with a withdrawn ahead grant; the nominal end of that withdrawn period is not the boundary. Keep open-subscription and same-ID duplicate/conflict cases. Force create to race the cancellation that frees the open slot: a backdated create cannot commit on a stale overlap read.
- Create and renew the same subscription ID in two tenants; their corresponding grant IDs differ and the combined facts resolve for each tenant. Cancel one tenant and check the matching grant IDs and times in the returned and reread revocations; resolve the other tenant unchanged. Check the exact format with an independently derived vector and a maximum-length input; keep duplicate identity stable.
- Negative controls: omit the overlap decision (the backdated create commits), use the nominal withdrawn end (the exact-boundary case is refused), and omit tenant from the grant identity (the combined facts are rejected). Restore each edit before the final gate.

Durable state, tenant isolation, concurrent writes and money: local small gate and full review. No new dependency, grant store, timer, or support for multiple open subscriptions.
