# domain/recipe-config

Check tenant settings against a caller-supplied schema descriptor, the same
descriptor that a later recipe-package declares (ELZ-162,
[issue #352](https://github.com/balungpisah/elzoo/issues/352)). A secret
setting holds only a credential reference, never a credential value. One pure
boundary: no package loading, store, resolver, defaults or coercion. The ready
`core/payload-schema` compiles and validates; this Piece adds the descriptor,
the closed top-level object rule, the reference shape and fixed failures.

## Interface and Contract

`Elzoo.RecipeConfig.build(descriptor)` returns `{:ok, checked_schema}` or
`{:error, :invalid_descriptor | :unsupported_version | :invalid_schema}`.
`Elzoo.RecipeConfig.check(checked_schema, settings)` returns `{:ok, settings}`
with the exact original value, or `{:error, :invalid_settings | :invalid_secret
| :too_large | :too_deep | :validation_failed}`. The checked schema is opaque,
immutable and caller-held; only values from `build/1` are admitted.

The descriptor is an exact string-keyed map:

```elixir
%{"version" => 1, "id" => "example/greeter", "revision" => 1,
  "port" => %{"id" => "greeter.settings", "direction" => "input",
              "schema_id" => "example/greeter-settings", "schema_version" => 1},
  "schema" => %{"type" => "object", "required" => ["model_key"],
                "properties" => %{"model_key" => reference_schema},
                "additionalProperties" => false},
  "secrets" => ["model_key"]}
```

- `version` is 1; identity is `(id, revision, version)`. `id` is 1..128
  UTF-8 bytes, `revision` an integer 1..2,147,483,647. The host keeps one
  immutable meaning per identity; there is no digest or registry.
- `port` is the existing four-field `core/port` input declaration; schema is a
  host-approved decoded draft 2020-12 object. `PayloadSchema.build/2` compiles
  it and `PayloadSchema.check/3` checks each settings value with this Port.
- The schema root declares `"type" => "object"`, a `properties` map of at most
  64 names (each 1..128 UTF-8 bytes, compared exactly) and
  `"additionalProperties" => false`, and has no root `patternProperties` or
  `unevaluatedProperties`. The schema is never rewritten. `required` decides
  which settings are mandatory; nested validation stays upstream-owned.
- `secrets` is a unique list of at most 64 declared property names. Each such
  property schema is exactly `{"type": "object", "required": ["ref", "scope"]
  (either order), "properties": {"ref"|"scope": {"type": "string", "minLength":
  1, "maxLength": 128}}, "additionalProperties": false}`: no default, enum,
  const, annotation or other key; integer limits compared exactly.

A present secret setting is exactly `%{"ref" => binary, "scope" => binary}`,
each 1..128 bytes (independent of character count). That is the request of
`integration/secrets` after trusted injection code translates the two string
keys to the fixed atoms `:ref` and `:scope`; no atom is created here. This
Piece does not call `Elzoo.Secrets`, resolve, reveal, or check existence,
authority, expiry or value. A raw string, `value` member, extra or missing
member, struct or malformed identifier is refused.

## Evaluation order and failures

`build/1`: descriptor plain JSON data, compact JSON at most 65,536 bytes and
container depth at most 32 (`:invalid_descriptor`); then an integer version
other than 1 (`:unsupported_version`); then exact keys, version, id, revision,
input direction and the `secrets` list (`:invalid_descriptor`); then the root
object rule and secret property shapes (`:invalid_schema`; a secret name that
is not a property is `:invalid_descriptor`); then `PayloadSchema.build/2`
(`:invalid_port` becomes `:invalid_descriptor`, other refusals `:invalid_schema`).

`check/2`: settings plain JSON data (`:invalid_settings`), depth at most 32
(`:too_deep`) and compact JSON at most 65,536 bytes (`:too_large`), the same
counting as `core/payload-schema` (root container is depth 1; the boundary is
accepted, the first excess refused, nothing truncated); then the shape of each
present secret (`:invalid_secret`); then `PayloadSchema.check/3`. Its
violations, including missing required settings or secrets and extra keys,
become `:invalid_settings`; its `:validation_failed` stays. No key names,
values, violation paths or library diagnostics are returned. No partial
result, logs or telemetry.

## Assumptions

Choices where the issue left the reason open:

- A descriptor over 65,536 compact bytes, deeper than 32 or not plain JSON data
  is `:invalid_descriptor`: the bound belongs to the descriptor, and
  `:too_large`/`:too_deep` are check-only tags.
- A malformed Port and a Port whose direction is not `"input"` are
  `:invalid_descriptor`; an undeclared or duplicate secret name is
  `:invalid_descriptor`; open-object forms, more than 64 properties, bad
  property names and a nonexact secret property schema are `:invalid_schema`.
- A non-integer version is `:invalid_descriptor`; an integer other than 1 is
  `:unsupported_version`, checked before the other fields.
- A struct (such as `Elzoo.Secrets.Credential`) or an atom-keyed map in a secret
  setting fails the plain-data check first, so it is `:invalid_settings`.
- `check/2` with a value not returned by `build/1` is `:validation_failed`,
  without raising.

## Needs and limits

Host Needs: approved schema complexity, immutable truthful schema identity,
secret-free nonsecret values and reference identifiers, and a trusted host
that later resolves the exact scope under fresh authority. A well-shaped
reference authenticates nobody; a caller can put credential bytes in an
identifier, and this Piece is not a content detector. No I/O, resolver,
clock, credential release, authority grant, tenant authentication or
persistence. Bounds are not a schema CPU/memory isolation guarantee.
Telemetry, Config and Control are `not_applicable`: descriptor and settings
are data operands of a check, not ambient configuration or a running service.

## Evidence

`test/elzoo/recipe_config_test.exs` has the four named groups:
`declared_settings_only`, `secret_reference_not_value`,
`identity_and_ready_schema_reuse` and `fixed_bounds_and_redacted_failure`.
Calls run in a traced worker: no `Elzoo.Secrets` or `:telemetry.execute` call
and no log is observed, a resolver that fails if called is never called, and
the compiled module imports `Elzoo.PayloadSchema.build/2` and `check/3` but no
`Elzoo.Secrets` module. `examples/elzoo/recipe_config.exs` passes the checked
references to host injection code; the test confirms that the translated
requests have the `Elzoo.Secrets` request shape (a deny grant gives
`:denied`, not `:malformed`, without a resolver call). Tests only: no Cure law
is selected; schema semantics are grounded upstream in `core/payload-schema`
and pinned JSV.

## Consumption

Use `mix elzoo.take domain/recipe-config --to <consumer>`. The closure
includes `core/payload-schema`, `core/port` and `integration/secrets`; the
library calls only `core/payload-schema` and Jason. `integration/secrets` and
telemetry are for the copied tests. Source is Apache-2.0; see
[consuming](../../../docs/consuming.md).
