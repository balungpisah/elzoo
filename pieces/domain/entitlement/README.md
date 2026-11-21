# domain/entitlement

Versioned plans and a tenant's grants of them, resolved at a time the host
injects to entitled, grace or not entitled, with the plan's features and its
unit allowances. Host gates read the feature decision; `domain/quota` will
read the allowances. `Elzoo.Entitlement` is three pure functions: no I/O,
clock, process, storage, billing, quota or authorization decision.

A plan is a building block, not a plan shape: the Piece knows no
pay-as-you-go, quota or prepaid type. The host stores plans and grants, keeps
revoked and ended grant rows, and supplies them per call.

## Facts

`facts` is a plain atom-keyed map with exactly `plans` and `grants`, each a
proper list of 0..1024 entries.

- A plan is exactly `%{plan_id, version, content_hash, features, allowances}`.
  `features` is 0..256 feature names, sorted by bytes and unique.
  `allowances` is 0..64 maps `%{unit, amount, period_kind}`, sorted by
  `{unit, period_kind}` in Erlang term order and unique on that pair. `unit`
  is one of `Elzoo.AiModel.Usage.units/0` or `{:cache_write_tokens, ttl}` with
  `ttl` in `Elzoo.AiModel.Usage.ttls/0` (the unit set of `domain/metering`);
  `amount` is an integer `1..2^63-1`; `period_kind` is `:utc_month`. A
  `{plan_id, version}` appears at most once.
- A grant is exactly `%{grant_id, tenant, plan_id, version, valid_from_ms,
  valid_to_ms, grace_until_ms, revoked_at_ms}`. The last three may be `nil`.
  `valid_to_ms`, when set, is greater than `valid_from_ms`; `grace_until_ms`
  needs a `valid_to_ms` and is greater than it; `revoked_at_ms` is any time.
  A `grant_id` appears at most once.

Texts (`tenant`, `grant_id`, `plan_id`, feature names) are 1..128 bytes of
valid UTF-8 without a C0 or C1 control character, compared by exact bytes.
`version` is an integer `1..2^31-1`. Times are integers `0..2^63-1`, Unix
milliseconds; the Piece only compares them.

## Content hash

`content_hash(plan)` is `{:ok, hash}`, the 32-byte SHA-256 of this encoding of
the plan (a `content_hash` key is ignored), or `{:error, :plans}`:

    text(b)   = <<byte_size(b)::32, b::binary>>
    int(n)    = <<n::64>>                      (unsigned, big-endian)
    list(xs)  = <<length(xs)::32>> <> xs
    field(k, v) = text(k) <> v

    plan      = text("elzoo/entitlement/plan")
                <> field("plan_id", text(plan_id))
                <> field("version", int(version))
                <> field("features", list(map(features, text)))
                <> field("allowances", list(map(allowances, allowance)))
    allowance = text(field("unit", unit) <> field("amount", int(amount))
                     <> field("period_kind", text(period_kind name)))
    unit      = list([text(name)])  or  list([text("cache_write_tokens"), text(ttl)])

Features and allowances are encoded in their required sorted order. A field
that a later in-place version adds as optional is appended only when present,
so existing hashes stay equal. The host computes the hash when it stores a
plan version; `resolve/3` refuses a plan whose stored hash differs.

## Functions

| Call | Result |
| --- | --- |
| `resolve(facts, tenant, now_ms)` | `{:entitled, resolution}`, `{:grace, resolution}`, `{:not_entitled, :no_grant \| :expired \| :revoked}` or `{:error, reason}` |
| `feature(resolution, name)` | `:allow`, `{:deny, :feature_absent}` or `{:error, :invalid}` |
| `content_hash(plan)` | `{:ok, hash}` or `{:error, :plans}` |

`resolve/3` checks, in this order, and stops at the first failure: `now_ms`
(`:now`), `tenant` (`:tenant`), the facts shape (`:facts`), every plan
(`:plans`), every grant (`:grants`), each plan's `content_hash`
(`:content_hash`, also for a plan that no grant names), and that each grant of
`tenant` names a present plan version (`:unknown_plan`). Grants of other
tenants are validated but never contribute. Errors are fixed atoms that never
echo an ID.

A `resolution` is `%{tenant, at_ms, grants, features, allowances}`:

- `grants`: each contributing grant as `%{grant_id, plan_id, version,
  content_hash, status}`, `status` `:entitled` or `:grace`;
- `features`: the sorted unique union of the contributing plans' features;
- `allowances`: `%{unit, amount, period_kind, settle_only, grant_id}` for each
  allowance of each contributing grant, with `settle_only: true` for a grant
  in grace (settle what is already reserved, reserve nothing new;
  `domain/quota` enforces that).

The tag is `:grace` when every contributing grant is in grace, else
`:entitled`. `feature/2` allows a feature of a resolution in grace.

## Status

A grant's status at `now`, in this order: **revoked** when `revoked_at_ms` is
set and `revoked_at_ms <= now`; **expired** when `valid_to_ms` is set,
`valid_to_ms <= now` and there is no grace or `grace_until_ms <= now`;
**grace** when `valid_to_ms <= now < grace_until_ms`; **active** when
`valid_from_ms <= now` and `valid_to_ms` is `nil` or `now < valid_to_ms`; else
not yet valid. Revocation wins over grace; `valid_to_ms` and `grace_until_ms`
are exclusive.

Two grants of `tenant` that are active or in grace at `now` are
`{:error, :overlap}` in this version. With one, the result is its resolution.
With none: `:revoked` when a grant of `tenant` is revoked at `now`, else
`:expired` when one is expired, else `:no_grant` (also for a grant not yet
valid).

## Growth

The unit, `period_kind`, status and error sets, and the returned maps, may
gain members and keys in a later in-place version (for example a tenant-local
month or a rolling window, a host unit, or stacking a base plan with an
add-on, which drops `:overlap`). The resolution already lists every grant and
plan it came from, and allowances are a list attributed to their grant, so
stacking changes only the accepted inputs. A caller matches on the members
and keys it uses.

## Example

`examples/entitlement.exs` resolves an entitled and a grace resolution, a
feature allowed in grace and an absent one, a grant past its grace and another
tenant's revoked grant.

## Grounding

- Proof: Cure owns the status order `status(revoked, expired, grace, active)`
  over the flags that Elixir computes. Selected laws: `revoked_wins` (for all
  other flags, a revocation wins, also over grace), `expired_before_grace`,
  `grace_before_active`, `active_alone` and `none_not_yet`. That Elixir
  computes the flags exactly as above is test-grounded.
- Type: pinned Cure checks types and totality; the audit reports no axiom,
  hole or unproved-total definition.
- Test: `mix test pieces/domain/entitlement/test` runs every time boundary on
  both sides, revocation before, during and after grace, overlap and
  non-overlap, two tenants, unknown plan versions, content-hash mismatches and
  the documented encoding, `feature/2`, each reachable validation bound on both sides and
  the error order (the 64-allowance bound is not reachable with the 15
  distinct unit pairs of this version). Negative controls: swapping grace and revocation in the Cure order
  fails the `revoked_wins` law at compile; swapping the two flags at the
  Elixir call, letting grace win over revocation, and dropping the tenant
  filter each make the tests fail. Finite scenarios, not universal proofs.
- Upstream: pinned Cure; pinned Elixir/OTP term order and `String.valid?/1`;
  OTP `:crypto` SHA-256.

## Needs and limits

Needs: a host that reads plans and grants from its own storage, stores each
plan's content hash, keeps revoked and ended grants, and injects the time.

Limits: facts are host-supplied; the Piece does not fetch, store or
authenticate them. One active grant per tenant in this version. No billing,
invoice, subscription or period accounting. A revocation reaches a gate only
at its next call. Telemetry, Config and Control are not applicable.

Modules are application-owned under `Elzoo.Entitlement` and
`Cure.Elzoo.Entitlement`; the Piece depends on `integration/ai-model` for the
unit set. Apache-2.0; no dependency beyond pinned Cure, Elixir and OTP.
