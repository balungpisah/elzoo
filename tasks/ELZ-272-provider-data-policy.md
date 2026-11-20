# ELZ-272 — Refuse to send classified data to a provider, region or retention mode the tenant does not admit

- Phase: Wave 5 Level 2
- Dependencies: ELZ-033
- Release: V1B
- Output: new `domain/provider-data-policy` Piece (absorbing the `domain/data-class` handle)
- Change class: Piece-only
- Owned paths: `pieces/domain/provider-data-policy/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (`domain/authorization`, `integration/ai-model`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One pure Policy Piece in plain Elixir (Cure where it fits; no new provider). It holds the closed data-class tag and one decision: may a payload carrying a set of data classes go to one provider, in one region, under one retention mode, according to a tenant's policy? It is a host-gate check beside `domain/authorization` and `integration/egress-policy`. It neither replaces them nor calls them. No I/O, no clock, no classification of content (the host or Level 3 `integration/pii-redaction` tags data), no provider registry and no ASK. By the 2026-11-20 owner decision, a missing or malformed policy or request is not admissible, and the host treats every non-`:allow` result as DENY.

## Interface

- `Elzoo.ProviderDataPolicy.data_classes()` returns `[:public, :internal, :confidential, :pii, :secret]`, the closed tag set.
- `Elzoo.ProviderDataPolicy.decide(policy, request)` returns `:allow`, `{:deny, reason}` with `reason` in `:secret | :provider | :class | :region | :retention`, or `{:error, :policy | :request}`.

`policy` is a plain atom-keyed map with exactly `providers`: 0..256 maps with exactly `provider` and `classes`. `classes` holds 1..4 maps with exactly `class` (one of `:public | :internal | :confidential | :pii`), `regions` (1..64 texts) and `retention` (1..16 texts). Provider IDs are unique within the policy and classes unique within a provider. `:secret` is never admissible: a policy that names it is `:policy`.

`request` is a plain atom-keyed map with exactly `provider`, `region`, `retention` (texts) and `classes` (a proper list of 1..5 tags from `data_classes/0`; duplicates coalesce). An empty list is `:request`, because unclassified data is not public data.

Order:

1. Policy shape, giving `{:error, :policy}`; then request shape, giving `{:error, :request}`.
2. `:secret` in the request classes gives `{:deny, :secret}`.
3. A provider absent from the policy gives `{:deny, :provider}`.
4. For each request class in the fixed order `:pii`, `:confidential`, `:internal`, `:public`: a class absent for that provider gives `{:deny, :class}`; a request region not in its `regions` gives `{:deny, :region}`; a request retention not in its `retention` gives `{:deny, :retention}`. The first failure is returned.
5. Otherwise `:allow`.

Admission is per class and has no ordering or inheritance between classes: admitting `:pii` does not admit `:internal`.

## Bounds and invariants

- Provider IDs, regions and retention modes: 1..64 bytes of valid UTF-8 without C0 or C1 control characters, compared by exact bytes. Every `integration/ai-model` `ModelRef.provider` (1..64 bytes, no C0 or DEL) without a C1 character fits. Region and retention vocabularies are the host's (for example `"eu-west-1"`, `"zero-retention"`); this Piece gives them no meaning.
- Lists are proper lists, counted before coalescing; anything else, an extra or string key, a struct, or a non-atom class is the shape error of its side.
- Errors and denials are the fixed atoms and never echo supplied values; no telemetry, no log.

## Acceptance

1. `data_classes/0` returns exactly the five tags in that order.
2. Admission: a policy admitting provider `p1` for `:pii` in `["eu"]` under `["zero"]` and for `:public` in `["eu", "us"]` under `["zero", "30d"]`. `{p1, eu, zero, [:pii, :public]}` is `:allow`; `{p1, us, 30d, [:public]}` is `:allow`; `{p1, us, zero, [:pii, :public]}` is `{:deny, :region}`; `{p1, eu, 30d, [:pii]}` is `{:deny, :retention}`; `{p1, eu, zero, [:internal]}` and `{p1, eu, zero, [:pii, :internal]}` are `{:deny, :class}`; `{p2, eu, zero, [:public]}` is `{:deny, :provider}`.
3. Order, each on its own case: `:secret` with an unknown provider is `{:deny, :secret}`. An unknown provider with an unadmitted class is `{:deny, :provider}`. With a policy admitting only `:pii` in `["eu"]` for `p1`, `{p1, us, zero, [:public, :pii]}` gives `{:deny, :region}` (`:pii` comes first in the fixed order, whatever the input order), not the `:class` failure of `:public`. A malformed policy with a malformed request is `{:error, :policy}`.
4. Shape: an empty policy (`providers: []`) with a valid request is `{:deny, :provider}`. A policy naming `:secret`, an unknown class atom, a duplicate provider, a duplicate class, 257 providers, 65 regions, 17 retention modes and an empty `regions` list are each `{:error, :policy}`, while 256, 64 and 16 pass. A request with `classes: []`, 6 entries (even when only 2 are distinct), an unknown tag, a string class or an extra key is `{:error, :request}`, while 5 entries with duplicates pass. Texts at 0, 1, 64 and 65 bytes, invalid UTF-8, NUL, DEL and U+0085 on both sides.
5. Exact bytes: region `"EU"` against `"eu"` and provider `"p1 "` against `"p1"` are denied.
6. Negative controls, one at a time: drop the `:secret` refusal; check only the first request class; treat an admitted `:pii` as admitting `:internal` (a class order). Each must make a case of groups 2–3 fail. Restore before the final gates.

Limits to state: no content inspection, provider identity verification or contractual truth of the provider's region and retention claims (host Needs); no ASK, policy identity hash or decision record (the host records the decision with its checked command). Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
