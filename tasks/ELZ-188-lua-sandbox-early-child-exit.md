# ELZ-188 — A child of the Lua sandbox that dies early gives a host outcome and never ends its caller

- Dependencies: ELZ-033, ELZ-177
- Output: none. A repair of the ready Piece `runtime/lua-sandbox` that restores its Contract; the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/runtime/lua-sandbox/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row when `piece.json` changes).

Issue #418 records the failure. In a hosted full check the test `private
text on stderr is in no return value and no log`
(`pieces/runtime/lua-sandbox/test/elzoo/lua_sandbox_protocol_test.exs`)
ended with

    ** (EXIT from #PID<...>) :epipe

The test starts fake children that write to stderr and exit at once, and it
expects `{:host_outcome, :protocol_error}` from each. One of the four
exchanges ended the test process.

Facts checked on `main` (confirm each when you start; if one differs, stop
and ask):

- `Elzoo.LuaSandbox.Child.exchange/3`
  (`lib/elzoo/lua_sandbox/child.ex`) opens the Port in the calling process
  with `Port.open({:spawn_executable, ...}, [:binary, :exit_status,
  :stderr_to_stdout, ...])`. A Port is linked to the process that opens it.
- It then writes the request with `send(port, {self(), {:command,
  frame}})`. When the child has already exited or has closed its input, the
  write fails in the Port with `epipe`, the Port exits with the reason
  `:epipe`, and the link sends that exit to the caller. The caller does not
  trap exits, so it ends. No `rescue` can catch an exit signal.
- The README of the Piece says that the owning process stays alive on every
  adverse case and that a child that exits is a host outcome
  (`process_exit` or `protocol_error`).

So this is a defect of the Piece and not only of a test: a child that exits
before it reads its request (a broken executable, a kill from outside, a
crash at start) can end the process that called `run/2`. The window is
short, which is why the tests pass almost always.

## Task

1. **Show it first.** Add a test that makes the case certain and not a
   race: a fake child that closes its input or exits before the request is
   written, with a request frame that is large enough that the write cannot
   complete into the pipe buffer (use the largest frame that the Piece
   accepts), repeated enough times that the unrepaired code ends the test
   process in each run of the test. Record that failure on the unrepaired
   code in the pull request body.
2. **Repair.** No exit of the Port may reach the caller of `run/2` as an
   exit signal. Every such case returns `{:host_outcome, reason}` with an
   existing reason: `process_exit`, or `protocol_error` when bytes that are
   not one reply frame were read, by the rules that `exited/3` has today.
   The caller's process flags must be the same after `run/2` as before it:
   do not set `trap_exit` in the caller. Every guarantee that the Piece
   states today stays: the absolute deadline held on the caller's side, the
   child killed by OS pid and reaped on every return path, no live child
   after the death of the caller, exactly one reply frame, no message of the
   Port left in the caller's mailbox, and no process of the Piece left alive
   after `run/2` returns. The mechanism is your choice inside these rules
   (for example a short-lived process that owns the Port, is not linked to
   the caller in a way that can end it, and ends when the caller ends). Add
   no pool, no long-lived process, no option and no new public function.
3. Update the README and `piece.json` only where they describe the Port
   owner, so that they state what is true after the repair. No reason, no
   return form, no bound and no identity changes; the policy version stays.

## Acceptance

- `early_exit_is_a_host_outcome`: the test of step 1 gives a host outcome in
  each of 200 exchanges and the test process stays alive; the same for a
  child that is killed from outside while the request is written.
- `caller_is_unchanged`: after each adverse exchange the caller has no
  message of the Piece in its mailbox, the same `trap_exit` flag, no new
  link and no new monitor (`Process.info/2`), and a next valid `run/2`
  succeeds.
- `no_orphan`: a caller that is killed during an exchange leaves no child
  and no process of the Piece (the existing test of caller death passes,
  and one case is added in which the caller is killed while the request is
  written).
- Every existing test of the Piece passes unchanged; the deadline tests
  give `wall_time` within their existing bounds.
- Negative control: restore the direct link by a temporary edit; the test
  of step 1 must end the test process. Revert it.
- The small gate exits 0; the copied consumer of the Piece stays inside its
  existing 300 s (if not, stop and report the measured time).
- The pull request closes this task and issue #418.
- One independent review, risk high (native child process, untrusted
  input).

## Not in scope

The C host, the policy, the frame format, limits, `runtime/lua-binding`,
`workflow/lua-tool`, and any other Piece.
