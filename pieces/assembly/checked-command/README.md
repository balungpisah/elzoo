# assembly/checked-command

`Elzoo.CheckedCommand` commits a schema-checked, gate-checked and authorized
command without creating a Run. The caller holds an immutable handle over an
existing atomic `Elzoo.DurableLog.Store`; the Piece starts no process and owns
no global cache, Repo, identity provider, or remote effect. Resource mutation,
the retained command result, Approval events and an optional pending outbox
notification share one Store append.

The public surface is exactly `new/2`, `execute/3`, `release/4`, `result/3`,
and `resource/3`. Codec helpers are internal implementation details, not a
stream lookup API.

This is a bounded command Assembly, not a generic workflow or transaction
engine. It uses the existing `PayloadSchema`, `PatternStep`, `Authorization`,
`Approval`, `TriggerBinding` and Store contracts directly. It does not claim
RunEngine parity: the separately owned root-consumer acceptance must invoke the
actual public RunEngine.

## Bind a command

`new/2` accepts a Store tuple with atomic append visibility and a descriptor
with exactly these required atom keys:

```elixir
%{
  id: "trigger/install",
  version: 1,
  content_hash: <<...::256>>,
  effect_class: "publish",
  port: checked_port,
  schema: compiled_payload_schema,
  prepare: prepare_fun3,
  gate: %{call: gate_fun2},
  approval: %{verifiers: ["command-reviewer"], max_age: 60_000},
  outbox: "command-notifications" # optional; omit or set nil for no item
}
```

The descriptor is trusted fixed host configuration. `version` is 1..2^31-1;
the id, effect class, verifier IDs and other identifiers use the Piece's
1..128-byte UTF-8/no-NUL identity bound. `content_hash` is 32 bytes. The
descriptor identity must change whenever schema or preparation meaning
changes. `schema` must be a compiled token returned by the actual
`PayloadSchema.build/2` boundary; serialized schemas and functions are not
accepted. `gate` has exactly a `call/2` function. `approval` has exactly
`verifiers` (1..64) and positive `max_age`; Approval keys use revisions
1..2^31-1. A `:once` requirement name must also fit the command key's
1..128-byte/no-NUL identity bound; `:run` and `:root` remain unsupported.
The Store's declared outbox destinations must include a configured
destination. The Piece retains neither functions nor the Store/provider
configuration in command records.

The host supplies a current exact execute context:

```elixir
%{tenant: tenant, actor: actor, policy: policy,
  own: own_authority, parent: parent_authority, facts: portable_facts}
```

Release adds `approver: %{identity: reviewer_id, authority: current_authority}`,
`now` (Unix milliseconds), and `revoked` (a proper list of fresh
`{verifier, evidence_id}` keys). The approver map has exactly those two keys,
matching Approval's release boundary. The host authenticates and vouches for
tenant, actor, approver, authority and current revocations. They are Needs,
not authentication implemented by this Piece. Facts must already use
Authorization's portable values (`nil`, booleans, bounded integers,
`{:text, binary}`, `{:bytes, binary}`, `{:list, values}` or
`{:record, [{name, value}]}`); raw JSON maps and strings are not converted into
facts. They are validated and normalized by Authorization, then passed to the
pure preparer as exactly
`%{tenant: context.tenant, actor: context.actor, data: normalized_facts}`.

The preparer is a pure deterministic host Need:

```elixir
prepare.(snapshot, original_request, facts)
# => {:ok, writes, response} | {:refused, bounded_code}
```

`snapshot` is `%{tenant: ..., resource: ..., revision: ..., fields: ...}`;
fields are a string-keyed map of normalized Authorization values, or `%{}` for
an absent resource. The request payload is the original JSON-shaped map, not
the portable Authorization encoding. A write is `%{target: id, field: name,
value: portable_value}`. Every target must equal the requested resource; there
must be 1..16 normalized, nonconflicting writes. Bounded raw writes are
normalized by Authorization: unsorted writes and duplicate-identical writes
are accepted, while conflicting values for one field are refused. Write values
and `response` must already be Authorization portable values; raw JSON maps
and strings are not converted. Domain exceptions, invalid returns and oversized values become
bounded refusals; exception text is not returned. Callbacks run outside Store
transactions and must not perform I/O or effects.

The gate receives the exact one-action decoded PatternStep check frame used by
the RunEngine gate and `%{proposer: actor, effect_class: class, tenant: tenant}`.
The frame's action id is `operation_id`, kind is `local_work`, schema id/version
come from the checked Port, and payload is unchanged. This is only a check
frame: it starts no Run and invokes no local-work callback.

`execute/3` takes an exact plain atom-keyed request
`%{operation_id: id, resource: id, expected_revision: revision, payload: map}`.
JSON payloads admit UTF-8 text, bounded integers, booleans, null, lists and
string-keyed objects; floats, structs and runtime terms are refused. The host
must reject duplicate JSON object keys before conversion to an Elixir map.
Schema-approved object keys use Authorization's portable field-name bound of
0..4,096 UTF-8 bytes; the separate resource write-field bound is 1..128 bytes.
JSON payload content never overrides host context. Portable facts, writes and
responses reject duplicate record-field names through Authorization.
Schema/representation preflight, caller context and read scopes are validated
before reading command history. Result scope is exactly `%{tenant: tenant,
actor: actor}`. Resource scope is exactly `%{tenant: tenant, actor: actor,
resources: readable_ids}`; it must list the requested resource. An absent
authorized resource is revision zero with empty fields. Scope mismatch returns
`:not_found` without disclosing a receipt.

## Identity, replay and approval

Each tenant has one versioned, collision-free stream. Canonical public request
bytes bind tenant, actor, operation id, descriptor identity, resource, expected
revision, normalized payload and immutable portable facts. Their exact bytes
and SHA-256 are retained. Gate verdict, policy, authority, time and approver
are current dynamic inputs, not identity. A retained equal request returns the
first result even if today's gate or policy verdict changed; the current
context must still validate. Reuse of the same `{tenant, actor, operation_id}`
for different request bytes, descriptor or resource returns
`{:conflict, :identity}` before new gate or prepare work.

Authorization decides directly from the checked proposal and trusted current
context. DENY and stale/domain outcomes are retained without mutation or
outbox. ALLOW applies exactly the normalized permitted writes. ASK supports
only `:once`; its exact request and decision are retained without mutation.
Each retained Authorization result includes the validated full decision. The
Approval request event is regenerated from that exact ASK decision during
replay; release transitions must retain the same action, policy identity,
escrow and requirement. Replay also rejects foreign release events and
previously consumed `{verifier, evidence_id}` keys.

Release replays the pending entry, checks current descriptor/facts/schema/gate
and resource revision, re-prepares, and requires exact write/response binding
before calling `Approval.release/4` with current policy and authority. A
permanently stale resource becomes a terminal stale result without consuming
evidence. Successful consumption, release event, exact mutation, terminal
result and optional outbox item are one append. Failed release attempts leave
the pending record and consumed-key state unchanged.

The release argument is a host-vouched envelope:

```elixir
%{purpose: :command, tenant: tenant, evidence: approval_evidence}
```

The evidence is the existing Approval evidence map with the exact fields
`verifier`, `evidence_id`, `reviewer`, `request`, `decision`, `scope`,
`issued_at`, and `expiry`; only `scope: :once` is accepted. This Elixir map is
not authentication. The host MUST verify purpose, tenant, command owner/key and
reviewer provenance before passing it, and MUST keep command verifier IDs
separate from Run verifier IDs. Run-purpose, wrong-tenant and non-once
evidence are refused even when textual owner fields happen to match. The
versioned opaque command owner is not proof that all Run IDs are disjoint.
The host must provide evidence only after authenticated provenance is checked
by a command-dedicated verifier; this verifier and its trust material are host
Needs, not supplied or simulated by this Piece.

The host supplies fresh revocation keys on each release. This Piece has no
revocation service and cannot make a stale host feed fresh. Pending Approval
and consumed command evidence survive Store restart by replay; no process-local
revocation feed is persisted.

## Persistence, recovery and operations

Recovery requires `low_water == 0` and a complete, stable, contiguous history
from sequence 1 through the observed stream head. Unknown versions, malformed
records, gaps, missing rows or pruned history return an unknown bounded
failure. The Assembly never creates or loads a Store checkpoint. An unused
checkpoint does not affect replay of intact complete history, and no
checkpoint can authorize skipping missing/pruned records or resetting
identity. There is no receipt TTL, compaction, deletion or reset API.

Known Store CAS conflicts reload and re-evaluate at most three times, checking
identity before callbacks. An indeterminate append is checked with the
existing nonce/record confirmation API. Unresolved, superseded or unavailable
append status returns `{:unknown, reason}` and never triggers automatic
re-append. The host reconciles unknown attempts using `result/3` and the Store's
retained history; absence is not proof of abort. Outbox records remain pending
until the host's separate outbox owner acknowledges them. This Piece never
executes the remote effect and does not claim exactly-once delivery.

The tenant-wide stream name is intentionally derivable without inspecting the
handle or calling an Assembly helper. For a tenant already validated as a
1..128-byte UTF-8/no-NUL identity, the exact versioned encoding is:

```elixir
"cc1:" <>
  Base.url_encode64(
    :erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]),
    padding: false
  )
```

The same stream holds that tenant's receipts, resource projection, Approval
events and outbox items. A host that already owns the Store can use the
ordinary Outbox/Store pending and acknowledgement boundaries; no private
handle inspection or adapter wrapper is needed:

```elixir
stream =
  "cc1:" <>
    Base.url_encode64(
      :erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]),
      padding: false
    )

{:ok, items} = Elzoo.Outbox.pending(store, stream, 64)

Enum.each(items, fn item ->
  case host_effect_commit(item.idempotency_key, item.destination, item.payload) do
    :committed ->
      case Elzoo.Outbox.ack(store, item.idempotency_key, item.nonce) do
        {:committed, _revision} -> :ok
        {:conflict, _} -> reconcile_ack(item)
        {:indeterminate, _} -> reconcile_ack(item)
        {:rejected, _} -> reconcile_ack(item)
      end

    :unknown ->
      reconcile_effect(item)

    :failed ->
      leave_pending(item)
  end
end)
```

`host_effect_commit/3` and reconciliation above are host-owned placeholders,
not Assembly APIs. Dispatch must use the committed idempotency key according to
the destination's contract; acknowledge only after the host's effect commit
point. An unknown effect or acknowledgement is not proof of failure and must
not be replaced with a new key. The runnable PostgreSQL example derives this
same stream and reads its pending items; it deliberately neither dispatches
nor acknowledges a remote effect.

Finite bounds are enforced before append: identities and resource write-field
names 1..128 UTF-8 bytes without NUL; expected resource revisions 0..2^63-2;
at most 64 resources and 64 fields per resource; canonical request and encoded
resource at most 65,536 bytes each. Encoded resource size is the deterministic
Erlang term encoding of exactly `%{revision: revision, fields: fields}` (tenant
and resource identifiers are not part of that representation); response at
most 8,192 encoded bytes; record at
most 1,048,576 bytes; 1,024 retained operations and 4,096 stream records.
Existing Authorization and Approval bounds also apply. Values are refused,
never truncated or evicted. These finite byte/count limits do not prove
allocation safety against a hostile host callback or production scalability.

The 4,096-record ceiling is an independent guard, not a reachable target under
the smaller operation bound: each retained operation contributes one initial
record and an ASK operation can contribute at most one terminal release record,
so a usable stream is limited to 2,048 records. A resource revision is likewise
bounded by the 1,024 retained operations. The wider integer bounds are defensive
input and replay checks; this Piece has no import or checkpoint path that can
bypass the append-only operation history.

Copied-source/provider closure includes `integration/sql` (consumer-owned Repo
and migrations; `ecto_sql`/`postgrex`), `state/event-log`, `state/outbox`,
`core/payload-schema`, `workflow/pattern-step`, `domain/authorization`,
`workflow/approval`, `domain/trigger-binding`, and `Elixir`/OTP plus Jason for
the fixed notification encoding. The consumer owns its Repo, schema lifecycle,
database permissions, PostgreSQL durability settings, backups and operational
reconciliation. Local tests use a disposable PostgreSQL database and never
substitute Memory for those SQL checks.

## PostgreSQL binding example

`examples/elzoo/postgres_trigger_binding.exs` is a runnable, bounded binding
caller. From the repository root, configure `ELZOO_TEST_DATABASE_URL` to a
disposable PostgreSQL database and run:

```sh
mix run pieces/assembly/checked-command/examples/elzoo/postgres_trigger_binding.exs
```

The example creates a temporary schema, invokes the existing SQL migration
helper through the consumer-owned Repo, installs and CAS-updates a
TriggerBinding, reads it back, and calls the real
`TriggerBinding.validate_declaration/1` and `select/3`. It checks declaration
ID/tenant/source/revision mismatches and a stale expected revision without
changing the resource or outbox. A deliberately different payload tenant/source
does not replace the trusted tenant/source facts. Its local Approval evidence
is a purpose/key-bound demonstration fixture, not authenticated evidence; a
production host must supply a command-verifier-authenticated receipt. The
example drops its temporary schema on completion, never dispatches the pending
outbox notification, and creates no Run or budget.

## Evidence

With the SQL test helper available, `mix test
pieces/assembly/checked-command/test` runs 43 finite Piece tests, including 17
against real PostgreSQL for message duplicate refusal, distinct-identity
revision races, ASK key bounds and self-approval refusal, Store response-loss/
paused-transaction boundaries and checkpoint-independent full-history replay.
The copied dependency closure includes `integration/sql` and its helper at
`test/support/durable_log_postgres_test_helper.exs`; the CheckedCommand tests
load that helper and run all 17 tagged PostgreSQL cases against the disposable
consumer database. The per-ID consumer runs the CheckedCommand tests, not the
dependency Piece's own tests. The selected Piece gate is still a selected
check, not the full repository check. Tests and local
PostgreSQL observations are finite evidence, not proofs of production
durability, host identity, external effects or universally exactly-once
behavior.
