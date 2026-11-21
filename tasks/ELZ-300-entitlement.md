# ELZ-300 — Plan grants that resolve to entitled, grace or not entitled at one time

- Phase: Wave 6 Level 1
- Dependencies: ELZ-033, ELZ-079
- Release: V1B
- Output: new `domain/entitlement` Piece (from RC-07, entitlement part)
- Change class: Piece-only
- Owned paths: `pieces/domain/entitlement/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece, `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One pure Piece in Elixir with Cure for the status decision: versioned plans and a tenant's grants of them resolve, at a time the host injects, to entitled, grace or not entitled, with the plan's features and its unit allowances. Host gates read the feature decision; `domain/quota` (Wave 6 Level 2) will read the allowances. No I/O, clock, process, storage, billing, quota or authorization decision. A revocation takes effect at the next call that sees it, as in `domain/kill-switch`. It does not depend on `domain/metering` (ELZ-299); both use the same unit set.

A plan is a building block, not a plan shape: the Piece knows no pay-as-you-go, quota or prepaid type (owner, 2026-11-21). Version 1 refuses two grants of one tenant that are active or in grace at one time, but the resolution already lists every grant and plan it came from, and the allowances are a list, so letting a tenant hold a base plan and an add-on later changes only the accepted inputs, not the result shape.

## Interface

- `Elzoo.Entitlement.content_hash(plan)` returns `{:ok, hash}`: 32 bytes, the SHA-256 of a documented canonical encoding of `{plan_id, version, features, allowances}` (features and allowances sorted as below), or `{:error, :plans}` for a malformed plan. A field that a later in-place version adds as optional is encoded only when present, so existing hashes stay equal.
- `Elzoo.Entitlement.resolve(facts, tenant, now_ms)`. `facts` is exactly `%{plans: [plan], grants: [grant]}`.
  - A plan is exactly `%{plan_id, version, content_hash, features, allowances}`. `features` is a proper list of 0..256 feature names, sorted by bytes and unique. `allowances` is a proper list of 0..64 entries `%{unit, amount, period_kind}`, sorted by `{unit, period_kind}` and unique on that pair. `unit` is one of `Elzoo.AiModel.Usage.units/0` or `{:cache_write_tokens, ttl}` with `ttl` one of `Elzoo.AiModel.Usage.ttls/0`, the unit set of `domain/metering`; `amount` an integer 1..2^63−1; `period_kind` `:utc_month` (owner Q6 A).
  - A grant is exactly `%{grant_id, tenant, plan_id, version, valid_from_ms, valid_to_ms, grace_until_ms, revoked_at_ms}`; the last three may be `nil`. `grace_until_ms` needs a `valid_to_ms` and is greater than it.
  - Returns `{:entitled, resolution}`, `{:grace, resolution}`, `{:not_entitled, :no_grant | :expired | :revoked}` or `{:error, reason}`.
- `resolution` is `%{tenant, at_ms, grants, features, allowances}`. `grants` lists each contributing grant as `%{grant_id, plan_id, version, content_hash, status}` with `status` `:entitled` or `:grace`. `features` is the sorted unique union of the contributing plans' features. `allowances` is a list of `%{unit, amount, period_kind, settle_only, grant_id}`, with `settle_only: true` for an allowance of a grant in grace (no new reservation; `domain/quota` enforces that). The top-level tag is `:grace` when every contributing grant is in grace, else `:entitled`. In version 1 there is exactly one contributing grant.
- `Elzoo.Entitlement.feature(resolution, name)` returns `:allow` or `{:deny, :feature_absent}`; a resolution in grace allows its features. A malformed resolution or name is `{:error, :invalid}`.

Texts (`tenant`, `grant_id`, `plan_id`, feature names): 1..128 bytes of valid UTF-8 without a C0 or C1 control character, compared by exact bytes. `version`: an integer 1..2^31−1. Times: integers 0..2^63−1, Unix milliseconds. `plans` and `grants`: proper lists of 0..1024 entries; a `{plan_id, version}` appears at most once in `plans` and a `grant_id` at most once in `grants`.

## Rules

A grant's status at `now`, in this order (the Cure decision over flags that Elixir computes): **revoked** when `revoked_at_ms` is set and `revoked_at_ms <= now`; **expired** when `valid_to_ms` is set, `valid_to_ms <= now` and there is no grace or `grace_until_ms <= now`; **grace** when `valid_to_ms <= now < grace_until_ms`; **active** when `valid_from_ms <= now` and `valid_to_ms` is `nil` or `now < valid_to_ms`; else **not yet** (`now < valid_from_ms`). Revocation wins over grace. `valid_to_ms` and `grace_until_ms` are exclusive.

`resolve/3` checks, in this order, and stops at the first failure: `now_ms` (`:now`); `tenant` (`:tenant`); the shape and bounds of every plan (`:plans`); every grant (`:grants`); each plan's `content_hash` against `content_hash/1` (`:content_hash`); for each grant of `tenant`, the plan version it names exists (`:unknown_plan`); then the grants of `tenant` alone are classified. Grants of other tenants are validated but never contribute. Two grants of `tenant` that are active or in grace at `now` are `{:error, :overlap}` in version 1. With one such grant the result is its resolution. With none: `:revoked` when a grant of `tenant` is revoked and would otherwise be active or in grace at `now`, else `:expired` when a grant has expired, else `:no_grant` (including a grant not yet valid).

Errors are fixed atoms that never echo an ID: `:now`, `:tenant`, `:plans`, `:grants`, `:content_hash`, `:unknown_plan`, `:overlap`, `:invalid`. The unit, `period_kind`, status and error sets, and the maps returned, may gain members and keys in a later in-place version (for example a tenant-local month or a rolling window as `period_kind`, a host unit `runs`, or stacking that drops `:overlap`); a caller matches on the members and keys it uses.

`piece.json` declares telemetry, config and control `not_applicable` (a pure Piece with fixed bounds).

## Acceptance

1. Every boundary at exact `now`: `valid_from_ms − 1` is `:no_grant` and `valid_from_ms` is entitled; `valid_to_ms − 1` is entitled and `valid_to_ms` is grace (with grace) or `:expired` (without); `grace_until_ms − 1` is grace and `grace_until_ms` is `:expired`; an open `valid_to_ms` stays entitled.
2. Revoked during grace is `:revoked`; revoked before `valid_from_ms` at a `now` after it is `:revoked`; a revocation time after `now` does not apply yet.
3. Two overlapping grants of one tenant are `:overlap`; two grants of one tenant that do not overlap at `now` resolve to the active one; grants of two tenants never cross (each tenant resolves to its own plan, and a tenant with only another tenant's grant is `:no_grant`).
4. An unknown plan version is `:unknown_plan`; a content-hash mismatch is `:content_hash`, also for a plan that no grant of `tenant` names.
5. `feature/2`: present, absent, and present in grace; the resolution in grace marks every allowance `settle_only: true`, and an entitled one `false`; `grants` names the grant, plan, version and hash.
6. Malformed facts in the fixed error order: one input with both a bad `now` and a bad plan gives `:now`; a bad plan and a bad grant give `:plans`; unsorted or duplicate features or allowances, an unknown unit or `period_kind`, `amount` 0 and 2^63, a 129-byte text and a C1 character are refused; error atoms carry no ID.
7. Selected Cure law: the status order revoked > expired > grace > active over the flags that Elixir supplies.
8. Negative control, restored before the final gates: swap grace and revocation in the order (case 2's revoked-during-grace must fail).

The Piece is pure, but its result gates access to features and allowances, an authorization-like decision, so it keeps the local new-Piece small gate and the full review of the coordinator guide ("Reviewer by risk"). Run the Piece tests, the roadmap and claims checks and the diff check; the exact-head hosted check and the merge queue are required.

## Limits to state

Facts are host-supplied; the Piece does not fetch, store or authenticate them. One active grant per tenant in version 1. No billing, invoice, subscription or period accounting (subscriptions wait for Wave 9's `domain/plan` and `domain/invoice`). A revocation reaches a gate only at its next call.
