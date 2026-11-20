# domain/provider-data-policy

`Elzoo.ProviderDataPolicy` holds the closed data-class tag and one pure
decision: may a payload carrying a set of data classes go to one provider, in
one region, under one retention mode, according to a tenant's policy? It is a
host-gate check beside `domain/authorization` and `integration/egress-policy`;
it neither replaces nor calls them. No I/O, no clock, no classification of
content, no provider registry and no ASK.

## Interface

- `data_classes()` returns `[:public, :internal, :confidential, :pii, :secret]`.
- `decide(policy, request)` returns `:allow`, `{:deny, reason}` with `reason` in
  `:secret | :provider | :class | :region | :retention`, or
  `{:error, :policy | :request}`. **The host treats every result other than
  `:allow` as DENY**, including both errors.

`policy` is a plain atom-keyed map with exactly `providers`: 0..256 maps with
exactly `provider` and `classes`. `classes` holds 1..4 maps with exactly
`class` (`:public | :internal | :confidential | :pii`), `regions` (1..64 texts)
and `retention` (1..16 texts). Provider IDs are unique in the policy, classes
unique in a provider. A policy that names `:secret` is `{:error, :policy}`.

`request` is a plain atom-keyed map with exactly `provider`, `region`,
`retention` (texts) and `classes`: a proper list of 1..5 tags from
`data_classes/0`, counted before duplicates coalesce. An empty list is
`{:error, :request}`: unclassified data is not public data.

A text is 1..64 bytes of valid UTF-8 without a C0 control (U+0000..U+001F),
DEL (U+007F) or a C1 control (U+0080..U+009F), compared by exact bytes. Every
`integration/ai-model` `ModelRef.provider` without a C1 character fits. Lists
are proper lists; an extra or string key, a struct, an improper list or a
non-atom class is the shape error of its side.

## Order

1. Policy shape (`{:error, :policy}`), then request shape (`{:error, :request}`).
2. `:secret` in the request gives `{:deny, :secret}`.
3. A provider absent from the policy gives `{:deny, :provider}`.
4. For each request class in the fixed order `:pii`, `:confidential`,
   `:internal`, `:public`: absent for the provider gives `{:deny, :class}`; a
   region not admitted gives `{:deny, :region}`; a retention mode not admitted
   gives `{:deny, :retention}`. The first failure is returned.
5. Otherwise `:allow`.

Admission is per class, with no ordering or inheritance: admitting `:pii` does
not admit `:internal`.

```elixir
policy = %{providers: [%{provider: "p1", classes: [
  %{class: :pii, regions: ["eu"], retention: ["zero-retention"]}]}]}

Elzoo.ProviderDataPolicy.decide(policy,
  %{provider: "p1", region: "eu", retention: "zero-retention", classes: [:pii]})
#=> :allow
```

## Grounding, Needs and Limits

Tests only: `mix test pieces/domain/provider-data-policy/test` runs the groups
data_classes, admission, order, policy shape, request shape, text bounds,
exact bytes and no echo. Three negative controls, each a temporary edit
(drop the `:secret` refusal; check only the first request class; let `:pii`
admit `:internal`), each failed a case of the admission or order groups.
Finite scenarios, not a universal proof.

Needs: the host tags each payload with its data classes (the host or
`integration/pii-redaction`), supplies the tenant's current policy, and treats
every non-`:allow` result as DENY.

Limits: no content inspection, provider identity verification or contractual
truth of a provider's region and retention claims; no ASK, policy identity
hash or decision record (the host records the decision with its checked
command). Region and retention vocabularies, such as `"eu-west-1"` or
`"zero-retention"`, are the host's. Errors and denials are fixed atoms that
never echo supplied values; no telemetry, no log. Telemetry and Control are
not applicable; Config is the per-call policy.

Module application-owned under `Elzoo.ProviderDataPolicy`. Apache-2.0; no new
dependency or pin. See [consumption instructions](../../../docs/consuming.md).
