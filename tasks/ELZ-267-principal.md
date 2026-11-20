# ELZ-267 — Typed principals whose delegation never widens authority

- Phase: Wave 5 Level 1
- Dependencies: ELZ-033, ELZ-024
- Release: V1B
- Output: new `domain/principal` Piece (from RC-06; `integration/identity` stays with RC-06)
- Change class: Piece-only
- Owned paths: `pieces/domain/principal/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece, `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

Create one pure Piece in plain Elixir (Cure where it fits; no Ash, no new provider): a typed principal value, its validation, one-level delegation to an agent that can never exceed its parent, and a deterministic check against caller-supplied epoch and revocation facts. No I/O, clock, process, storage, identity provider, token parsing, session or account linking. `integration/token-verify` (ELZ-268) and hosts build principals with this Piece; ready `domain/authorization`, `assembly/checked-command` and `state/audit-log` keep their host-vouched text identities and are not edited here.

A principal value is not authentication evidence. A host can build an `%Elzoo.Principal{}` struct literal; every function below therefore revalidates every struct field and invariant and refuses a struct that breaks one.

## Interface

`%Elzoo.Principal{kind, id, tenant, auth_epoch, delegated_by, allowed_scopes, allowed_spaces}`.

- `Elzoo.Principal.new(fields)` — `fields` is a plain atom-keyed map with exactly `kind`, `id`, `tenant`, `auth_epoch`, `allowed_scopes` and `allowed_spaces`; `kind` is `:human` or `:service`. Returns `{:ok, principal}` with `delegated_by: nil`, or `{:error, reason}` with `reason` in `:shape | :kind | :id | :tenant | :auth_epoch | :scopes | :spaces`. `kind: :agent` is refused `:kind`: an agent is made only by `delegate/2`.
- `Elzoo.Principal.delegate(parent, fields)` — `fields` has exactly `id`, `allowed_scopes` and `allowed_spaces`. Returns `{:ok, agent}` with `kind: :agent`, `tenant` and `auth_epoch` copied from the parent and `delegated_by` equal to the parent's `id`; or `{:error, reason}` with `reason` in `:parent | :nested_delegation | :shape | :id | :self_delegation | :scopes | :spaces | :escalation`. `:parent` is a parent that fails revalidation; `:nested_delegation` is a valid parent of kind `:agent` (one level only in this version); `:self_delegation` is an agent `id` equal to the parent's `id`; `:escalation` is any requested scope or space that the parent does not hold. The request is refused whole; it is never silently intersected.
- `Elzoo.Principal.check(principal, %{current_epoch: n, revoked_ids: ids})` — returns `:ok` or `{:error, :malformed | :revoked | :stale}`. Revoked: the principal's `id` is in `revoked_ids`, or the principal is an agent and its `delegated_by` is in `revoked_ids`. Stale: `auth_epoch < current_epoch`; equal or greater passes. For an agent, the host supplies its parent's current epoch. Order: revalidate the principal, validate the context (both `:malformed`), then revoked, then stale.
- `Elzoo.Principal.require_human(principal)` — `:ok`, `{:error, :not_human}` for a valid `:service` or `:agent`, or `{:error, :malformed}`.

Errors are the fixed atoms above and never echo supplied values.

## Bounds and invariants

- `id`, `tenant`, `delegated_by` and each scope, space and revoked ID: 1..128 bytes of valid UTF-8 with no control character (U+0000–U+001F, U+007F). This fits the CheckedCommand 1..128-byte/no-NUL identity, the AuditLog 1..256-byte no-control `actor` and the Authorization identity text. Compare by exact bytes; no normalization, case folding, wildcard, prefix or hierarchy.
- `auth_epoch` and `current_epoch`: integers `0..9_223_372_036_854_775_807`. The host defines their unit per issuer; this Piece compares them only.
- `allowed_scopes` and `allowed_spaces`: proper lists of 0..256 entries each. Duplicates are coalesced and the stored list is sorted by byte order, so equal sets give equal structs. An empty list is valid and holds no authority.
- `revoked_ids`: a proper list of 0..1024 entries.
- Struct invariants: `delegated_by` is `nil` exactly when `kind` is `:human` or `:service`; scope and space lists are canonical. Scopes and spaces are opaque labels for the host's mapping into Authorization rules or later membership; this Piece makes no authorization decision.

Cure owns the subset and kind decisions when it fits; Elixir validates foreign values. Any Cure law is a named selected law, not a claim about authentication.

## Acceptance

1. Valid `:human` and `:service` principals; canonicalization of duplicate and unordered scopes and spaces; exact boundaries for every text (0, 1, 128 and 129 bytes, invalid UTF-8, NUL, another C0 character, DEL), epoch (-1, 0, 2^63-1, 2^63, non-integer), list sizes (256 and 257, improper list) and map shape (missing, extra or string keys, non-map, struct). `new/1` with `kind: :agent` is refused `:kind`.
2. Delegation from a human and from a service with a subset and with an equal set; one extra scope and, separately, one extra space give `:escalation`; an agent parent gives `:nested_delegation`; an agent `id` equal to the parent's gives `:self_delegation`; `tenant`, `auth_epoch` or `kind` in `fields` gives `:shape`; a forged parent (for example a service with `delegated_by` set, a 129-byte tenant or unsorted scopes) gives `:parent`. The agent's tenant and epoch always equal the parent's.
3. `check/2`: an older epoch is `:stale`; equal and newer pass; a revoked ID is `:revoked`; an agent whose parent is revoked is `:revoked` although its own ID is not; revoked precedes stale; a malformed context or principal is `:malformed`.
4. `require_human/1` refuses `:service` and `:agent` and accepts `:human`.
5. Every function refuses hand-built structs that break an invariant: an agent without `delegated_by`, a human with it, unsorted or duplicate scopes, an out-of-range epoch.
6. Negative controls: temporarily remove the subset check in `delegate/2`, and separately the parent-revocation clause of `check/2`; the adversarial tests must fail. Restore before the final gates.

Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
