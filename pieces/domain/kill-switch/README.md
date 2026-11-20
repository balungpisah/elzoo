# domain/kill-switch

`Elzoo.KillSwitch` suspends a tenant, a recipe or a tool through an audited
`assembly/checked-command` command, and gives every gate one pure decision
that refuses work for a suspended target. It has two halves:

- **Change.** `prepare/3` is a CheckedCommand preparer. It engages or releases
  one switch in the `"switches"` field of a tenant control resource, so every
  change is a retained, revision-fenced checked command. A host policy that
  answers ASK gets dual control through ready `workflow/approval`
  (`reviewer != proposer`).
- **Check.** `check/2` is a pure decision over the value that the host just
  read with `CheckedCommand.resource/3`. A missing, unreadable or malformed
  read is a refusal too.

No I/O, clock, process, storage, telemetry or log. CheckedCommand, RunEngine,
Authorization and Approval are used through their public APIs and not changed.

## Switches

A switch is the portable record

```elixir
{:record, [{"engaged_at", ms}, {"id", {:text, id}}, {"kind", {:text, kind}},
           {"reason", {:text, reason}}]}
```

- `kind` is `"tenant"`, `"recipe"` or `"tool"`;
- `id` is 1..128 bytes of valid UTF-8 without C0 or C1 control characters (the
  `domain/principal` text rule);
- `reason` is 1..64 bytes of `[a-z0-9_]` (the gate code rule of both engines);
- `ms` is an integer `0..9_223_372_036_854_775_807`.

The field value is `{:list, switches}`: 0..64 entries, unique by
`{kind, id, reason}` and sorted by those bytes. Several reasons may hold one
target; it is suspended while any of them is engaged.

## Change: `prepare/3`, `engage/2`, `release/2`

`Elzoo.KillSwitch.prepare(snapshot, request, facts)` follows the CheckedCommand
preparer contract. The payload is exactly

```elixir
%{"op" => "engage" | "release", "kind" => kind, "id" => id, "reason" => reason}
```

and `facts.data` is exactly `{:record, [{"now", ms}]}`; `engaged_at` is that
`now`. It returns `{:ok, [%{target: request.resource, field: "switches",
value: list}], {:record, [{"engaged", count}, {"revision", next_revision}]}}`
or `{:refused, code}`, with codes in this order:

1. `invalid_request`: payload, facts or snapshot shape, including a malformed
   stored `"switches"` value;
2. `reserved_reason`: a reason starting with the bytes `lifecycle`, reserved
   for `workflow/tenant-lifecycle`;
3. `cross_tenant`: a `tenant` switch whose `id` is not the snapshot tenant;
4. `already_engaged`, `not_engaged` or `too_many` (a 65th entry).

The preparer reads and writes only `"switches"`. CheckedCommand writes per
field, so other fields of the same resource (for example the lifecycle fields
of `workflow/tenant-lifecycle`) are kept.

`engage(list, switch)` and `release(list, {kind, id, reason})` are the pure
list transitions behind `prepare/3`. They return `{:ok, list}` or
`{:error, :invalid | :already_engaged | :not_engaged | :too_many}` and accept
reserved reasons, for a composer that writes its own switch in the same append.

A kill-switch descriptor is ordinary CheckedCommand configuration. Its gate is
the host's own policy and **does not call `check/2`**, or a suspended tenant
could never be released:

```elixir
{:ok, kill_switch} =
  Elzoo.CheckedCommand.new(store, %{
    id: "kill-switch/change", version: 1, content_hash: hash,
    effect_class: "kill_switch", port: port, schema: schema,
    prepare: &Elzoo.KillSwitch.prepare/3,
    gate: %{call: fn _frame, _context -> :allow end},
    approval: %{verifiers: ["command-reviewer"], max_age: 60_000}
  })
```

The host gives the operator exact-value Authorization authority for the one
`"switches"` value of the change, and an ASK rule for `effect_class:
"kill_switch"` when it wants a second person.

## Check: `check/2` and the gate

`Elzoo.KillSwitch.check(read, target)` takes `read`, the exact return value of
`CheckedCommand.resource/3`, and `target`, exactly `%{tenant: t, recipe: r |
nil, tool: name | nil}`. In this order:

1. `read` is not `{:ok, %{tenant: t, resource: _, revision: _, fields: fields}}`
   for the target tenant with a valid or absent `"switches"` field, or the
   target is malformed: `{:deny, "kill_switch_unavailable"}`. An absent field
   (revision 0 included) means no switch is engaged.
2. A `tenant` switch for `t`: `{:deny, "tenant_suspended"}`.
3. A `recipe` switch for `r`: `{:deny, "recipe_suspended"}`.
4. A `tool` switch for `name`: `{:deny, "tool_suspended"}`.
5. Otherwise `:allow`.

`check/2` never raises. Codes never echo an ID.

Both engines take a pure gate fixed at construction, so a gate closes over one
read. In each gate the host maps the action to a tool name that it trusts (for
example a `workflow/tool-registry` alias):

```elixir
read = Elzoo.CheckedCommand.resource(kill_switch, scope, "control")

gate = %{
  call: fn {:PatternStep, %{"actions" => [action]}}, %{tenant: tenant} ->
    Elzoo.KillSwitch.check(read, %{
      tenant: tenant,
      recipe: recipe,
      tool: Map.get(trusted_tools, action["schema_id"])
    })
  end
}
```

- **CheckedCommand.** The gate is part of the descriptor passed to
  `CheckedCommand.new/2`. Take the read immediately before each `execute/3` or
  `release/4` and build a new handle with a descriptor whose gate closes over
  that read. A gate denial is retained as `{:denied, {:gate, code}}` under its
  operation ID, so a command refused while a switch was engaged needs a new
  `operation_id` after the release.
- **RunEngine.** `gate` (with its `id` and `version`) is fixed at
  `RunEngine.start_link/1`. Take the read before `start_link/1`, call
  `check(read, %{tenant: t, recipe: r, tool: nil})` and start no Run unless it
  allows, then pass a gate over that same read. That gate cannot see a switch
  engaged later: when the host engages a switch that covers a live Run, it
  pauses the Run with `control/4`, and continues it with the verified-person
  continue control of `control/4` once the switch is released. A restarted
  engine is built over a fresh read.

A `workflow/tenant-lifecycle` descriptor's gate skips `check/2` only for its
lifecycle ops, so a suspended tenant can be reactivated, and calls it for every
other op.

## Limits

- A switch takes effect at the host's next read before a call; a call already
  running uses the read it started with.
- A RunEngine gate sees only the read taken before `start_link/1`; a live Run
  is stopped by the host's Run control, not by the gate. That composition is
  not exercised by this Piece's tests (the ELZ-286 acceptance shows it). A gate
  verdict RunEngine already committed survives restart, so admitted actions and
  their effects are not recalled.
- No platform-wide switch across tenants, no expiry or timer, no wildcard or
  prefix target. The tool name and recipe are the host's trusted mapping.

## Evidence

`mix test pieces/domain/kill-switch/test` runs the finite scenarios named in
`piece.json`: preparer transitions and refusal order, every shape bound,
`check/2` codes, order, unavailable reads and generated terms, and real
CheckedCommand composition on the Memory Store (engage, retained gate denial,
release, replay, ASK with a distinct reviewer and self-approval refused). The
selected Cure laws cover only the verdict order over the flags Elixir supplies.
`examples/kill_switch.exs` engages and releases a tool switch and checks the
read after each step. Tests are finite scenarios, not proofs.
