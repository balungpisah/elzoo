# ELZ-186 — The resolved bindings of `runtime/lua-binding` are plain data

- Dependencies: ELZ-033, ELZ-178
- Output: none. A repair of the ready Piece `runtime/lua-binding` that restores its Contract; the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/runtime/lua-binding/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row when `piece.json` changes).

The Contract of `runtime/lua-binding` (ELZ-178) says that the value of
`resolve/2` is "opaque plain data", and its README says "A pattern can keep
it in its state". That is not true on `main`. Found by the worker of ELZ-179
(issue #398), who needs to keep the value in the state of a pattern step.

Facts checked on main:

- `Elzoo.LuaBinding.resolve/2` gives `{:LuaBinding, entries}`. Each entry is
  `%{manifest: manifest, arguments: checked, result: checked}`, where
  `checked` is the value of `Elzoo.PayloadSchema.build/2`
  (`lib/elzoo/lua_binding.ex`, `checked/1` and `operand/2`).
- A built schema of `core/payload-schema` is a tuple that holds a struct of
  the JSON Schema library. So the bindings hold structs.
- `check_arguments/3` and `check_result/3` read the built schema of the
  entry and give it to `PayloadSchema.check/3`.
- `assembly/run-engine` installs the state of a callable only when it is
  plain data: atoms, numbers, binaries, lists, tuples and maps that are not
  structs, all the way down (`plain?/1` in `lib/elzoo/run_engine.ex`), and
  at most 65,536 bytes as
  `:erlang.term_to_binary(state, [:deterministic, {:minor_version, 2}])`.
  With one function the bindings are about 2,500 bytes in that form, and
  `plain?/1` is false.
- No test of the Piece asserts that the bindings are plain.

## Change

`resolve/2` still builds both schemas of each declared manifest, to decide
`:invalid_manifest`, exactly as today. It keeps only the manifest in the
entry: no built schema. `check_arguments/3` and `check_result/3` build the
schema of that side from the kept manifest when they are called, and then
check as today. A build that fails there cannot happen for a value that
`resolve/2` made; for a value from elsewhere the result stays outside the
Contract.

Nothing else changes: no function, argument, return form, reason, bound,
identity or source. `identity/1` gives the same text as before for the same
resolved manifests.

Update the README sentence on the bindings so that it states what is kept
(the resolved manifests) and that each check builds its schema; state the
cost in Limits: one schema build for each checked call.

## Acceptance

1. **`bindings_are_plain`**: for a declaration of three functions the value
   of `resolve/2` is plain by the rule above (write the rule as a small
   function in the test: no struct anywhere in the term), and its
   `term_to_binary` form in the measure above is smaller than the same form
   of the three manifests plus 1,024 bytes.
2. **`same_results`**: every existing test of the Piece passes without a
   change of an assertion; `identity/1` of the test declarations is equal to
   its value before this change (record the value in the pull request body
   from a run on the base, and assert it as a literal).
3. **`checks_still_check`**: `check_arguments/3` and `check_result/3` give
   the same refusals as before for the cases of the existing groups, also
   when they are called 1,000 times on one bindings value.
4. A negative control: temporarily keep one built schema in the entry;
   group 1 must fail; revert it.
5. The local gate: `mix test pieces/runtime/lua-binding/test`, then
   `mix check --piece "$(git merge-base origin/main HEAD)"` and
   `git diff --check`. One independent review.

## Not in scope

A cache of built schemas, a change of `core/payload-schema`, `workflow/lua-tool`
and any other Piece.
