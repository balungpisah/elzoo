# ELZ-235 — A loaded skill lists the tools that its pinned package declares, with descriptors that the host gives

- Dependencies: ELZ-033, ELZ-182, ELZ-194, ELZ-136, ELZ-142, ELZ-164
- Output: none. A change in place of the ready Piece `workflow/skill`, before the first release, with the same Piece ID. The Contract changes: `sources/3` replaces `source/2`, `load/4` replaces `load/2`, there is one new refusal `undescribed_tool`, and a load lists the declared tools of its skill. The plan text (the RC-67 job row in `docs/plans/release-plan.json` and the RC-67 note in `docs/plans/bot-platform.md`) is changed by the coordinator in the publication of this task, not by this task.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/workflow/skill/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and the `note` of its row in `entries`, because the `contract` changes). No other part of `docs/plans/`, and no file of another Piece.

RC-67 says that a skill load gives the instructions and the tools that the
pinned package declares for that skill. Today `load/2` always gives
`"listing" => nil`, so a skill never brings a tool. The agent loop already
applies a skill and a listing in one step. If the listing is refused, the
loop refuses the whole load and changes nothing. So this task changes only
`workflow/skill`.

The package says *which* tools a skill brings: a list of identity texts.
The host gives the *descriptors* of those tools as a fact, as it does for
every other tool of a Run. Each skill that declares at least one tool gets
its own source of kind `other`, callable `adapter`. That source is empty at
Run start, and the load of the skill fills it.

Facts checked on `main` (at the time of writing, at `6d140be`). They were
read, not run. Lines are "about". Confirm each fact when you start, and if
one differs, stop and ask.

- `pieces/workflow/skill/lib/elzoo/skill.ex`:
  - about 94 to 140: `source/2` gives one source of kind `pinned_skill`,
    callable `adapter`, with the tools `load_skill` and `read_skill_file`.
    The skill names are the `enum` of the argument `name`.
  - about 206 to 210: the id must match `[a-zA-Z0-9_-]{1,32}`, else
    `invalid_input`. It is checked before `no_skills` (about 95 and 212 to
    217).
  - about 153 to 165: `load/2` refuses `invalid_arguments`,
    `unknown_skill`, `empty_body` in that order, else it gives
    `{"declaration": {"skill": {"name", "instructions"}, "listing": nil}}`.
    No function reads the `"tools"` member of a skill entry.
  - about 37 to 44: the type `call_reason`.
  - Only files of this Piece call `Skill.source/2` or `Skill.load/2`: the
    test file and `examples/skill.exs` (about 87 to 88 and 100). The skill of
    the example declares no tool (about 12).
- `pieces/workflow/tool-registry/lib/elzoo/tool_registry.ex`:
  - about 125: a source id matches `[a-zA-Z0-9_-]{1,32}`. This is the bound
    of a source id. About 129: two sources with the same id are
    `invalid_source`.
  - about 132 to 135: the descriptors of one source must have unique
    `name`s; two descriptors with one name make `snapshot/1` and `refresh/3`
    refuse the whole list with `invalid_descriptor` (about 100 to 101).
  - about 137 to 147: a descriptor has exactly `annotations`, `description`,
    `input_schema`, `name`, `trust`; the name matches
    `[A-Za-z0-9_.-]{1,128}`. About 103 to 104: `trust` other than
    `"untrusted"` is `invalid_trust`.
  - about 15 and 106 to 107: more than 64 tools over all sources is
    `too_many_tools`. The two tools of the `pinned_skill` source count.
  - about 24 to 37: `refresh/3` replaces the whole tool list of one source;
    an id that is not in the snapshot is `unknown_source`. It does not read
    the kind of the source.
  - about 166 to 178: the alias is `<source id>_<name>` when that text
    matches `[a-zA-Z0-9_-]{1,64}`; otherwise it is a cut text with 8 hex
    digits of a digest. A name with a `.`, or a long alias, gets the second
    form.
- `pieces/domain/recipe-package/lib/elzoo/recipe_package.ex`:
  - about 70: a package has at most 16 skills. So the position `k` of a
    skill is 1 to 16, and `"-" <> k` is 2 or 3 bytes.
  - about 83, with 63 to 67 and 52 to 56: the `tools` of one skill are at
    most 64 unique UTF-8 texts of 1 to 128 bytes, with any characters. Some
    of them are not names that the registry accepts (for example a text with
    a space).
  - about 74: at most 64 distinct identities over all skills. An identity
    that two skills declare counts once there.
- `pieces/workflow/agent-loop/lib/elzoo/agent_loop.ex`:
  - about 316 to 331: a tool action keeps the `source_kind` of the resolved
    tool. About 359 to 363 and 386 to 387: a completed
    `elzoo.agent-loop.tool-result` whose payload is exactly
    `{"declaration": _}` is a declaration.
  - about 485 to 508: `declare/3` checks the form, then the Cure decision
    `permit`, then `load/2` (about 535 to 548: `already_loaded`, then
    `instructions_over_bound`), then `list/2` (about 550 to 553:
    `ToolRegistry.refresh/3` with the source that the listing names), then
    the state bound. Any refusal returns the state from before and the notice
    `[declaration refused: REASON]`.
  - about 550 to 553: the source of a listing is not compared with the
    source of the called tool.
  - `cure/elzoo/agent_loop.cure`, about 42 to 59: `permit` refuses every
    declaration from kind `Other`; kind `PinnedSkill` may give a skill, a
    listing or both.
  - about 378 to 384: a not completed outcome with a reason gives
    `[tool call not completed: CLASS: REASON]`.
  - about 567: each model call sends `ToolRegistry.tools(snapshot)`.
- `pieces/workflow/skill/test/elzoo/skill_test.exs`:
  - describe groups: `skill_md_split`, `folder_bounds_and_paths`,
    `yaml_refusals`, `package_checks_fields`, `pinned_skill_source` (about
    908), `load_gives_declaration` (about 1027),
    `file_read_is_marked_content`, `scripts_never_run`,
    `agent_loop_accepts` (about 1276), `pinned_version_answers` (about
    1580).
  - helpers: `skill!/2` (about 110 to 125, option `:tools`), `pinned!/1`
    (about 128 to 131), `source!/2` (about 133 to 136), `outcome/4`
    (about 1300), `model_outcome/2` (about 1310), `proposal/3` (about
    1321), `tool_result_outcome/2` (about 1330), `loop_state/1` (about 1344
    to 1361; it takes one source), `notice/1` (about 1378), `messages/1`
    and `request_tools/1` (about 1380 to 1381), `trace_scenario/0` (about
    1383 to 1445; the skill `tooly` at position 2 declares
    `tool-identity-one` and `tool-identity-two`), `tool_call/4` (about 1447
    to 1460; its source is fixed to `sk`), `requests/1` (about 1463 to
    1468).
  - No test name in the file uses the case names of the Acceptance below.
    No Piece has a file under `test/fixtures/`.

## The changed Contract

**`sources(id, package, descriptors)`** replaces `source/2`. It gives
`{:ok, sources}`:

- first, the `pinned_skill` source, equal to what `source/2` gives today;
- then, for each skill at 1-based position `k` of the package `skills` that
  declares at least one tool, in package order:
  `%{"id" => id <> "-" <> Integer.to_string(k), "kind" => "other",
  "callable" => "adapter", "tools" => []}`.

The first failing check is the result:

1. `id` does not match `[a-zA-Z0-9_-]{1,32}`: `invalid_input` (as today).
2. the package has no skill: `no_skills` (as today).
3. `descriptors` is not a proper list of maps that are not structs:
   `invalid_input`.
4. the longest per-skill source id would pass the registry's bound of 32
   bytes: `invalid_input`. A package whose skills declare no tool has no
   per-skill source, so the id rule of today stays for it. With a skill
   that declares a tool at position 1 to 9 the id may have 30 bytes; at
   position 10 to 16, 29 bytes.
5. for each skill in package order, and each declared identity in its
   order, the descriptors whose `"name"` equals the identity are counted.
   None: `undescribed_tool`. Two or more: `invalid_input`. The first such
   identity decides. (The registry refuses two descriptors with one name in
   one source as a whole list; this Piece has no reason `invalid_descriptor`,
   and the operand is malformed as a whole, so it is `invalid_input`.)

A descriptor whose name no skill declares is ignored. One descriptor serves
each skill that declares its name. `sources/3` checks no other part of a
descriptor; the registry checks the form when a load lists it.

**`load(id, package, descriptors, arguments)`** replaces `load/2`. It keeps
no state. The first failing check is the result:

1. checks 1, 3 and 4 of `sources/3`, with the same rules: `invalid_input`;
2. `invalid_arguments`, `unknown_skill`, `empty_body`, as today (a package
   with no skill is still `unknown_skill`);
3. check 5 of `sources/3` for the asked skill only: `undescribed_tool` or
   `invalid_input`.

Then:

- a skill with no declared tool: `"listing" => nil`, as today;
- else `"listing" => %{"source" => id <> "-" <> Integer.to_string(k),
  "tools" => tools}`, where `tools` is the one descriptor of each declared
  identity, in the order of the skill's `tools`, each as the host gave it.

The descriptors of `load_skill` and `read_skill_file`, `read/4` and
`read_file/3` do not change. Add `:undescribed_tool` to `call_reason`. Add
no option, record kind, state or helper module.

**What the agent loop then does, with no change of `workflow/agent-loop`:**
a load that lists tools refreshes the skill's own source; the next model
request lists the aliases of those tools; a repeat load is `already_loaded`
before any refresh; a listing that would pass 64 tools is refused whole by
`refresh/3` with `too_many_tools`, so neither instructions nor tools are
added; a descriptor that the registry refuses is refused whole with its
reason; a result of a listed tool comes from a source of kind `other`, so it
is never a declaration.

**README and `piece.json` state:**

- the descriptors are a host fact; the package says only which tools a
  skill brings;
- one source per skill that declares a tool: kind `other`, callable
  `adapter`, empty at start, filled by the load;
- the host puts every source of `sources/3` into the source set of the Run
  at start (a listing for a source that is not in the snapshot is
  `unknown_source`), gives the same descriptors to `sources/3` and
  `load/4`, and binds `{:adapter, id <> "-" <> k, name}` to the real
  Adapter of that tool;
- the model sees the alias that the registry gives to that source and name;
- a load that would pass 64 tools (all sources together, `load_skill` and
  `read_skill_file` included) is refused whole with `too_many_tools` by the
  agent loop and changes nothing;
- a tool that two skills declare is listed in the source of each skill and
  counts once for each loaded skill toward the 64;
- the results of the listed tools are never declarations;
- `allowed-tools` still grants nothing; a listed tool still passes the
  engine checks at use;
- Limits: a tool of a skill is an Adapter call; a nested callable (a Lua
  tool, a graph) as a skill tool is not part of this Piece. A declared
  identity outside the registry name grammar can be described but its load
  is refused by the registry. The agent loop does not check that a listing
  of a `pinned_skill` result targets a source of that skill.
- `piece.json`: the `contract` names `sources/3` and `load/4` and the
  listing. For example: "…; sources/3 gives the one pinned_skill
  tool-registry source of the skills of a package, with the tools load_skill
  and read_skill_file, and one empty source of kind other for each skill that
  declares a tool, after it checks that the host descriptors name each
  declared tool once; load/4 gives the declaration payload with the body of
  one skill byte for byte and a listing of the host descriptors of its
  declared tools for its own source, or no listing for a skill without
  tools; …". The `limits` entry 4 (about line 15, "A load lists no tool…")
  is replaced by what is now met. The entry 5 (about line 16): the declared
  tool is now listed, and its refusal at use is still the engine's claim; the
  test shows a recorded `refused` outcome only. The entry 6 (about line 17)
  stays: the restart case is still not shown with the harness of RC-66.
  The grounding test claim names the new cases and the new negative
  controls. The `note` of the index row equals the new `contract`.

## Task

1. Confirm the facts above at your base.
2. Make the change of the Contract in `lib/elzoo/skill.ex`.
3. Update the README sections `## source/2`, `## load/2`, "Needs and
   limits" and "Evidence", `piece.json` and `examples/skill.exs`. In the
   example, give the skill one declared tool and one descriptor, so that it
   shows a listing; the test of the example (about 1612 to 1620) asserts the
   text and the form of the identity only and stays.
4. Change the existing tests only as listed below. Name each changed test in
   the pull request body.

Existing assertions that change, in `test/elzoo/skill_test.exs`:

- about 920 to 961: `Skill.source("sk", checked) == {:ok, map}` becomes
  `Skill.sources("sk", checked, []) == {:ok, [map]}` with the same map.
- about 994, 1001, 1004 and 1006: the calls of `source/2` become
  `sources/3`; the results stay (`no_skills`, the id, `invalid_input`).
- about 1032 to 1051, 1056 to 1058, 1078, 1085, 1091, 1175, 1598 to 1602:
  `Skill.load/2` becomes `Skill.load/4`; the expected results stay.
- about 1609: the two `source/2` results become two `sources/3` results.
- the test at about 1544 to 1563 ("the tools of each model request are the
  same…"): the assertions at about 1554, 1560 and 1561 reverse. The seven
  model requests before the load of `tooly` list only the tools of the
  `pinned_skill` source; the request after it (index 14) also lists the
  aliases of `tool-identity-one` and `tool-identity-two` in the source
  `sk-2`. The assertion at about 1562 (no `allowed-tools` text) stays.
  Rename the test to what it now shows.

Helpers that change with no change of an assertion: `source!/2`,
`loop_state/1` (it takes the list of sources), `trace_scenario/0` (it gives
the host descriptors of `tooly` and the list of `sources/3`), and the call at
about 1019 (the test then gives descriptors for its declared identities). No
other existing assertion changes. If another test fails, stop and ask.

## Acceptance

New cases are tests inside the existing groups, so the eleven group names
of `piece.json` stay. Each test name starts with the case name.

In `pinned_skill_source`, over `skill!/2` and `pinned!/1`:

- `sources_literal_list`: for a package with a skill without tools at
  position 1 and one with two tools at position 2, `sources/3` gives the
  literal list: the `pinned_skill` map and `sk-2` with `"tools" => []`.
  `ToolRegistry.snapshot/1` accepts the list and `tools/1` lists only the
  two tools of the `pinned_skill` source.
- `source_id_bound`: a skill with a tool at position 1: an id of 30 bytes
  passes and 31 is `invalid_input`. A skill with a tool at position 10: 29
  passes and 30 is `invalid_input`. The existing id test of a package with
  no declared tool (about 997 to 1007) shows that 32 still passes.
- `start_check_of_descriptors`: a declared identity with no descriptor is
  `undescribed_tool`; two descriptors of one declared name are
  `invalid_input`; `descriptors` that are not a list, an improper list, or a
  list with a non-map are `invalid_input`; an undeclared extra descriptor is
  ignored; the refusals come in the order of the Contract.
- the existing test at about 1009 to 1024: no source of the list holds a
  tool identity, `allowed-tools` text or descriptor.

In `load_gives_declaration`:

- `load_lists_declared_tools`: the literal payload with the listing for a
  skill with tools (the descriptors in the order of the skill's `tools`, not
  of the host list), and `"listing" => nil` for a skill without tools.
- `load_refusal_order`: each refusal of `load/4` in its order, with
  `undescribed_tool` and `invalid_input` for the asked skill; a missing
  descriptor of another skill does not refuse this load.

In `agent_loop_accepts`, folding `AgentLoop.step/3` over recorded traces
with the helpers above (add a builder of a tool action for any source, in the
way of `tool_call/4`):

- `skill_tools_listed_after_load`: no alias of a skill tool is in a model
  request before the load; the next model request lists one alias for each
  declared tool, and its system message holds the instructions.
- `repeat_load_adds_nothing`: after `[declaration refused: already_loaded]`
  the tool list of the next model request is unchanged.
- `load_over_64_refused_whole`: the snapshot holds 63 tools in all before the
  load (the two tools of the `pinned_skill` source included); a load of a
  skill with 2 tools gives `[declaration refused: too_many_tools]`, the
  system message has no new text and the tool list is unchanged; a load of a
  skill with 1 tool, which reaches exactly 64, is accepted. Use small host
  descriptors so that the state stays under 65,536 bytes; if the state bound
  is reached first, stop and ask.
- `two_skills_keep_their_tools`: after a load of skill A and then of skill
  B, the tools of both are listed.
- `listed_tool_result_is_not_a_declaration`: a completed result in the exact
  declaration form from an action of a skill tool gives `[declaration
  refused: declaration_not_permitted]`, and nothing changes.
- `declared_tool_refused_at_use`: a `refused` outcome with a reason for an
  action of a skill tool gives `[tool call not completed: refused:
  REASON]`, and the instructions stay in the system message.
- `bad_descriptor_refused_whole`: a host descriptor that `sources/3` accepts
  and the registry refuses (for example one with an extra key) gives
  `[declaration refused: invalid_descriptor]`, and neither instructions nor
  tools are added.
- the existing cut-trace test (about 1565 to 1577) runs over the changed
  `trace_scenario/0` and passes unchanged.

In `pinned_version_answers`: the existing tests pass with `load/4` and
`sources/3`.

Negative controls, each a temporary edit that is reverted and never
committed. Record the failing output in the pull request body.

- The listing names the `pinned_skill` source (`id`) instead of `id-k`:
  `listed_tool_result_is_not_a_declaration` fails.
- `load/4` lists the described identities and skips a missing one:
  `load_refusal_order` fails.
- Every skill uses one shared source `id-1`: `two_skills_keep_their_tools`
  fails.
- `sources/3` skips check 5: `start_check_of_descriptors` fails.
- Check 4 uses the plain 32-byte rule of the id only: `source_id_bound`
  fails.

## Evidence and gate

Run `mix test pieces/workflow/skill/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check "$(git merge-base origin/main HEAD)"`. The index row
follows in the last commit (AGENTS.md section 3): `manifest_sha256` and
`note`. Then `mix elzoo.ledger`, `python3 scripts/check-roadmap.py --write`
and `python3 scripts/check-roadmap.py`.

## Review risk

Medium. One independent review. The reviewer checks:

- that the trust text in the README and `piece.json` says what the code
  does: which tools come from the package, what each tool is comes from the
  host, and a declaration is accepted only for a `pinned_skill` caller;
- that the per-skill sources have kind `other` and start empty, and that
  `sources/3` and `load/4` refuse in the stated order;
- that the README states no mechanism of the agent loop or the registry that
  their code does not have;
- that only the listed assertions changed.

## Not in scope

- Any change of `workflow/agent-loop`. It does not check that a listing of
  a `pinned_skill` result targets a source of that skill; this task does not
  change that.
- Changes of `workflow/tool-registry`, `domain/recipe-package` or
  `workflow/recipe-check`.
- A nested callable (a Lua tool, a graph) as a skill tool.
- A full check of the descriptor form at Run start.
- The harness of RC-66 (ELZ-237) and a start with a skill loaded (ELZ-236).
- The plan text of RC-67: the coordinator changes it in the publication.
