# ELZ-281 — Suspend a tenant, recipe or tool through an audited checked command that every gate refuses on

- Phase: Wave 5 Level 3 (sub-level 3a)
- Dependencies: ELZ-033, ELZ-024, ELZ-249
- Release: V1B
- Output: new `domain/kill-switch` Piece
- Change class: Piece-only
- Owned paths: `pieces/domain/kill-switch/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (`assembly/checked-command`, `assembly/run-engine`, `domain/authorization`, `workflow/approval`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One pure Piece in plain Elixir (Cure where a pure decision fits; no new provider). It has two halves.

- **Change.** A pure preparer for ready `assembly/checked-command` (ELZ-249) engages or releases one switch in the `"switches"` field of a tenant control resource. Every change is then a retained, revision-fenced checked command. A host policy that answers ASK gets dual control through `workflow/approval`; that `reviewer != proposer` rule is ready and unchanged.
- **Check.** A pure decision over the resource that the host just read with `CheckedCommand.resource/3` refuses work for a suspended tenant, recipe or tool. A missing, unreadable or malformed read is a refusal too (owner decision of 2026-11-20).

The host writes its RunEngine and CheckedCommand gate (`call/2`, returning `:allow` or `{:deny, code}`) as a few lines that map the frame to a target and call `check/2`. The README shows that gate. Gate callbacks do no I/O: both engines require pure callbacks. So the host takes the `resource/3` read immediately before each `CheckedCommand.execute/3` or `release/4` and each RunEngine `input/4`, and builds the gate over that read. No wrapper of either engine, no process, no clock, no storage of its own. CheckedCommand, RunEngine, Authorization and Approval are not edited.

The preparer reads and writes only the `"switches"` field. CheckedCommand applies writes per field (`Map.put` per written field), so other fields of the same resource are kept. Level 3 `workflow/tenant-lifecycle` (ELZ-284) uses that to write its own fields beside it.

## Interface

A switch is the portable record `{:record, [{"engaged_at", ms}, {"id", {:text, id}}, {"kind", {:text, kind}}, {"reason", {:text, reason}}]}`. `kind` is `tenant`, `recipe` or `tool`. `id` follows the `domain/principal` text rule (1..128 bytes of valid UTF-8 without C0 or C1 control characters). `reason` is 1..64 bytes of `[a-z0-9_]`, the gate code rule of both engines. `ms` is an integer `0..9_223_372_036_854_775_807`. The field value is `{:list, switches}`: 0..64 entries, unique by `{kind, id, reason}` and sorted by those bytes. Several reasons may hold one target; the target is suspended while any of them is engaged.

- `Elzoo.KillSwitch.prepare(snapshot, request, facts)` follows the CheckedCommand preparer contract. It returns `{:ok, [write], response}` with one write `%{target: request.resource, field: "switches", value: list}`, or `{:refused, code}`. The payload is exactly `%{"op" => "engage" | "release", "kind" => kind, "id" => id, "reason" => reason}`. `facts.data` is exactly `{:record, [{"now", ms}]}`, and `engaged_at` is that `now`. Refusal codes, in this order:
  1. `invalid_request` for the payload, facts or snapshot shape, including a malformed stored `"switches"` value;
  2. `reserved_reason` for a reason starting with `lifecycle`, which is reserved for ELZ-284;
  3. `cross_tenant` for a `tenant` switch whose `id` is not the snapshot tenant;
  4. `already_engaged`, `not_engaged` or `too_many` (a 65th entry).

  The response is `{:record, [{"engaged", count}, {"revision", next_revision}]}`.
- `Elzoo.KillSwitch.engage(list, switch)` and `release(list, {kind, id, reason})` are the pure list transitions behind `prepare/3`. They return `{:ok, list}` or `{:error, :invalid | :already_engaged | :not_engaged | :too_many}` and accept reserved reasons, for a composer such as ELZ-284.
- `Elzoo.KillSwitch.check(read, target)` returns `:allow` or `{:deny, code}`. `read` is the exact return value of `CheckedCommand.resource/3`. `target` is exactly `%{tenant: t, recipe: r | nil, tool: name | nil}`. Order:
  1. `read` is not `{:ok, %{tenant: t, resource: _, revision: _, fields: fields}}` with `t` equal to the target tenant and a valid or absent `"switches"` field: `{:deny, "kill_switch_unavailable"}`. An absent field (revision 0 included) means no switch is engaged.
  2. A `tenant` switch for `t`: `{:deny, "tenant_suspended"}`.
  3. A `recipe` switch for `r`: `{:deny, "recipe_suspended"}`.
  4. A `tool` switch for `name`: `{:deny, "tool_suspended"}`.
  5. Otherwise `:allow`.

  A malformed `target` is also `"kill_switch_unavailable"`. `check/2` never raises.

Before `RunEngine.start_link/1` the host calls `check/2` with `tool: nil`. In each gate it maps the action to a tool name that it trusts, for example a `workflow/tool-registry` alias. Errors and denials are fixed codes that never echo an ID. The Piece emits no telemetry and no log.

## Acceptance

1. `prepare/3`: engage and release each kind; two reasons on one target, where releasing one leaves the target suspended; `already_engaged`, `not_engaged`, `too_many` (64 pass, 65 refused), `reserved_reason` (`lifecycle`, `lifecycle_x`; `lifecyclex` too, since the rule is a byte prefix) and `cross_tenant`. Fields other than `"switches"` in the snapshot are ignored and never written. The stored list is canonical (sorted, unique) whatever the engage order.
2. Shape: payload with a missing, extra or non-string key; kind `Tenant`; IDs at 0, 1, 128 and 129 bytes, invalid UTF-8, NUL, DEL and U+0085; reasons of 65 bytes and with an uppercase letter; `now` at −1, 2^63 and as a float; a stored list that is unsorted, has a duplicate or holds 65 entries. Each is `invalid_request`.
3. `check/2`: each deny code and its order (a tenant switch wins over recipe and tool switches); `:allow` with switches for other targets; revision 0 with `fields: %{}` allows. `:not_found`, `{:refused, :invalid_request}`, `{:unknown, :storage}`, a view of another tenant, a malformed list and a malformed target each give `"kill_switch_unavailable"`. Arbitrary terms never raise.
4. Real composition on the Memory Store: a CheckedCommand descriptor whose preparer is `Elzoo.KillSwitch.prepare/3`. An engage commits; `resource/3` then feeds `check/2`, which denies; a release commits and `check/2` allows. A second descriptor's command, whose gate is the README gate over a `resource/3` read taken just before each `execute/3`, is refused with the gate's `tenant_suspended` code while the switch is engaged and committed after the release. Replay of the engage operation returns its retained result. A host policy that answers ASK leaves the switch unchanged until `release/4` with valid once-evidence from a reviewer other than the proposer. The same reviewer as the proposer is refused by the ready Approval rule.
5. Negative controls, one at a time: let `check/2` allow on an unavailable read; skip the reserved-reason refusal; check recipe before tenant. Each must make a case of groups 1 or 3 fail. Restore before the final gates.

Limits to state: a switch takes effect at the host's next read before a call; a call already running uses the read it started with. A gate verdict that RunEngine already committed survives restart, so admitted actions and their effects are not recalled. Stopping live Runs is the host's Run control, and ELZ-286 shows it. No platform-wide switch across tenants, no expiry or timer, no wildcard or prefix target. The tool name is the host's mapping. Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
