# ELZ-206 — Run refuses missing approval evidence and keeps a child death whose write failed

- Dependencies: ELZ-116, ELZ-126
- Output: none. A repair of the ready Pieces `workflow/run` and `workflow/run-approval-release` (a source copy of the first) that restores one result and states two Limits; both Piece IDs stay.
- Change class: Piece-only implementation, in place on two ready Pieces; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/workflow/run/**` and `pieces/workflow/run-approval-release/**` only, and their index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of each of the two rows, because both `piece.json` files change).

The automated review of pull request #246 left three findings on
`workflow/run`. `workflow/run-approval-release` is a source copy that
`assembly/run-engine` uses, and it has the first two in the same lines.
This task repairs both Pieces in the same way, each with its own test.

Facts checked on `main` (lines of `pieces/workflow/run/lib/elzoo/run.ex`
at the time of writing, and in brackets the lines of
`pieces/workflow/run-approval-release/lib/elzoo/run_approval_release.ex`;
confirm each when you start, and if one differs, stop and ask):

- **Evidence.** `validate/1` (about 137 to 148) checks only the set of
  keys of a command, so `evidence: nil` passes. `classify_command/3`
  (about 236 to 238 [237 to 239]) answers `{:unchanged, :duplicate}` when
  `run.evidence[c.request_key] == c.evidence`. For a request key with no
  stored evidence and `evidence: nil` that is `nil == nil`. The same
  holds for a request key that does not exist. `perform/3` (about 332 to
  337) and `store_evidence/3` (about 390 to 399), which would answer
  `{:refused, :unknown_request}` or `{:refused, :invalid_evidence}`, are
  not reached. Stored evidence is always a map (`valid_evidence?/2`,
  about line 825).
- **Child death.** `attach_child` keeps the monitor in the process state
  only (about 283 to 287); the README says that no pid is stored. The
  `DOWN` handler (about 755 to 767 [783 to 797]) takes the monitor out
  of the state and then calls `persist/3` with `{:child_dead, ...}`.
  `persist/3` (about 626 to 645) returns the state unchanged for
  `{:fenced, _}`, `{:rejected, _}` and `{:error, _}`. Only
  `:indeterminate` stops the owner. So after a failed write the death is
  in no record and in no state, and no second `DOWN` comes.
- After a restart of the owner every monitor is gone, so a death during
  or after a restart is never recorded. No Limit states that.
- Each write moves the revision of the stream, and a command is refused
  with `conflict` when its `expected_revision` is not the current one
  (`at_revision/3`, about 254 to 256). A recorded death moves the
  revision today as well.
- In the repository only `status` reads `dead`; `assembly/run-engine`
  does not (searched).
- **Correlation.** `dispatch_approved` checks that the request belongs
  to this Run and Attempt, that the intent matches the named binding,
  and that a second call does not change the intent of the action
  (about 339 to 348). It compares nothing of the intent with the
  approved action. The Contract takes trusted commands: the README says
  that the host supplies "canonical arguments" (Needs, about 148 to 152)
  and that untrusted payloads must not be used as commands (about 161 to
  162), and `piece.json` says the same in its assumption (about line
  28). The README of `workflow/run` does not say in so many words that
  the correlation of the intent with the approved action is a host Need.
  The README of the copy does (about 112 and 124), and its `piece.json`
  (about lines 15 and 29).
- Both test helpers have a Store fault seam (`fault/5`:
  `test/support/run_test_helper.exs`, about line 339;
  `test/support/run_approval_release_test_helper.exs`, about line 360).

## The repair

1. **Evidence.** The duplicate answer of `approval_evidence` needs
   stored evidence for the request key: the clause also requires that
   the key is in `run.evidence`. A command with missing evidence, or
   with a request key that has none stored, then goes on to `perform/3`
   and gets the existing refusals, `unknown_request` or
   `invalid_evidence`. A true duplicate (equal stored evidence) keeps
   `{:unchanged, :duplicate, revision}`.
2. **Child death.** When the write of a child death returns
   `{:error, _}`, the owner keeps that death in its process state. With
   the next command, whatever its result, it writes each kept death,
   after the command itself was carried out, so that the kept death does
   not turn that command into a `conflict`. A death that is written
   leaves the kept list; one whose write fails again stays.
   `:indeterminate` stops the owner as today. `{:fenced, _}` and
   `{:rejected, _}` drop the death as today. This needs no durable field
   and no timer: the kept list is process state, bounded by the
   monitors. `status` triggers nothing.
3. **Limits and Needs.** State in both READMEs and in `limits` of both
   `piece.json` files: `dead` is best effort; a death is not recorded
   when the owner restarts before or while the child ends (no pid is
   stored), or when its write is fenced or rejected; a death whose write
   failed with an error is written with the next command. State in the
   Needs of the README of `workflow/run`, and in the assumption of its
   `piece.json`: the host correlates the intent of `dispatch_approved`
   with the approved action; Run checks the request, the binding and
   that the intent of an action does not change, and nothing else. The
   copy states this already; change it only if a word is wrong.

Both Pieces must stay equal in behaviour for these two commands: the
same edit in both modules, and each Piece has its own tests. Add no
command, no record kind, no option and no timer. The `contract`
sentences are unchanged. Both `piece.json` files change, so the
`manifest_sha256` of both index rows follows in the last commit before
the pull request is opened (in-place change of ready Pieces, same Piece
IDs; Elzoo is not released).

## Named acceptance groups

Each group exists once in the tests of each of the two Pieces.

1. **`missing_evidence_is_refused`**: with an open request and the
   current revision, `approval_evidence` with `evidence: nil` is
   `{:refused, :invalid_evidence}`; with a request key that does not
   exist it is `{:refused, :unknown_request}`; nothing is written. The
   same valid evidence sent twice is `{:ok, ...}` and then
   `{:unchanged, :duplicate, revision}`.
2. **`failed_death_write_is_kept`**: a live child is attached; the
   fault seam makes the next write `unavailable`; the child ends; the
   fault is cleared; `status` still shows `dead: false`; one command is
   sent and gets its ordinary result; then `status` shows `dead: true`.
   A second failure keeps the death for the command after it.
3. **`death_is_best_effort`**: after a restart of the owner, a child
   that ends leaves `dead: false` (the stated Limit).
4. **`existing_behaviour`**: every existing test of both Pieces passes
   unchanged.

Negative controls, each by a temporary edit that is reverted, in each
Piece: without the new condition, the first case of group 1 gives
`{:unchanged, :duplicate, _}`; without the kept list, group 2 ends with
`dead: false`. Record the four failures.

Run `mix test pieces/workflow/run/test` and
`mix test pieces/workflow/run-approval-release/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. The small gate also runs the ready Pieces that
depend on these two (`assembly/run-engine` among them). One independent
review, risk normal (durable lifecycle state).

## Not in scope

A check of the tenant or of the arguments of an intent against the
approved action (a Contract decision of its own), a stored pid or a
timer for child deaths, the approval recovery of `assembly/run-engine`,
and any other Piece.
