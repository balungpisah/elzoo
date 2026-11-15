# ELZ-239 — The skill Piece names where each RC-67 sentence that rests on another Piece is shown

- Dependencies: ELZ-033, ELZ-182, ELZ-235, ELZ-237, ELZ-238
- Output: none. Text only, in place, in the ready Piece `workflow/skill`, with the same Piece ID. The Contract does not change: the `contract` of `piece.json` stays byte for byte. No code and no test changes.
- Change class: Piece-only implementation (Piece directory and index rows only); small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/workflow/skill/README.md` and `pieces/workflow/skill/piece.json` only, and the index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of the row of `workflow/skill` in `entries`; the `note` stays, because the `contract` stays). No other file.

The README and `piece.json` of `workflow/skill` say that four sentences of
RC-67 are "met in part". Since ELZ-237 and ELZ-238 merged, each of the four
is shown, in this Piece or in the Piece that owns it. The text is now stale,
and one part of it is false: it says that the restart case is "not with the
harness of RC-66", but the harness now shows it. This task makes the text
say what is shown and where. It builds nothing.

Facts checked on `main` (at the time of writing, at `1d57233`, before
ELZ-238). They were read, not run. Lines are "about". Confirm each fact
when you start, and if one differs, stop and ask.

- `pieces/workflow/skill/README.md` about 253 to 260: "Four sentences of
  RC-67 are met in part: …, not with the harness of RC-66."
- `pieces/workflow/skill/piece.json` `limits` entries about 16 and 17: the
  same four "met in part" sentences; entry 17 ends "not with the harness".
- `lib/elzoo/registry.ex` about 214 to 223: a `test`, `proof`, `type` or
  `monitor` grounding must name a file of this Piece's own `files`
  ("evidence outside bundle"). So this Piece cannot name a test file of
  another Piece in its grounding. It names the other Piece and its group in
  the prose of `limits` and of the README, as it already names
  `workflow/agent-loop` and `workflow/version-pin` there.
- Restart, with the harness: `pieces/runtime/recipe-test/test/elzoo/recipe_test_test.exs`
  about 985 to 1023 (`skill_load_after_restart`): with `restart_after: 3`
  the record shows `restarted: true`, one load action and one load outcome,
  `asked` holds the load once, the dropped skill tool call is `unknown`, and
  the model call after the restart holds the instructions and the skill tool.
  `pieces/runtime/recipe-test/README.md` about 168 to 175 says the same.
- Refusal at use: the group `declared_tool_denied_by_gate` of
  `runtime/recipe-test` (ELZ-238): the engine gate refuses the declared
  tool for the principal, the tool never reaches the Adapter, and the
  instructions stay. Confirm the group name and what it shows at your base.
- Scripts: `test/elzoo/skill_test.exs` about 1477 to 1507
  (`scripts_never_run`): `read/4` and `read_file/3` give the script bytes
  unchanged, no sentinel file and no `persistent_term` is written. README
  about 234 and the `assumption` grounding of `piece.json` about 35 already
  declare "stores the skill files" as a host Need.
- Version: `test/elzoo/skill_test.exs` about 2076 to 2106
  (`pinned_version_answers`). `pieces/workflow/version-pin/piece.json`: the
  proof `publish_keeps_version` and the test group
  `publish_changes_no_running_run`. No Piece of the catalogue calls
  `Elzoo.VersionPin` (search `pieces/` for `VersionPin`): the pin of a Run is
  a host Need.

## Task

1. Confirm the facts above at your base.
2. Replace the README text about 253 to 260 ("Four sentences of RC-67 are met
   in part: … not with the harness of RC-66.") with text of this sense, in
   the style of the README:

   > Four sentences of RC-67 rest on other Pieces or on the host. The refusal
   > of a declared tool that the principal may not use is at use, in the
   > engine: here the instructions load whatever the declared tools are
   > (`agent_loop_accepts`), and the group `declared_tool_denied_by_gate` of
   > `runtime/recipe-test` shows the engine gate refusing such a tool while
   > the instructions stay. Scripts are read and never executed here
   > (`scripts_never_run`); this Piece stores nothing, and storing the files
   > is a host Need. A changed version does not change a running Run because
   > the host pins the package of the Run: that is the rule of
   > `workflow/version-pin` (its law `publish_keeps_version`), and here
   > `pinned_version_answers` shows that a load and a file read given one
   > package answer from it after another version exists. With the harness of
   > RC-66, a load survives a restart and is not asked again: the group
   > `skill_load_after_restart` of `runtime/recipe-test`.

3. Replace the `limits` entries about 16 and 17 of `piece.json` with the same
   claims in one or two entries. Drop "met in part" and "not with the
   harness". Keep "this Piece reads and never executes; storing is a host
   Need" and "the host's pin".
4. Change nothing else. The `contract`, the grounding entries and the
   evidence section stay.

## Acceptance

1. `grep -n "met in part\|not with the harness" pieces/workflow/skill/README.md pieces/workflow/skill/piece.json`
   finds nothing.
2. Each of the four sentences names where it is shown: a group of this Piece,
   or a named Piece and its group or law. Each named group exists at the base
   (`grep -n 'describe "<name>"'` in the named test file).
3. The text claims no store, no policy of the context and no executed check
   that is not in a named group.
4. `existing_behaviour`: `mix test pieces/workflow/skill/test` passes
   unchanged.

No negative control: no code or test changes. The reviewer checks each
pointer against the named test.

## Evidence and gate

`mix check --piece "$(git merge-base origin/main HEAD)"` (it runs the tests
of this Piece and of `runtime/recipe-test`, which depends on it, so it needs
a disposable PostgreSQL through `ELZOO_TEST_DATABASE_URL`) and
`git diff --check "$(git merge-base origin/main HEAD)"`. The index row
(`manifest_sha256` only) follows in the last commit (AGENTS.md section 3).

## Review risk

Low. One independent review; a different session is enough. The reviewer
checks each pointer against the named test or law, and that the text claims
nothing more than they show.

## Not in scope

- Any code or test change.
- A store of skill files, or a tie between the files and the package
  identity.
- A composition test of `Elzoo.VersionPin` with `Elzoo.Skill`.
- The published job row of ELZ-182 in `docs/plans/release-plan.json` ("A load
  lists no tool"): it is the record of that task.
