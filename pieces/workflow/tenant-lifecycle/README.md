# workflow/tenant-lifecycle

`Elzoo.TenantLifecycle` moves a tenant through its lifecycle and consumes
one-use invitations as `assembly/checked-command` commands. It is a pure
preparer Piece: no store, process, I/O, clock, telemetry or log of its own.
The code calls only the public `Elzoo.KillSwitch.engage/2`, `release/2` and
`check/2` and `Elzoo.PatternStep.encode/1`; the host runs it inside
`Elzoo.CheckedCommand`, with `workflow/approval` for dual control and
`domain/membership` for the accepted membership. None of them is changed.

It works over the tenant control resource that `domain/kill-switch` also uses.
It reads and writes the `"lifecycle"` and `"invitations"` fields. On a
transition that suspends or reactivates the tenant it also writes
`"switches"`, through the public `Elzoo.KillSwitch.engage/2` and `release/2`
with the reserved reason `lifecycle`. The status and the switch that every
gate checks therefore change in one append. CheckedCommand writes per field,
so other fields of the resource are kept.

Not in this Piece: storing memberships (the host applies an accepted
invitation from the response or from the descriptor's outbox notice), erasing
data (the host calls `state/retention-erasure` and reports it as a fact),
sending invitation codes, reminders, resends, expiry sweeps and jobs.

## Lifecycle

The `"lifecycle"` field value is `{:text, state}` with one of `provisioned`,
`active`, `suspended`, `closing` or `erased`. An absent field is the state
`none`.

| Command (`"op"`) | From | To | Switch with reason `lifecycle` |
| --- | --- | --- | --- |
| `provision` | `none` | `provisioned` | engaged (no work before activation) |
| `activate` | `provisioned`, `suspended` | `active` | released |
| `suspend` | `active` | `suspended` | engaged |
| `close` | `active`, `suspended` | `closing` | engaged (kept if already engaged); every pending invitation is removed |
| `erase` | `closing` | `erased` | kept |

`erase` also requires the trusted fact `vault_erased: true`, which the host
sets only after `state/retention-erasure` reported every subject of the
tenant `erased`. `erased` is terminal: every command there is refused
`terminal`. A switch of another reason (an operator's `incident` switch) is
independent: `activate` releases only the `lifecycle` switch. A written
switch has `engaged_at` equal to `now * 1000`, the kill-switch millisecond
unit. A command that would engage the lifecycle switch on a list that already
holds 64 other switches is refused `too_many`.

## Invitations

The `"invitations"` field value is `{:list, invitations}`: 0..32 pending
invitations, unique and sorted by ID. Each one is the portable record

```elixir
{:record, [{"code_digest", {:bytes, <<_::256>>}}, {"expires_at", unix_s},
           {"id", {:text, id}}, {"invitee", nil | {:text, principal}},
           {"issued_by", {:text, actor}}, {"role", {:text, role}},
           {"space", {:text, space}}]}
```

- `invite` (status `active` only) adds one. The payload carries `id`, `space`,
  `role`, `invitee` (`nil` for anyone) and `expires_at`, which must be after
  `now`. The facts carry `code_digest`, `known_target: true` (the host checked
  that the space and role exist in the tenant) and `inviter_may_grant: true`
  (the host resolved, for example with `domain/membership`, that the inviter
  holds the permission it hands out). `issued_by` is the trusted actor.
- `accept` (status `active` only) consumes one. The payload carries `id`; the
  facts carry `presented_digest`; the accepter is the trusted actor. On
  success the invitation is removed and the response is the membership record
  with exactly the six `domain/membership` keys:

  ```elixir
  {:record, [{"principal", {:text, actor}}, {"revoked_at", nil}, {"role", {:text, role}},
             {"space", {:text, space}}, {"valid_from", now}, {"valid_to", nil}]}
  ```

  Decoded into the atom-keyed map
  `%{principal:, space:, role:, valid_from:, valid_to: nil, revoked_at: nil}`
  it is a membership fact for `Elzoo.Membership.permissions/4`.
- `revoke` (any state with invitations) removes one.

### The code

The host makes a random code of **at least 128 bits**, sends it out of band and
puts only its SHA-256 into the `invite` facts. On `accept` it hashes the code
the person presented into `presented_digest`. The code never enters command
history; digests are compared with `:crypto.hash_equals/2`. An unkeyed
SHA-256 is enough only for such a high-entropy random code.

### Single use

Single use follows from removal plus CheckedCommand's revision fencing. Two
accepts with distinct operation IDs at one revision commit at most once; the
other is retained as `{:conflict, :stale_revision}`. A replay of the
committed operation returns its first result, and a later accept with a new
operation ID is `unknown_invitation`. A refused accept (a digest mismatch
included) commits nothing and leaves the invitation pending.

## `prepare/3`

`Elzoo.TenantLifecycle.prepare(snapshot, request, facts)` follows the
CheckedCommand preparer contract. It returns `{:ok, writes, response}` with
1..3 writes on `request.resource`, or `{:refused, code}`. The payload is a
string-keyed map with `"op"` and exactly that command's fields. `facts.data`
is an exact portable record per command:

| Command | `facts.data` fields |
| --- | --- |
| `provision`, `activate`, `suspend`, `close`, `revoke` | `now` |
| `erase` | `now`, `vault_erased` |
| `invite` | `code_digest`, `inviter_may_grant`, `known_target`, `now` |
| `accept` | `now`, `presented_digest` |

`now` is Unix seconds, the `domain/membership` convention, an integer
`0..9_223_372_036_854_775` (so `now * 1000` fits the kill-switch bound);
`expires_at` has the same range. Digests are exactly 32 bytes. IDs, spaces,
roles, principals, the tenant and the resource follow the `domain/principal`
text rule: 1..128 bytes of valid UTF-8 without C0 or C1 control characters.

A lifecycle command answers
`{:record, [{"lifecycle", {:text, state}}, {"pending", count}, {"revision", next}]}`,
as do `invite` and `revoke`; `accept` answers the membership record.

Refusal codes, in this order:

1. `invalid_request`: payload, facts, request or snapshot shape, including a
   malformed stored `"lifecycle"`, `"invitations"` or `"switches"` field, and
   `invite` with `expires_at <= now`;
2. `terminal`: any command in `erased`;
3. `invalid_transition`: a lifecycle op from a state with no row for it;
4. `not_active`: `invite` or `accept` when the state is not `active`;
5. `not_erased`: `erase` with `vault_erased` other than `true`;
6. `not_permitted`: `known_target` or `inviter_may_grant` other than `true`;
7. `duplicate` (an existing ID) or `too_many` (a 33rd invitation) for
   `invite`; `unknown_invitation` (absent, used, revoked or removed),
   `expired` (`now >= expires_at`), `bad_code`, `wrong_invitee` for `accept`,
   in that order; `unknown_invitation` for `revoke`.

## The lifecycle descriptor and `gate/1`

`Elzoo.TenantLifecycle.gate(read)` is the gate of the lifecycle descriptor
over the exact return of `CheckedCommand.resource/3`. For the five lifecycle
ops it allows without calling `Elzoo.KillSwitch.check/2`, or a suspended
tenant could never be activated. For `invite`, `accept` and `revoke` it calls
`check(read, %{tenant: tenant, recipe: nil, tool: nil})` like every other
gate, so a tenant switch of any reason refuses them as
`{:denied, {:gate, "tenant_suspended"}}`. `revoke` is therefore refused while
any tenant switch is engaged, including in `provisioned` and `suspended`;
`close` still removes every pending invitation. The frame is read through the
public `Elzoo.PatternStep.encode/1`.

The gate closes over one read, so take the read immediately before each
`execute/3` or `release/4` and build a new handle:

```elixir
read = Elzoo.CheckedCommand.resource(any_handle, scope, "control")

{:ok, lifecycle} =
  Elzoo.CheckedCommand.new(store, %{
    id: "tenant-lifecycle/command", version: 1, content_hash: hash,
    effect_class: "tenant_lifecycle", port: port, schema: schema,
    prepare: &Elzoo.TenantLifecycle.prepare/3,
    gate: Elzoo.TenantLifecycle.gate(read),
    approval: %{verifiers: ["command-reviewer"], max_age: 60_000},
    outbox: "membership-notifications"
  })
```

The host gives the actor exact-value Authorization authority for the writes of
the command, and an ASK rule for `effect_class: "tenant_lifecycle"` when it
wants a second person (for example for `suspend` or `close`); release then
needs a reviewer other than the proposer through `workflow/approval`. A gate
denial is retained under its operation ID: a command refused while a switch
was engaged needs a new `operation_id` after the release.

`Elzoo.TenantLifecycle.status(read)` returns `{:ok, state}` (`"none"` for an
absent field) or `{:error, :unavailable}` for any other read, for host checks
such as "issue tokens only for an `active` tenant".

## Limits

- The host vouches for the actor, the inviter's rights, target existence,
  erasure completion and the time.
- A code's secrecy is the host's; the code must be at least 128 random bits.
- No membership store: the host applies the accept response or the outbox
  notice at most once per command identity.
- No reminder, resend or expiry sweep: an expired invitation stays until
  revoked or until `close`.
- A command that a policy answers ASK is prepared again at release with the
  facts retained at proposal, so its `now` (and an `accept`'s expiry check) is
  the proposal time. Use ASK for lifecycle ops; the Approval evidence age and
  expiry bound the delay.
- Values that break the text rule are refused `invalid_request`, failing
  closed, also for a tenant ID that CheckedCommand itself would accept.

## Evidence

`mix test pieces/workflow/tenant-lifecycle/test` runs the finite scenarios
named in `piece.json`: the transition table enumerated over every state and
lifecycle op, the switch writes and `check/2` after them, every invitation
refusal and its order, every shape bound, and real CheckedCommand composition
on the Memory Store (commit, replay, one use under a race, ASK with a distinct
reviewer, activate through the gate on a suspended tenant, gate denials under
an incident switch, and the membership response accepted by
`Elzoo.Membership.permissions/4`). The selected Cure laws cover only the
transition table over the state and command Elixir decodes.
`examples/tenant_lifecycle.exs` provisions, activates, invites and accepts.
Tests are finite scenarios, not proofs.
