# domain/principal

A typed principal value, its validation, one-level delegation to an agent that
can never exceed its parent, and a deterministic check against epoch and
revocation facts that the caller supplies. `Elzoo.Principal` is four pure
functions: no I/O, clock, process, storage, identity provider, token parsing,
session or account linking.

A principal value is not authentication evidence. Any code can build an
`%Elzoo.Principal{}` struct literal, so every function revalidates every field
and invariant and refuses a struct that breaks one. The host builds principals
only from its own authenticated state, for example with
`integration/token-verify`.

## The struct

`%Elzoo.Principal{kind, id, tenant, auth_epoch, delegated_by, allowed_scopes, allowed_spaces}`

- `kind`: `:human`, `:service` or `:agent`. `delegated_by` is `nil` exactly
  when `kind` is `:human` or `:service`; for an agent it is the parent's `id`.
- `id`, `tenant`, `delegated_by`, each scope and each space: 1..128 bytes of
  valid UTF-8 with no C0 or C1 control character (U+0000–U+001F,
  U+007F–U+009F).
- `auth_epoch`: an integer `0..9_223_372_036_854_775_807`. The host defines the
  unit per issuer; this Piece only compares epochs.
- `allowed_scopes`, `allowed_spaces`: proper lists of 0..256 labels, counted
  before coalescing. Duplicates are coalesced and the list is sorted by byte
  order, so equal sets give equal structs. An empty list holds no authority.

Labels compare by exact bytes: no normalization, case folding, wildcard,
prefix or hierarchy. Scopes and spaces are opaque labels that the host maps
into `domain/authorization` rules or later membership; this Piece makes no
authorization decision.

## Functions

| Call | Result |
| --- | --- |
| `new(fields)` | `{:ok, principal}` with `delegated_by: nil`, or `{:error, :shape \| :kind \| :id \| :tenant \| :auth_epoch \| :scopes \| :spaces}` |
| `delegate(parent, fields)` | `{:ok, agent}`, or `{:error, :parent \| :nested_delegation \| :shape \| :id \| :self_delegation \| :scopes \| :spaces \| :escalation}` |
| `check(principal, %{current_epoch: n, revoked_ids: ids})` | `:ok`, or `{:error, :malformed \| :revoked \| :stale}` |
| `require_human(principal)` | `:ok`, or `{:error, :not_human \| :malformed}` |

The first failing step gives the reason, in the order listed. Errors are these
fixed atoms and never echo supplied values.

`new/1` takes a plain atom-keyed map (not a struct) with exactly `kind`, `id`,
`tenant`, `auth_epoch`, `allowed_scopes` and `allowed_spaces`. `kind: :agent`
is refused `:kind`: only `delegate/2` makes an agent.

`delegate/2` takes a parent that passes revalidation (else `:parent`) and is a
human or a service (an agent parent is `:nested_delegation`: one level only),
and a plain map with exactly `id`, `allowed_scopes` and `allowed_spaces`. An
agent `id` equal to the parent's is `:self_delegation`. The agent holds the
requested sets when the parent holds every requested scope and every requested
space; one label the parent does not hold refuses the whole request with
`:escalation`. It is never intersected. The agent's `tenant` and `auth_epoch`
are the parent's and `delegated_by` is the parent's `id`.

`check/2` revalidates the principal, then the context: `current_epoch` in the
epoch range and `revoked_ids` a proper list of 0..1024 texts, exactly these two
keys (both failures are `:malformed`). Then it is `:revoked` when the
principal's `id`, or for an agent its `delegated_by`, is in `revoked_ids`, then
`:stale` when `auth_epoch < current_epoch`; an equal or greater epoch passes.
For an agent the host supplies its parent's current epoch.

`require_human/1` is `:ok` only for a valid `:human`.

## Example

`examples/principal.exs` builds a human, delegates to an agent, checks it, and
shows an escalation, a nested delegation, a revoked parent and the human gate.

## Grounding

- Proof: Cure owns the kind functions `delegable` and `human` and the delegation subset rule. Selected
  laws `granted_scopes_within_parent` and `granted_spaces_within_parent` (every
  granted label is held, for all lists), `granted_scopes_exact` and
  `granted_spaces_exact` (a granted delegation is the request, never an
  intersection), `agent_parent_not_delegable`, `human_parent_delegable`,
  `service_parent_delegable`, `human_is_human`, `service_not_human` and
  `agent_not_human`. They hold over the byte lists that Elixir supplies, with
  respect to the Cure `subset`, `member` and `eq_bytes` definitions; that these
  match exact-byte membership is test-grounded. They are not a claim about
  authentication.
- Type: pinned Cure checks types and totality; the audit reports no axiom,
  hole or unproved-total definition.
- Test: `mix test pieces/domain/principal/test` runs the listed scenarios for
  `new`, `delegate`, `check`, `require_human` and forged structs, the Cure law
  and audit and the checked example. Negative controls: removing the subset
  check of `delegate/2`, and separately the parent-revocation clause of
  `check/2`, makes the tests fail. Validation, canonicalization, revalidation,
  the agent test in `check/2` and check ordering are Elixir-side and
  test-grounded only.
- Upstream: pinned Cure, and pinned Elixir/OTP binary byte order,
  `String.valid?/1` and term equality.

## Needs and limits

Needs: a host that builds principals only from authenticated state, supplies
the current epoch of the issuer (for an agent, its parent's) and the revoked
IDs it holds, calls `check/2` before relying on a principal, and maps scopes
and spaces into its own authorization rules.

Limits: no authentication, identity provider, token parsing, session, expiry,
clock, account linking or authorization decision; one delegation level. Ready
`domain/authorization`, `assembly/checked-command` and `state/audit-log` keep
their host-vouched text identities. Telemetry, Config and Control are not
applicable.

Modules are application-owned under `Elzoo.Principal` and
`Cure.Elzoo.Principal`. Apache-2.0; no dependency beyond pinned Cure and
Elixir.
