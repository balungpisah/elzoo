# ELZ-346 — Grant a child Run less authority and a budget share, refuse deep or cyclic delegation, and decide what a parent's end does to each child

- Phase: Wave 8 Level 1
- Dependencies: ELZ-033, ELZ-267, ELZ-024
- Release: V1B
- Output: new `workflow/delegation` Piece (absorbs the delegation part of the handle `workflow/loop-guard`)
- Change class: Piece-only
- Owned paths: `pieces/workflow/delegation/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (including `domain/principal`, `domain/authorization`, `workflow/version-pin` and `workflow/run`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One pure Piece in plain Elixir: when a bot's callable asks for a child Run, `grant/2` decides the child's principal, authority, budget share, depth, lineage, pinned recipe version and parent-close rule, or refuses the whole request; `on_parent_close/1` decides, for the open children of a parent that ended, what the host does to each. The Contract source is the `workflow/delegation` section of [the Wave 8 plan](../docs/plans/bot-platform-wave8.md) ("Level 1"), under owner answers Q3 A and Q6 A (2026-11-23; [choices](../docs/choices.md#wave-8-owner-choices-2026-11-23)) and the owner's settled decisions 2 and 3 of 2026-11-21 (the parent-close rule per child, default request cancel; the inherited pin).

A child Run starts through a `tool_call` whose host binding records the work item, pins the version and starts the child (Q3 A): the host does that, not this Piece. The Piece has no I/O, clock, process or store, and starts, cancels or messages no Run.

The Piece makes authorization and identity decisions (who the child acts as and what it may do), so it is not low-risk under `AGENTS.md` section 5: this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"); the hosted `check-piece` run does not replace the local run.

## Facts on `main` that this task builds on

Checked at `main` `bce5ea99`:

- `Elzoo.Principal.delegate(parent, %{id, allowed_scopes, allowed_spaces})` builds an `:agent` only from a `:human` or `:service` parent that passes revalidation (else `:parent`; an `:agent` parent is `:nested_delegation`), refuses the parent's own ID (`:self_delegation`) and any scope or space the parent does not hold (`:escalation`, the whole request), and copies tenant and epoch, with `delegated_by` the parent's ID. Its errors are `:parent`, `:nested_delegation`, `:shape`, `:id`, `:self_delegation`, `:scopes`, `:spaces` and `:escalation`. IDs, scopes and spaces are 1..128 bytes of valid UTF-8 without a C0 or C1 control character; scope and space lists hold 0..256 labels. Its `piece.json` limits say "One delegation level only".
- `Elzoo.Authorization.validate_authority(writes)` validates and normalizes a trusted authority set and returns `{:ok, writes}` or `{:error, {:unavailable_context, reason}}`; `decide/3` takes `parent: [write] | :none` as "current parent effective authority, for a child Run", and a proposal must be a subset of both `own` and `parent` (the intersection), else the whole proposal is refused `:authority_exceeded`.
- `workflow/budget` amounts are positive integers in the unit's smallest denomination.
- `workflow/run` `cancel` "targets exactly this execution Attempt", and `workflow/version-pin` takes the pinned version at the child's start as host input (`new/2`). The library calls neither, so neither is a dependency (the plan listed ELZ-170; a coordinator check against `main`).

## Interface

Module `Elzoo.Delegation`.

- `grant(facts, request)` returns `{:ok, grant}` or `{:error, reason}`.
  - `facts` are trusted parent facts, exactly `%{root, parent, authority, budget_remaining, max_depth, lineage, revoked_ids, pin}`: `root` the `:human` or `:service` principal at the top of the lineage; `parent` the principal of the callable that asks, either `root` itself or an `:agent` whose `delegated_by` is the root's ID and whose tenant is the root's; `authority` the parent's current effective authority, an authority set for `domain/authorization`; `budget_remaining` a non-negative integer; `max_depth` the host's declared bound, 1..8, no default; `lineage` the ordered list of 0..8 distinct bot IDs from the root Run to the parent, empty exactly when `parent` is `root` and otherwise ending with the parent's ID; `revoked_ids` the host's current revocation facts, a list of 0..1,024 IDs; `pin` the parent's pinned identity, 1..128 bytes.
  - `request` is exactly `%{child_bot, scopes, spaces, budget, parent_close, change}`: `child_bot` an ID; `scopes` and `spaces` label lists as `domain/principal` takes them; `budget` an integer; `parent_close` `:abandon`, `:request_cancel`, `:cancel` or `nil` (the default, `:request_cancel`); `change` `nil` or `%{pin, ref}`.
  - `grant` is exactly `%{principal, parent_authority, budget, depth, lineage, pin, change_ref, parent_close}`: `principal` from `Elzoo.Principal.delegate(root, %{id: child_bot, allowed_scopes: scopes, allowed_spaces: spaces})`; `parent_authority` the validated `authority`, which the host gives as `parent` in the child's `domain/authorization` context, so the child never holds more than its parent; `budget` the reserved share; `depth` the length of the lineage plus 1; `lineage` the lineage with `child_bot` appended; `pin` the parent's `pin`, or `change.pin` when `change` is set; `change_ref` `nil` or `change.ref`; `parent_close` the rule, the default filled in.
- `on_parent_close(children)` takes the open children of an ended parent, a list of 0..256 entries `%{child_run_id, parent_close}` with distinct `child_run_id`s (1..200 bytes of valid UTF-8 without NUL, the `workflow/run` ID rule), and returns `{:ok, actions}`, one entry per child in the same order, or `{:error, :malformed}`:
  - `%{child_run_id, action: :abandon}`: the child goes on; its later result is given to no one;
  - `%{child_run_id, action: :request_cancel, message: payload}`: the host delivers one cancel request to the child when the child Run is idle (for example through the child's own one-link `delivery/durable-mailbox` chain), `payload` the `elzoo.delegation.cancel_requested` version 1 map `{"child_run_id": id, "reason": "parent_closed"}`; the child's pattern decides what to do, and a request to a child that never idles stays pending until the child ends;
  - `%{child_run_id, action: :cancel}`: the host cancels the child's current Attempt through `workflow/run`, which settles its open actions by the engine's rules.

## Rules

`grant/2` checks, in this fixed order, and returns the first failure; a refusal refuses the whole request:

1. `:malformed`: any shape or bound above, `root` not a valid `:human` or `:service` principal (a principal is revalidated with `Elzoo.Principal.check(principal, %{current_epoch: 0, revoked_ids: []})`, which is `:ok` for every valid principal and `{:error, :malformed}` otherwise), `parent` neither `root` nor an `:agent` delegated by `root` in its tenant, a lineage that is not empty exactly when `parent` is `root` or does not end with the parent's ID, an `authority` that `Elzoo.Authorization.validate_authority/1` refuses, a `change` that is not a map of exactly the keys `pin` and `ref`, or whose `pin` is not 1..128 bytes.
2. `:revoked`: the root, the parent, `child_bot` or any bot of the lineage is in `revoked_ids` (the child's `delegated_by` names the root only, so the lineage is where a revoked middle bot is seen).
3. `:stale`: `parent` is an `:agent` whose `auth_epoch` is below the root's `auth_epoch`, so a revocation by epoch of the root is seen before the parent mints a child with the root's newer epoch (coordinator decision of 2026-11-23, in place before the first release).
4. `:depth`: the length of the lineage plus 1 is over `max_depth`.
5. `:cycle`: `child_bot` is the root's ID or already in the lineage (so `domain/principal`'s `:self_delegation` is never reached).
6. `:escalation`: a requested scope or space is not held by the parent (`allowed_scopes` and `allowed_spaces` of the parent principal, the root's own for a root parent).
7. `:budget`: `budget` is not a positive integer of at most `budget_remaining`.
8. `:version_change`: `change` is not `nil` and its `ref` is `nil` or not 1..256 bytes of valid UTF-8 without a C0 or C1 control character (a reference of the host's authorised, recorded action; the Piece checks only that it is there).
9. `Elzoo.Principal.delegate/2` from the root. A refusal is `{:error, {:principal, reason}}` with its reason unchanged; after steps 1–8 none is expected, and the tests show which reasons remain reachable.

The parent is the callable whose `tool_call` started the child (in a room, a bot's turn). A child's parent has ended when the child-start `tool_call` slot settles without the child's result: at its deadline, at a change of Attempt or at the end of the Run (a callable does not close because its actions settle, so the slot is the trigger). A room rolls over only with nothing open, so a rollover never ends the parent of a child whose slot is still open. The README states this, with the default: a `:request_cancel` reaches a child only when the child is idle, so a busy agent-loop child, which has an action open from its start to its finish, sees no cancel request before it ends (the owner's reading, recorded with the 2026-11-23 answers).

Errors are fixed atoms, or `{:principal, atom}` with a reason of `domain/principal` (step 9), and never echo an ID, scope or space. The task records whether Cure owns a decision (for example a selected law that a granted child's scopes are within the parent's, or that the depth never passes `max_depth`) or states it as test-grounded plain Elixir. `piece.json` declares telemetry, config and control `not_applicable`, and the dependencies `domain/principal` and `domain/authorization`.

## Kept open (owner's "no corner" rule)

Each option below can be added in place before the first release without breaking a caller: the facts, request and grant maps may gain optional keys, and the parent-close, action and error sets may gain members; a request that is valid now gets the same grant.

- *Multi-level delegation in `domain/principal`* (Q6 B): a later in-place change of that Piece; the grant's lineage already records the path.
- *An `allowed_patterns` key of the grant,* narrowed per child like scopes, for a runtime rule switch of subagents (owner, 2026-11-23).
- *A fan-out bound per parent;* a per-child deadline rule.
- *A pattern-step v3 `start_child` action* (Q3 B).
- *A control that reaches a busy child* (see the limits).
- *Handing a Run resource to a child* (an RC-49 later form).

## Acceptance

1. Each rule at its edge: depth at `max_depth` and one over, with `max_depth` 1 and 8; a cycle through the root's ID, through a middle bot and back to the parent; a revoked root, a revoked middle bot, a revoked parent and a revoked `child_bot`; an `:agent` parent one epoch below the root (`:stale`), at the root's epoch and above it (granted); a scope and a space the parent does not hold, with the others held; budget 0, 1, the remaining amount and one over; a change with a `ref`, with `ref: nil` and with a 257-byte `ref` (each `:version_change`), and a change without the `ref` key (`:malformed`).
2. The order: each input with two faults gives the earlier reason (a revoked middle bot in a too-deep request is `:revoked`; a revoked middle bot under a stale parent is `:revoked`; a stale parent in a too-deep request is `:stale`; a cycle with an escalated scope is `:cycle`; an escalated scope over budget is `:escalation`).
3. An `:agent` parent's child is delegated from the root, `delegated_by` the root's ID, with scopes inside the agent's; a root (`:human` or `:service`) parent's child has an empty lineage plus the child; the grant's pin is the parent's without a change and the changed one with it.
4. The default rule: `parent_close: nil` gives `:request_cancel`.
5. `:malformed` for a parent agent delegated by another root, a parent of another tenant, a lineage that does not end with the parent, a non-empty lineage for a root parent, 9 lineage entries, a repeated lineage ID, `max_depth` 0 and 9, and a conflicting authority set.
6. `on_parent_close/1` for each rule, for a mixed list in order, for 0 and 256 entries, and `:malformed` for 257 entries and a repeated `child_run_id`; the cancel request payload written out by hand.
7. Negative controls, one at a time, each restored before the final gates: skip the lineage check (case 1's cycle through a middle bot fails); skip the revocation check of the lineage (the revoked-middle-bot case fails); delegate from the parent agent instead of the root (`domain/principal` refuses it `nested_delegation`, and case 3 fails); skip the epoch check (case 1's stale parent is granted).

Run the Piece tests and the new-Piece small gate locally (`mix check --piece "$(git merge-base origin/main HEAD)"`), the roadmap and claims checks and the diff check. The full independent review of the coordinator guide ("Reviewer by risk": it finds the code and a test for each rule above), the exact-head hosted check and the merge queue are required. Record in the pull request body the change in the time of the aggregate consumer of `test/export_test.exs` (#814, #819).

## Limits to state

Every fact is host-vouched: the root, the parent, the authority, the remaining budget, the lineage, the revocations and the pin; the Piece checks their shape and their consistency, not their truth. A grant is a decision, not a reservation: the engine's nested binding or the host reserves the budget. A `:request_cancel` reaches a child only when it is idle; a `:cancel` of an Attempt does not stop a sent Effect (the engine's unknown rules apply). One delegation level in `domain/principal`: every child agent is delegated from the root. No Run start, cancel, message, store or clock.
