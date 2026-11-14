# ELZ-213 — An approval request that the Run already holds is waited for, and an uncertain reply of the Run is no refusal

- Dependencies: ELZ-033, ELZ-192, ELZ-212
- Output: none. This task changes the ready Piece `assembly/run-engine` in place: what the engine does with each reply to an approval request becomes a stated part of its Contract. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row).

The automated review of pull request #266 found it, and the code
confirms a wider form. An action under an ASK rule asks the Run for an
approval request and then records the key of that request on its slot.
These are two commits in two stores. When the engine ends between
them, the Run holds an open request and the slot holds no key. After
the restart the engine asks again, the Run answers `duplicate`, and
the engine settles the action as refused with the reason
`approval_refused`. An action that a person could still approve is
lost, and the Run keeps a request that no slot waits for. The same
clause turns a `conflict` and an `unavailable` reply of the Run into
the same durable refusal.

Facts checked on `main` (lines of `lib/elzoo/run_engine.ex` at the time
of writing, and in brackets lines of
`pieces/workflow/run-approval-release/lib/elzoo/run_approval_release.ex`;
confirm each when you start, and if one differs, stop and ask):

- `progress/3` for a slot in `approval`, in a Run that is not terminal
  (about 1828 to 1835), sends `:approval_request` with the decision of
  the slot. Only `{:ok, _, request_key}` with a tuple key commits the
  continuation that holds the key (about 1829 to 1831). Every other
  reply writes `refused`, `approval_refused`, actual 0 (about 1833 to
  1834).
- `drain/1` selects a slot in `approval` with no key in every round
  (about 1566 to 1567). `release_waiting/3` takes only slots with a
  key (about line 2511).
- The Run answers `{:unchanged, :duplicate, revision}` when the
  request of that decision already belongs to the Attempt [about 227
  to 233]. The key of a request is `{run, action, name, version,
  revision}` (`pieces/workflow/approval/lib/elzoo/approval.ex`, about
  322 and 385), and a Run has at most one request per action that is
  not superseded. The status view lists `request_key` and `status`
  (`open`, `released`, `superseded`) of each request of the Run [about
  807 to 820].
- Other replies of the Run to this command: `{:refused, :conflict}`
  when the expected revision is not the current one or the lease is
  fenced [about 255 to 257 and 663 to 664]; `{:error, :unavailable}`
  from the store [about 672 to 673]; `{:indeterminate, _}` when the
  write is unknown, after which the Run owner stops [about 131 to 135
  and 666 to 667]; `{:refused, :intent_mismatch}` [about 232];
  `{:unchanged, :terminal, _}` and `{:unchanged, :stale, _}` [about
  216 to 225]; `{:error, {:invalid_input, _}}` for a decision that is
  no ASK decision.
- The same request sent again is safe: the Run derives the key from
  the decision and answers `ok` or `duplicate`, never a second
  request.
- The engine has no timer. A slot that makes no progress in a round
  ends the drain (the last branch, about 1617 to 1621), and the next
  drain selects it again.
- The README says that ASK Effects use the approval protocol of the
  Run and that recovery replaces no identity (about 245 to 253). It
  states no Limit for these replies. No test contains
  `approval_refused`.

## The changed Contract

After a reply to `:approval_request` that is not `{:ok, _, key}`, the
engine reads the status view of the Run once and decides in this
order:

1. **The Run holds the request.** The view lists a request of this
   Run for the action of the slot, with the name and version of the
   requirement of the slot's decision, that is not superseded. The
   engine commits the same continuation as after `ok`, with that key,
   and goes on as after `ok`. This covers the `duplicate` after a
   death, and a reply that was lost after the write.
2. **The Run did not decide.** The reply was `{:refused, :conflict}`,
   `{:error, :unavailable}` or `{:indeterminate, _}`, and the view
   lists no such request. The engine writes nothing. The slot stays
   in `approval` with no key, and the next drain asks again. The
   engine does not halt and does not ask again in the same round.
3. **The Run refused.** Every other reply settles the slot as today:
   `refused`, `approval_refused`, actual 0.

Why "stay and ask at the next drain" for point 2: the request is the
same on every try, so a second try cannot make a second request;
nothing was sent for the action; a durable refusal would be false; and
a halt would need a restart of the host for a state that the next
input repairs. The cost is stated as a Limit: while the Run gives such
a reply, each drain ends at this slot, so slots behind it in the order
of the drain wait for the next drain; and a slot whose Run never
answers stays open until its deadline or a change of Attempt.

What the engine process does when the Run owner is gone does not
change. No input, option, control command, public function, record
kind or durable field is added: the key is read from the Run.

The README states the three points beside the text on ASK Effects,
and the Limit. `piece.json` gets the Limit and the new groups in its
grounding claim. A Run recorded before this repair that already holds
the false refusal keeps it (Elzoo is not released; a Limit). The index
row follows in the last commit before the pull request is opened
(in-place change of a ready Piece, same Piece ID).

## Named acceptance groups

Nearest existing tests: `ordinary ASK waits durably, then genuine
consent dispatches once` (`test/elzoo/run_engine_test.exs`, about
1926), `ASK non-Effect ready recovery revalidates release after death
before dispatch` (about 1712), `ASK descriptor recovery checks engine
startup binding before first Run binding` (about 1775) and `a slot
waiting for approval with no request key is refused and its
reservation is released` (about 4868). Two seams of the test file
serve: the store hook `test_dispatch` with a kill, as in the test at
about 2091 to 2140, for a death after the Run commit; and a small
forwarding process in the test file, given as `run_owner`, that passes
every call to the Run owner and answers one `approval_request` with a
chosen reply.

1. **`request_survives_a_death`**: the engine dies after the Run
   committed the request and before the continuation. After the
   restart the slot is in `approval` and holds the key that the Run
   lists; no outcome record exists for the action; the Run holds one
   request. Then the consent control dispatches the action once and
   its result settles it `completed`.
2. **`lost_reply_is_recovered`**: the forwarding process passes the
   request to the Run and answers `{:error, :unavailable}`: the slot
   holds the key in the same input, with no restart.
3. **`uncertain_reply_is_no_refusal`**: the forwarding process
   answers `{:refused, :conflict}` and, in a second case,
   `{:error, :unavailable}`, without passing the request on: the call
   returns, the slot is in `approval` with no key, no outcome record
   exists and the reservation is held. The next input asks again, the
   Run answers `ok`, and the slot holds the key.
4. **`definite_refusal_still_refuses`**: a reply
   `{:refused, :intent_mismatch}` settles the slot `refused` with the
   reason `approval_refused`, actual 0, and releases its reservation.
5. **`replay_is_equal`**: a restart after group 1 and after group 3
   gives an equal view and an equal count of journal records, and the
   Run still holds one request.
6. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged.

## Evidence and gate

Negative controls, each by a temporary edit that is reverted: with the
old clause, group 1 fails (the slot is settled `refused` after the
restart) and group 3 fails (the slot is settled `refused`).

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state;
an action that may be approved must not be lost).

## Not in scope

A request of the Run that no slot waits for in a Run recorded before
this repair; a timer or a retry inside one round; the replies of
`release_approved` and `dispatch_approved`; the evidence rule and the
child deaths of `workflow/run-approval-release` (ELZ-206, which does
not change the rule for `approval_request`); and any other Piece.
