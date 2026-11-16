# ELZ-247 — Validate and select scoped trigger bindings

- Dependencies: ELZ-033
- Release: V1B
- Output: domain/trigger-binding
- Change class: Piece-only

## Scope and reuse

Create one pure Piece that validates an immutable trigger declaration and selects one binding from a bounded snapshot. Cure owns deterministic selection; Elixir validates foreign maps, UTF-8 and byte bounds. The host supplies trusted scope in a separate argument. This Piece makes no authentication or authorization claim.

The public API is:

~~~elixir
Elzoo.TriggerBinding.validate_declaration(declaration)
Elzoo.TriggerBinding.select(snapshot, host_scope, event_schema)
~~~

Declarations are exact plain maps with string keys. A v1 declaration has exactly version, id, revision, tenant, source, schema_id, schema_version, enabled and target, and version must equal integer 1. target has exactly bot_ref, package_digest and callable. host_scope is a separate host-supplied atom-keyed map with exactly tenant and source. event_schema is a separate string-keyed map with exactly schema_id and schema_version, taken from declared message metadata after the caller validates its envelope; it remains untrusted event data, not authentication evidence. Never derive host_scope from event payload.

validate_declaration/1 returns {:ok, the unchanged exact validated string-keyed declaration} or {:error, :invalid_declaration}. select/3 returns {:ok, :no_match}, {:ok, %{id: id, revision: revision, target: target}} for exactly one match, or {:error, :ambiguous}. Other refusals are {:error, reason}, where reason is one of :invalid_scope, :invalid_event_schema, :invalid_snapshot or :duplicate_binding_id. These outcomes are bounded and do not echo supplied values; the Contract makes no confidentiality claim about caller-owned input maps. The successful selection map has exactly id, revision and target.

## Contract

- version is exactly integer 1; reject missing, unknown or unsupported declaration versions.
- id, tenant, source, schema_id and target.bot_ref are nonempty valid UTF-8 without NUL, 1..160 bytes.
- revision and schema_version are positive integers no greater than 2^63-1. enabled is a boolean.
- target.package_digest is exactly 64 lowercase hexadecimal characters. target.callable is valid UTF-8 without NUL, 1..128 bytes.
- Validate host_scope.tenant and host_scope.source with the same bounded text rule as declaration tenant/source. Validate event_schema.schema_id with the schema_id text rule and event_schema.schema_version with the positive signed-integer bound. These event fields remain declared metadata, not trusted identity.
- Reject unknown/missing keys, structs, malformed nested targets, invalid text, invalid numeric ranges and malformed declarations. Do not normalize whitespace or repair data.
- Refusal precedence is fixed: validate host_scope; validate event_schema; require a proper list with 0..256 rows; validate every declaration and target; reject duplicate declaration IDs; only then select. This order makes malformed-row and duplicate-ID failures invariant under row permutation.
- Match only enabled declarations whose tenant and source exactly match host_scope and whose schema_id and schema_version exactly match event_schema. Empty snapshot and zero matches are valid no_match outcomes. One match returns its immutable target and revision. Multiple matches are ambiguous even if their targets are byte-for-byte equal.
- Outcome is independent of snapshot order. Errors are bounded and redacted; do not return payloads or offending values.
- No database, lookup, package loader, authentication, authorization, principal mapping, payload predicate, priority, fanout or Run factory. Installing or changing a binding is a later checked command with expected-revision fencing; selection itself does not claim persistence or authority.

Reuse comparison: RecipeGraph validates named graph bindings shaped as name/target, and RecipeConfig checks caller-supplied settings against a schema. Neither is this tenant/source/schema selector. Do not depend on RecipeGraph just to carry opaque bot/package references or broaden either existing Piece.

## Acceptance

1. **Normal and empty:** a valid declaration validates; empty snapshot returns no_match; zero, one and multiple matches return the exact outcomes above.
2. **Text semantics and whole-snapshot validation:** do not trim or normalize. Test leading/trailing and whitespace-only text; it is accepted when it meets the nonempty UTF-8 byte bounds and is matched byte-exactly. Reject empty, NUL, invalid UTF-8 and over-bound text; missing, unknown, non-integer or unsupported versions; nonpositive and over-bound revisions/versions; bad uppercase, non-hex and wrong-length digests; unknown or missing fields; malformed target; duplicate IDs across disabled and nonmatching rows; and any malformed row in an otherwise matching snapshot.
3. **Isolation and ambiguity:** cover disabled rows and cross-tenant, cross-source and cross-schema rows; demonstrate exact scope match; same-target duplicates remain ambiguous; all permutations produce the same result; test 256 succeeds when otherwise valid and 257 fails wholly.
4. **Laws and negative controls:** selection is permutation-invariant and never returns a target outside the exact host tenant/source and event schema match. Temporarily bypass tenant comparison and then ambiguity refusal; the corresponding cross-tenant and multiple-match tests must fail. Restore only this Piece's source before completion.
5. **Bounded failures and precedence:** invalid host_scope, event_schema, malformed/non-list snapshot and over-bound snapshot return the fixed bounded errors in the declared precedence. A malformed declaration wins over duplicate-ID detection; duplicate IDs win over selection. Errors do not echo supplied values; this makes no confidentiality claim about caller-owned maps.

Run the Piece tests and the repository's normal Piece gate:

~~~sh
mix test pieces/domain/trigger-binding/test
mix check --piece "$(git merge-base origin/main HEAD)"
git diff --check
~~~

## Owned paths and deliverables

Own only pieces/domain/trigger-binding/**. Include piece.json with the full copied source closure and its required existing cure and elixir providers; add no new providers or pin changes. Include Cure source, Elixir validation/source, tests, README and one bounded example. Keep declaration selection and validation in the same Piece.

## Not in scope

No persistence, revision mutation, authorization, authentication, identity-provider integration, package loading, routing priority, fanout, payload matching, Run creation or shared-path changes.
