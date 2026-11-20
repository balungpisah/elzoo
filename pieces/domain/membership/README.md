# domain/membership

The permissions that a `domain/principal` holds at one space at one injected
time, resolved from facts that the host supplies: spaces in an optional tree,
named roles, memberships with a validity window and soft revocation, and
non-inheriting permission prefixes. It also lists the spaces of the
principal's tenant where one permission holds, for the space list of
`state/tenant-isolation`. `Elzoo.Membership` is two pure functions: no I/O,
clock, process, storage, invitation, authentication or authorization decision.

The host stores the facts and keeps revoked rows (soft revocation preserves
append-only foreign keys), calls `Elzoo.Principal.check/2` with the real epoch
and revoked IDs first, and maps the result into exact `domain/authorization`
rules.

## Facts

`facts` is a plain atom-keyed map with exactly `spaces`, `roles`,
`memberships` and `non_inheriting`. A space is the same label as a principal's
`allowed_spaces`; a permission is the label of its `allowed_scopes`.

- `spaces`: 1..1024 maps with exactly `id`, `tenant`, `parent` (`nil` or a
  space `id` of the same tenant) and `block_inheritance` (boolean). A flat
  tenant is one space with `parent: nil`. A path from a space to its root has
  at most 32 spaces; no cycle.
- `roles`: 0..256 maps with exactly `id` and `permissions` (0..256 texts,
  counted before coalescing).
- `memberships`: 0..1024 maps with exactly `principal`, `space`, `role`,
  `valid_from`, `valid_to` (`nil` or an integer greater than `valid_from`) and
  `revoked_at` (`nil` or an integer), naming a present space and role, counted
  before coalescing. Identical entries coalesce.
- `non_inheriting`: 0..16 permission prefixes.

Every ID, tenant, permission and prefix is 1..128 bytes of valid UTF-8 without
a C0 or C1 control character (the ELZ-267 text rule), compared by exact bytes:
no normalization, case folding, wildcard or pattern. Prefix matching is a byte
prefix. Times are integers `0..9_223_372_036_854_775_807`; this Piece only
compares them. Every fault is `{:error, :facts}`, including a struct or a
string-keyed map in place of a map, a duplicate space or role ID and an
improper list.

## Functions

| Call | Result |
| --- | --- |
| `permissions(principal, space_id, facts, now_unix_s)` | `{:ok, permissions}` (sorted, duplicate-free, possibly empty), or `{:error, :principal \| :now \| :facts \| :unknown_space \| :cross_tenant}` |
| `spaces(principal, permission, facts, now_unix_s)` | `{:ok, space_ids}` (sorted IDs of the principal's tenant where `permission` is in `permissions/4`), or `{:error, :principal \| :now \| :facts \| :permission}` |

The first failing step gives the reason: the principal, then `now_unix_s`,
then the facts, then the target (`space_id` text and existence, both
`:unknown_space`, then its tenant; or the `permission` text). The principal
is revalidated only through `Elzoo.Principal.check(principal, %{current_epoch: 0,
revoked_ids: []})`, which is `:ok` exactly for a valid principal. Errors are
fixed atoms and never echo supplied values. An unknown permission gives
`{:ok, []}`.

## Resolution

1. The authority owner is the principal's `id` for `:human` and `:service`,
   and its `delegated_by` for `:agent`. A membership naming an agent's own
   `id` grants nothing.
2. A membership is active at `now` when `valid_from <= now`, `valid_to` is
   `nil` or `now < valid_to`, and `revoked_at` is `nil` or `now < revoked_at`.
   It counts only when its `principal` is the owner and its space belongs to
   the principal's `tenant`.
3. An active membership at space M grants its role's permissions at M. At a
   proper descendant D it grants them only when no space on the path from D up
   to, but excluding, M has `block_inheritance: true`, and a permission that
   starts with a `non_inheriting` prefix is granted only at M. Nothing flows to
   an ancestor or to another branch.
4. For an agent, the union is intersected with its `allowed_scopes`, and a
   target that is not in its `allowed_spaces` (exact match, not through the
   tree) gives `{:ok, []}`. For a human or a service the memberships alone are
   the authority; their own `allowed_scopes` and `allowed_spaces` bound only
   what they can delegate.

## Example

`examples/membership.exs` resolves inherited and local permissions, a
non-inheriting prefix, a barrier, an agent, a space list and a cross-tenant
refusal.

## Grounding

- Proof: Cure owns the flow decision `flows(path, local_only)` over the
  barrier flags that Elixir supplies. Selected laws `grants_at_own_space`
  (every permission holds at M), `local_only_never_flows` (a non-inheriting
  permission never leaves M), `barrier_blocks` (for all paths, one barrier
  anywhere between D and M stops every permission), `barrier_closes` (its
  helper over `open`) and `open_path_flows` (an open path carries an inheriting
  permission). That Elixir supplies exactly the flags of the path from D up
  to M, and asks only for M on that path, is test-grounded.
- Type: pinned Cure checks types and totality; the audit reports no axiom,
  hole or unproved-total definition.
- Test: `mix test pieces/domain/membership/test` runs fact validation at every
  bound, the flat tenant and its time edges, the hierarchy with a barrier,
  non-inheriting prefixes, tenancy, the agent, the agreement of `spaces/4`
  with `permissions/4` on every fixture, the error order, the Cure laws and
  audit and the checked example. Negative controls: removing the
  `block_inheritance` check, the non-inheriting filter, the `revoked_at`
  clause, the membership tenant clause together with the tenant restriction
  of `spaces/4`, and the target tenant check of `permissions/4`, one at a
  time, each makes the tests fail. Finite scenarios, not universal proofs.
- Upstream: pinned Cure, and pinned Elixir/OTP binary byte order,
  `String.valid?/1` and term equality.

## Needs and limits

Needs: a host that builds principals from authenticated state and calls
`Elzoo.Principal.check/2` before this Piece, supplies facts as fresh as it
needs, keeps revoked membership rows, and maps permissions into its own
authorization rules.

Limits: no invitations, tenant status, per-space role definitions, wildcard
permissions, durable state or concurrency. An agent's `allowed_spaces` match
exactly and not through the tree, so with the 256-entry cap of
`domain/principal` an agent acts in at most 256 named spaces. Facts are as
fresh as the host made them, so a revocation takes effect at the next call
that sees it. No authorization decision. Telemetry, Config and Control are not
applicable.

Modules are application-owned under `Elzoo.Membership` and
`Cure.Elzoo.Membership`; the Piece depends on `domain/principal`. Apache-2.0;
no dependency beyond pinned Cure and Elixir.
