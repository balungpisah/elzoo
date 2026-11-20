# ELZ-269 — Scoped memberships and roles that never leak upward or across tenants

- Phase: Wave 5 Level 2
- Dependencies: ELZ-033, ELZ-267
- Release: V1B
- Output: new `domain/membership` Piece (from RC-07, absorbing the `domain/role` handle; `domain/entitlement` stays with RC-07)
- Change class: Piece-only
- Owned paths: `pieces/domain/membership/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (including `domain/principal`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

Create one pure Piece in plain Elixir (Cure where it fits; no Ash, no new provider). It resolves the permissions that a `domain/principal` (ELZ-267) holds at one space at one injected time. It reads caller-supplied facts: spaces in an optional tree, named roles, and memberships with a validity window and soft revocation. It also lists the spaces where one permission holds, for the space list of `state/tenant-isolation` (ELZ-270). No I/O, clock, process, storage, invitation, authentication or authorization decision. The host stores facts, keeps revoked rows (soft revocation preserves append-only foreign keys), and maps results into exact `domain/authorization` rules. Authorization, CheckedCommand and AuditLog are not edited.

Not in this task: one-use invitations (single use is a durable compare-and-set that a pure Piece cannot hold), tenant status (`active | suspended | closing` belongs to Level 3 `domain/kill-switch` and `workflow/tenant-lifecycle`), per-space role definitions and wildcard permissions.

## Interface

`facts` is a plain atom-keyed map with exactly `spaces`, `roles`, `memberships` and `non_inheriting`. A space is a node of the tenant's tree, the same label as a principal's `allowed_spaces`; a permission is the label of its `allowed_scopes`:

- `spaces`: 1..1024 maps with exactly `id`, `tenant`, `parent` (`nil` or a space `id`) and `block_inheritance` (boolean). A flat tenant is one space with `parent: nil`.
- `roles`: 0..256 maps with exactly `id` and `permissions` (0..256 texts, counted before coalescing).
- `memberships`: 0..1024 maps with exactly `principal`, `space`, `role`, `valid_from`, `valid_to` (`nil` or an integer) and `revoked_at` (`nil` or an integer), counted before coalescing. Identical entries coalesce.
- `non_inheriting`: 0..16 permission prefixes.

Functions:

- `Elzoo.Membership.permissions(principal, space_id, facts, now_unix_s)` returns `{:ok, permissions}` (a sorted, duplicate-free list, possibly empty) or `{:error, reason}` with `reason` in `:principal | :now | :facts | :unknown_space | :cross_tenant`.
- `Elzoo.Membership.spaces(principal, permission, facts, now_unix_s)` returns `{:ok, space_ids}`, the sorted space IDs of the principal's tenant where `permission` is in `permissions/4`, or `{:error, reason}` with `reason` in `:principal | :now | :facts | :permission`.

Order for both: revalidate the principal, then `now_unix_s`, then facts, then the target (`space_id` text and existence, both `:unknown_space`, then its tenant; or `permission` text). The principal is revalidated only through the public ELZ-267 API, `Elzoo.Principal.check(principal, %{current_epoch: 0, revoked_ids: []})`. By the ELZ-267 Contract that call is `:ok` exactly for a valid principal, since every `auth_epoch` is ≥ 0. Any other result is `:principal`. Epoch and revocation of the principal remain the host's `Elzoo.Principal.check/2` call before this one. Errors are the fixed atoms and never echo supplied values.

## Resolution rule

1. The authority owner is the principal's `id` for `:human` and `:service`, and its `delegated_by` for `:agent`. Memberships whose `principal` is an agent's own `id` grant nothing.
2. A membership is active at `now` when `valid_from <= now`, `valid_to` is `nil` or `now < valid_to`, and `revoked_at` is `nil` or `now < revoked_at`. It counts only when its `principal` equals the owner and its space belongs to the principal's `tenant`.
3. An active membership at space M grants its role's permissions at M. At a proper descendant D, it grants them only when no space on the path from D up to, but excluding, M has `block_inheritance: true`. Permissions whose bytes start with a `non_inheriting` prefix are granted only at M. Nothing flows to an ancestor or to another branch.
4. For `:agent`, the union is intersected with the agent's `allowed_scopes`. A target space that is not in its `allowed_spaces` gives `{:ok, []}`. For `:human` and `:service`, the memberships alone are the authority; their `allowed_scopes` and `allowed_spaces` bound only what they can delegate (ELZ-267).

## Bounds and invariants

- Every ID, tenant, permission and prefix: 1..128 bytes of valid UTF-8 without C0 or C1 control characters, the ELZ-267 text rule. These are compared by exact bytes, with no normalization, case folding, wildcard or pattern. Prefix matching is a byte prefix.
- Times: integers `0..9_223_372_036_854_775_807` (Unix seconds by convention; this Piece only compares them).
- The fact validation reports `:facts` for any of these: wrong shape or key set, a bound exceeded, an improper list, a duplicate space or role ID, a parent that is absent or in another tenant, a cycle (including a self-parent), a path of more than 32 spaces from a space to its root, a membership naming an absent space or role, or `valid_to <= valid_from`.

## Acceptance

1. Fact validation: each fault in the list above gives `:facts` on its own case. This includes depth 32 accepted and depth 33 refused; 1024 and 1025 spaces; 256 and 257 roles; 256 and 257 permissions in one role, with 257 entries that have duplicates; 1024 and 1025 memberships; 16 and 17 prefixes; text at 0, 1, 128 and 129 bytes, invalid UTF-8, NUL, DEL and U+0085; times −1, 2^63−1, 2^63 and a float; and a struct or string-keyed map in place of a map.
2. Flat tenant: a member gets its role's permissions; a non-member gets `{:ok, []}`; two roles at one space give their union. Time edges, each on its own case: `now == valid_from` active and `valid_from == now + 1` inactive; `valid_to == now` inactive and `now + 1` active; `revoked_at == now` inactive and `now + 1` active.
3. Hierarchy with root R, child A with `block_inheritance: true`, grandchild B under A and sibling C under R. A membership at R grants at R and C but not at A or B. A membership at A grants at A and B. A membership at B grants at B only, never at A or R.
4. With `non_inheriting: ["money."]` and a membership at R whose role holds `money.pay`, `money`, `Money.pay` and `read`: R gets all four. C gets `money`, `Money.pay` and `read`, because the prefix match is exact bytes. A membership at C with the same role gives C `money.pay` again.
5. Tenancy: a target space of another tenant is `:cross_tenant`. The facts hold memberships of the same principal ID in tenants T1 and T2, and the principal belongs to T1. `spaces/4` then never lists a space of T2, and `permissions/4` at a T1 space ignores the T2 membership.
6. Agent: an agent resolves its parent's memberships intersected with its `allowed_scopes`. A target outside its `allowed_spaces` gives `{:ok, []}`. A membership naming the agent's own `id` grants nothing. A parent membership that is revoked at `now` removes the agent's permissions with it.
7. `spaces/4` agrees with `permissions/4` on every space and permission of the fixtures in groups 2–6; an unknown permission gives `{:ok, []}`. An unknown `space_id` is `:unknown_space`. A forged principal (an agent without `delegated_by`, unsorted scopes, a 129-byte tenant) is `:principal` before any fact error. A malformed `now` with valid facts is `:now`.
8. Negative controls, one at a time: remove the `block_inheritance` check; remove the non-inheriting filter; remove the `revoked_at` clause; remove both the rule 2 membership tenant clause and any space-tenant restriction in `spaces/4` (including a reliance on `:cross_tenant`) together (each alone is masked by the other); remove the target tenant check in `permissions/4`. Each must make a case of groups 2–5 fail. Restore before the final gates.

Limits to state: no invitations, tenant status, per-space custom roles, durable state or concurrency; an agent's `allowed_spaces` match exactly and not through the tree, so with ELZ-267's 256-entry cap an agent acts in at most 256 named spaces; facts are as fresh as the host made them, so a revocation takes effect at the next call that sees it; no authorization decision. Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
