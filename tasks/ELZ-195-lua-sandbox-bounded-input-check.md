# ELZ-195 — The size check of the Lua sandbox input is bounded by `value_bytes` while it walks the term

- Dependencies: ELZ-163, ELZ-177, ELZ-188
- Output: none. A repair of the ready Piece `runtime/lua-sandbox` with one new stated Limit and one corrected sentence; the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/runtime/lua-sandbox/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row, because `piece.json` changes). No change of `lib/elzoo/lua_sandbox/native/lua_sandbox_host.c`.

Four findings of the automated reviews of pull requests #376, #405 and
#429 are open on this Piece. One is a bound that is checked too late, one
is a bound that the host does not hold for a few short names, one is a
README sentence that says more than the host does, and one is a test fake
that can lose a race.

Facts checked on `main` (confirm each when you start, and if one differs,
stop and ask):

- `Elzoo.LuaSandbox.run/2` (`lib/elzoo/lua_sandbox.ex`, about 191 to
  205) takes the start time, then runs `validate/1` to its end, and only
  then calls `Child.exchange/3`, the one place that holds the deadline.
- `Json.check/2` (`lib/elzoo/lua_sandbox/json.ex`, about 107 to 113)
  walks the whole term with `walk/4` (about 116 to 158), which carries no
  count of bytes. When no single string is over `value_bytes` it then
  builds the whole canonical encoding with `encode/1` and compares its
  size. A term that shares subterms (a list that holds the same list
  twice, 30 levels deep) is small in memory, but both steps visit each
  shared part once for each reference. The depth bound of 32 containers
  does not stop that. A term from a JSON decoder shares nothing, so for
  decoded input the cost is linear.
- Today the walk goes to the end before it answers, so a term that is
  both over the size and not plain data gives `invalid_request`.
- The recorded `arguments` and `result` of `calls` go through the same
  `Json.check/2`.
- In the C host the string guard is in the allocator (about 645 to 651)
  and holds only while `G.armed` is set (about line 2291, after the state
  and the bindings are made). A source literal that is equal to a short
  string that the state interned before that makes no new string, so the
  guard does not see it. This is read from the code, not observed.
- `check_calls` of the C host (about 2007 to 2041) checks the shape, the
  names, the counts and the depth of `calls`. It does not measure the
  encoded size of a recorded value. The README (about 203 to 205) says of
  that size: "This is decided before a process starts and again by the
  host before the Lua state exists". The sentence is not in `piece.json`.
- The fake `stderr-exit-0` of the group `caller_is_unchanged`
  (`test/elzoo/lua_sandbox_protocol_test.exs`, about line 622) writes to
  stderr and exits without reading its input, and the test expects
  `protocol_error`. `Child.await/4` (`lib/elzoo/lua_sandbox/child.ex`,
  about 112 to 117) gives `process_exit` when the Port ends with no report
  and an empty buffer, which happens when the request is written to a
  child that has already ended. The fakes `stderr-only`, `stderr-crash`
  and `stdout-text` (same file, about 438 to 445) and `stderr text`
  (`test/elzoo/lua_sandbox_replay_test.exs`, about line 753) have the same
  form.

## The repair

1. **Bounded check (finding of #376).** `Json.check/2` carries a budget
   of `value_bytes` through the walk. Each node takes from it an amount
   that is at most its size in the canonical encoding (for example the
   bytes of a string and its two quotes, one byte for a number or a
   literal, two bytes for a container). When the budget is used up the
   walk stops at once with `:size`. `encode/1` runs only on a term that
   the walk passed, and the exact comparison with `value_bytes` stays, so
   the result for a term that fits is the same as today, to the byte.
   The work of the check is then bounded by `value_bytes` and no longer
   by the count of references. Read no clock for it.
   One answer changes and the README states it: for a term that is both
   over `value_bytes` and not plain data, the answer is the one that the
   walk meets first, so it can be `value_size` where it was
   `invalid_request`. Both are refusals before a process starts.
2. **Interned names (finding of #376).** The smallest honest repair is a
   stated Limit, not a check at load: the C host stays byte for byte as
   it is, so no build identity and no recorded reply changes. State in
   the README Limits and in `limits` of `piece.json`: a string that is
   equal to a short name that the Lua state already holds when the limits
   are armed (names of the libraries and of metamethods, reserved words)
   can exist although it is longer than `value_bytes`; this matters only
   for a `value_bytes` below the length of such a name; the encoded result
   and each helper argument keep their own check. One test shows the
   stated case (group 3).
3. **README sentence (finding of #405).** Replace "This is decided before
   a process starts and again by the host before the Lua state exists"
   with a sentence that says: the size is decided before a process
   starts; before the Lua state exists the host checks the shape, the
   names, the counts and the depth of `calls` and does not measure the
   size of a recorded value again; a single string over `value_bytes` in a
   record is still stopped by the allocator when the record is pushed.
4. **Test fake (finding of #429).** Each fake named above reads the
   request from its input (at least the four bytes of the frame header)
   before it writes text and exits. The expected results stay as they
   are. No file of `lib/` changes for this part.

Add no option, no public function, no process and no reason. The policy
version, the frame format and the limits stay.

The changed Contract text: the new Limit of step 2, the sentence of step
1 on the order of the two refusals, and the corrected sentence of step 3
(README only). `piece.json` changes (the Limit, and the test claims that
name the groups), so the `manifest_sha256` of the index row follows in
the last commit before the pull request is opened (in-place change of a
ready Piece, same Piece ID; Elzoo is not released). The `contract`
sentence is unchanged.

## Named acceptance groups

1. **`input_check_is_bounded`**: an input built from one short string by
   doubling a list 22 times (about four million leaves, a few hundred
   bytes of memory), with `value_bytes` 4 and with 65,536, gives
   `{:refused, :value_size}`, no process starts (as the group
   `request_shape` shows it today), and the call uses fewer reductions of
   the calling process than a fixed count that you state
   (`Process.info(self(), :reductions)` before and after; no wall time).
   The same term as a recorded `arguments` and as a recorded `result`
   gives `value_size`.
2. **`size_answers_are_exact`**: an input whose canonical encoding is
   exactly `value_bytes` passes and one byte more is `value_size`, for a
   string, a list of numbers, a map and a nested term; a term over the
   size that also holds a value that is not plain data gives one of the
   two refusals and the test names which one for each of two orders.
3. **`interned_name_limit`**: with `value_bytes` 4 the source
   `return function() return #'string' end` gives the value 6, and a
   literal of the same length that is not such a name gives
   `value_size`. If the first result is not 6, stop and report: then the
   Limit is worded wrongly.
4. **`stderr_fakes_read_first`**: the changed fakes give
   `protocol_error` in 200 runs each. Record the count.
5. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged, apart from the bodies of the fakes of step 4.

Negative controls, each by a temporary edit that is reverted: with the
budget removed from the walk, group 1 passes its reduction count and
fails (choose the depth so that the unrepaired code fails without using
up the memory of the host; record the depth); with the read removed from
one fake, the test still passes in most runs, which is why this control
is recorded as "not decisive" and the review reads the fake instead.

Run `mix test pieces/runtime/lua-sandbox/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. The copied consumer of the Piece stays inside its
existing 300 s (if not, stop and report the measured time). One
independent review, risk high (bound on untrusted input, native child
process).

## Not in scope

The C host and its comments, a check of literal lengths at load, the
deadline of the child exchange, the policy and its version,
`runtime/lua-binding`, `workflow/lua-tool`, and any other Piece.
