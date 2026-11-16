# domain/trigger-binding

Elzoo.TriggerBinding validates an immutable v1 declaration and selects from a
caller-supplied bounded snapshot. validate_declaration/1 returns the exact
validated map unchanged or {:error, :invalid_declaration}. select/3 returns
{:ok, :no_match}, one exact %{id: id, revision: revision, target: target}
map, {:error, :ambiguous}, or one of the fixed refusal tags below.

## Declaration

The declaration is a plain string-keyed map with exactly version, id,
revision, tenant, source, schema_id, schema_version, enabled and target.
Version is integer 1; target is a plain string-keyed map with exactly bot_ref,
package_digest and callable. Identifier, tenant, source, schema ID and bot
reference are nonempty valid UTF-8 of 1..160 bytes; callable is 1..128 bytes.
None may contain NUL. Revision and schema version are positive integers no
greater than 2^63-1; enabled is boolean. The package digest is exactly 64
lowercase hexadecimal bytes. Whitespace is data: values are neither trimmed
nor normalized.

host_scope is a separate plain atom-keyed %{tenant: ..., source: ...} map.
event_schema is a separate plain string-keyed map with schema_id and
schema_version, taken from declared message metadata after the caller validates
its envelope. Event metadata remains untrusted and is not authentication
evidence. Never derive host scope from event payload.

## Selection and refusals

Selection requires a proper list of at most 256 declarations. It validates all
rows and their targets, rejects duplicate IDs even among disabled or
nonmatching rows, then selects only enabled rows with exact tenant, source,
schema ID and schema version matches. Zero matches (including an empty list)
returns {:ok, :no_match}. One match returns its unchanged target and revision;
two or more are {:error, :ambiguous}, including identical targets. Outcome
does not depend on row order.

Refusals have fixed precedence: :invalid_scope, :invalid_event_schema,
:invalid_snapshot (including improper, over-bound or malformed snapshots),
:duplicate_binding_id, then selection. Declaration validation returns only
:invalid_declaration. Errors do not contain supplied values. This is not a
confidentiality claim about caller-owned maps.

The host supplies trusted scope separately. This Piece does not authenticate,
authorize, map principals, inspect payloads, load packages, perform lookup,
persist or mutate bindings, create Runs, rank, fan out or promise authority.
Installing or changing a binding belongs to a later checked command with
expected-revision fencing.

## Evidence and consumption

test/elzoo/trigger_binding_test.exs covers exact declaration validation,
normal and empty selection, text/numeric/digest boundaries, scope isolation,
whole-snapshot validation, duplicate and ambiguity precedence, bounds and
permutation invariance. Named tenant and ambiguity cases are the negative
controls for comparison/refusal changes. The pinned Cure source owns the pure
selection decision; Elixir validates and translates foreign maps. Tests cover
finite scenarios; no universal proof is claimed.

Use mix elzoo.take domain/trigger-binding --to <consumer>. The copied source
closure declares the existing Cure and Elixir providers only. See
the repository consuming guidance for source-copy ownership and providers.
