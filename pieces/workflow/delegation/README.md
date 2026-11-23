# workflow/delegation

`Elzoo.Delegation` decides what a child Run gets when a bot's callable asks for
one. It has two pure functions and no I/O, clock, process or store. It starts,
cancels and messages no Run.

- `grant(facts, request)` returns `{:ok, grant}` or `{:error, reason}`. It
  decides the child's principal, the authority it is bounded by, its budget
  share, depth and lineage, the pinned recipe version and the parent-close
  rule, or it refuses the whole request.
- `on_parent_close(children)` returns, for the open children of a parent that
  ended, what the host does to each one.

A child Run starts through a `tool_call` whose host binding records the work
item, pins the version and starts the child. The host does that, not this
Piece. The Piece absorbs the delegation part of the handle `workflow/loop-guard`
(depth and cycles).

## `grant/2`

`facts` are trusted parent facts, exactly
`%{root, parent, authority, budget_remaining, max_depth, lineage, revoked_ids, pin}`:

- `root`: the `:human` or `:service` `Elzoo.Principal` at the top of the lineage.
- `parent`: the principal of the callable that asks. It is `root` itself, or an
  `:agent` whose `delegated_by` is the root's ID and whose tenant is the root's.
- `authority`: the parent's current effective authority, an authority set
  (writes) for `domain/authorization`.
- `budget_remaining`: a non-negative integer.
- `max_depth`: the host's declared bound, 1..8, with no default.
- `lineage`: the ordered list of 0..8 distinct bot IDs from the root Run to
  the parent. It is empty exactly when `parent` is `root`, and otherwise ends
  with the parent's ID.
- `revoked_ids`: the host's current revocation facts, 0..1,024 IDs.
- `pin`: the parent's pinned identity, 1..128 bytes.

`request` is exactly `%{child_bot, scopes, spaces, budget, parent_close, change}`:
`child_bot` an ID; `scopes` and `spaces` label lists as `domain/principal`
takes them; `budget` an integer; `parent_close` `:abandon`, `:request_cancel`,
`:cancel` or `nil` (the default, `:request_cancel`); `change` `nil` or
`%{pin, ref}`.

IDs, scopes and spaces follow the `domain/principal` text rule: 1..128 bytes of
valid UTF-8 without a C0 or C1 control character. Label lists hold 0..256
labels.

The grant is exactly
`%{principal, parent_authority, budget, depth, lineage, pin, change_ref, parent_close}`:

- `principal`: `Elzoo.Principal.delegate(root, %{id: child_bot, allowed_scopes:
  scopes, allowed_spaces: spaces})`. It is always delegated from the root, so
  `delegated_by` is the root's ID, even for the child of an agent.
- `parent_authority`: the `authority`, validated and normalized by
  `Elzoo.Authorization.validate_authority/1`. The host gives it as `parent` in
  the child's `domain/authorization` context. `decide/3` then refuses any
  proposal that is not inside both the child's own authority and this one, so
  the child never holds more than its parent.
- `budget`: the reserved share.
- `depth`: the length of the lineage plus 1.
- `lineage`: the lineage with `child_bot` appended.
- `pin`: the parent's `pin`, or `change.pin` when `change` is set.
- `change_ref`: `nil` or `change.ref`.
- `parent_close`: the rule, with the default filled in.

### Rules, in this fixed order

The first failure is returned, and a refusal refuses the whole request.

1. `:malformed`: any shape or bound above is not met. This includes the
   following cases:
   - `root` is not a valid `:human` or `:service` principal (revalidated with
     `Principal.check(principal, %{current_epoch: 0, revoked_ids: []})`).
   - `parent` is neither `root` nor an `:agent` delegated by `root` in its
     tenant.
   - The lineage is not empty exactly for a root parent, or does not end with
     the parent's ID.
   - `validate_authority/1` refuses the `authority`.
   - `change` is not a map of exactly `pin` and `ref`, or its `pin` is not
     1..128 bytes.
2. `:revoked`: the root, the parent, `child_bot` or any bot of the lineage is
   in `revoked_ids`. The child's `delegated_by` names the root only, so the
   lineage is where a revoked middle bot is seen.
3. `:stale`: `parent` is an `:agent` whose `auth_epoch` is below the root's
   `auth_epoch`. The child copies the root's epoch, so without this rule a
   parent left behind by a revocation by epoch of the root would mint a child
   with the newer epoch. A root parent has no epoch to compare.
4. `:depth`: the length of the lineage plus 1 is over `max_depth`.
5. `:cycle`: `child_bot` is the root's ID or is already in the lineage. Because
   of this rule, `domain/principal`'s `:self_delegation` is never reached.
6. `:escalation`: a requested scope or space is not held by the parent. The
   parent's own `allowed_scopes` and `allowed_spaces` decide this (the root's
   own for a root parent), by exact bytes.
7. `:budget`: `budget` is not a positive integer of at most `budget_remaining`.
8. `:version_change`: `change` is not `nil`, and its `ref` is `nil` or is not
   1..256 bytes of valid UTF-8 without a C0 or C1 control character. The `ref`
   is a reference of the host's authorised, recorded action. The Piece checks
   only that it is there.
9. `Principal.delegate/2` from the root. A refusal is
   `{:error, {:principal, reason}}` with its reason unchanged. After rules 1–8
   only `:escalation` stays reachable. That happens when the host-vouched agent
   parent holds a label that the given root no longer holds. Rule 1 has
   already validated the root, the IDs and the labels, so the other reasons of
   `domain/principal` cannot occur.

Errors are the fixed atoms `:malformed`, `:revoked`, `:stale`, `:depth`,
`:cycle`, `:escalation`, `:budget` and `:version_change`, or
`{:principal, atom}` with an unchanged reason of `domain/principal` (rule 9).
None echoes an ID, scope or space.

## `on_parent_close/1`

`on_parent_close/1` takes the open children of an ended parent: a list of
0..256 entries `%{child_run_id, parent_close}` with distinct `child_run_id`s
(the `workflow/run` ID rule: 1..200 bytes of valid UTF-8 without NUL). Each
`parent_close` is one of the three rules. It returns `{:ok, actions}`, one
entry per child in the same order, or `{:error, :malformed}`.

- `%{child_run_id, action: :abandon}`: the child goes on, and its later result
  is given to no one.
- `%{child_run_id, action: :request_cancel, message: payload}`: the host
  delivers one cancel request to the child when the child Run is idle, for
  example through the child's own one-link `delivery/durable-mailbox` chain.
  `payload` is the `elzoo.delegation.cancel_requested` version 1 map
  `%{"child_run_id" => id, "reason" => "parent_closed"}`. The child's pattern
  decides what to do. A request to a child that never idles stays pending until
  the child ends.
- `%{child_run_id, action: :cancel}`: the host cancels the child's current
  Attempt through `workflow/run`, which settles its open actions by the
  engine's rules.

### When a parent has ended

The parent is the callable whose `tool_call` started the child (in a room, a
bot's turn). A child's parent has ended when the child-start `tool_call` slot
settles without the child's result: at its deadline, at a change of Attempt or
at the end of the Run. A callable does not close because its actions settle,
so the slot is the trigger. A room rolls over only with nothing open, so a
rollover never ends the parent of a child whose slot is still open.

The default rule is `:request_cancel`, and it reaches a child only when the
child is idle. A busy agent-loop child has an action open from its start to its
finish, so it sees no cancel request before it ends.

## Grounding

Plain Elixir. No Cure law: the subset rule of the delegated scopes and spaces
is the selected Cure law of `domain/principal`, which `grant/2` reaches through
`Principal.delegate/2`. The decisions of this Piece (rule order, depth, cycle,
revocation, the epoch rule, the lineage checks and the parent-close mapping)
are grounded by finite tests only. `mix test pieces/workflow/delegation/test`
runs the listed scenarios:

- each rule at its edge, including an agent parent below, at and above the
  root's epoch;
- the rule order;
- the grant from an agent or root parent;
- an exhaustive 16×16 table of requested scope and space subsets against an
  agent parent;
- a child `domain/authorization` decision that refuses a write outside
  `parent_authority`;
- the reachable `domain/principal` reason;
- the default rule;
- malformed facts and requests;
- errors that echo no sentinel;
- `on_parent_close/1` for each rule, a mixed list, 0, 256 and 257 entries and
  a repeated ID.

Four negative controls make these tests fail:

- skipping the lineage check of rule 5;
- skipping the lineage check of rule 2;
- skipping rule 3, so that a stale parent is granted;
- delegating from the parent instead of the root, which `domain/principal`
  refuses `:nested_delegation`.

## Limits

- Every fact is host-vouched: the root, the parent, the authority, the
  remaining budget, the lineage, the revocations and the pin. The Piece checks
  their shape and their consistency, not their truth.
- A grant is a decision, not a reservation. The engine's nested binding or the
  host reserves the budget.
- A `:request_cancel` reaches a child only when it is idle. A `:cancel` of an
  Attempt does not stop a sent Effect (the engine's unknown rules apply).
- `domain/principal` has one delegation level, so every child agent is
  delegated from the root.
- No Run start, cancel, message, store or clock.
- Kept open, each addable in place before the first release:
  - multi-level delegation in `domain/principal`;
  - an `allowed_patterns` key of the grant;
  - a fan-out bound per parent;
  - a per-child deadline rule;
  - a pattern-step v3 `start_child` action;
  - a control that reaches a busy child;
  - handing a Run resource to a child.
