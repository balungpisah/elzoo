# ELZ-182 — Skill: instructions and files of a skill folder, loaded on demand

## Scope and reuse

- Dependencies: ELZ-033, ELZ-136, ELZ-137, ELZ-139, ELZ-140, ELZ-142, ELZ-161, ELZ-164, ELZ-170, ELZ-176
- Output: `workflow/skill`, one public module `Elzoo.Skill`; release V1B; RC-67.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/workflow/skill/**` and its index/generated changes under AGENTS.md section 3.

Admit RC-67. A skill follows the public Agent Skills format
(https://agentskills.io/specification, accessed 2026-11-12, no spec
version): a folder with `SKILL.md`, which holds YAML frontmatter and a
Markdown body, and other files. This Piece is pure. It does three things:

1. `read/4` reads a skill folder that the caller gives as data and gives
   the skill entry of a recipe package (`domain/recipe-package`) and the
   other files of the folder. It reads no file system.
2. `source/2` gives one tool-registry source of kind `pinned_skill` for the
   skills of a checked package, with a load tool and a read-file tool.
3. `load/2` and `read_file/3` answer one call of each tool: a load gives
   the declaration form that `workflow/agent-loop` accepts for a skill; a
   file read gives a result in the form of `workflow/tool-result-limit`,
   with marked content.

Decision this task rests on (owner decisions "RC-67" and "Skill trust and
bounds" in `docs/plans/bot-platform.md`, and the library decision of
2026-11-14): malformed skills are refused at package checking, not at load;
the YAML reader is the adopted `yaml_elixir` over `yamerl` (ELZ-176), never
a reader written by hand; trust comes from the pinned package manifest,
never from a path or from the shape of a result; the `SKILL.md` body is an
instruction, is never marked and is never cut; other skill files are
marked content that `workflow/tool-result-limit` may cut; `allowed-tools`
grants nothing; scripts are read as bytes and never executed.

Coordinator decision, 2026-11-14: a load lists no tool. The ready agent
loop applies a declaration whole (a refused listing also refuses the
instructions), and the package holds only the tool identities of a skill,
not the registry descriptors that a listing needs. So a load gives the
instructions only, and the RC-67 acceptance case "a load that would pass
64 tools gives the instructions and the named refusal" is not met by this
task (see Limits). The restart case of RC-67 is shown by folding the agent
loop again over a cut trace, not with the harness of RC-66, which is not a
dependency.

Implement only the named acceptance groups below. Use the public functions
of the reused Pieces as they are on main, and of `YamlElixir` only
`read_from_string/2` with the option list `[]` (the call that
`docs/dependencies.md` names for RC-67). Never call `yamerl_app`. Add no
process, no storage, no file access, no Markdown parser, no options,
behaviours or hooks. Edit no ready Piece, shared path, pin or CI file. No
fixtures directory is needed: each skill folder in a test is a literal
map.

## Facts checked on main

Confirm each when you start; if one differs, stop and ask.

- `domain/recipe-package` (ELZ-164): `Elzoo.RecipePackage.decode/1` gives
  `{:ok, checked}` or `{:error, reason}`; `encode/1` of a checked value
  gives the original map. It first checks that the whole package is plain
  data: a string that is not valid UTF-8, or a map key that is not a
  string, is `:invalid_shape`. `"skills"` is a list of at most 16 maps
  with exactly `name`, `version`, `tools`, `frontmatter`, `body` and
  unique names. `name` is 1 to 64 bytes matching
  `\A[a-z0-9]+(?:-[a-z0-9]+)*\z`; `version` 1 to 128 bytes of UTF-8;
  `tools` at most 64 unique texts of 1 to 128 bytes (union over all skills
  at most 64); `body` UTF-8 of 0 to 16,384 bytes, at most 32,768 bytes over
  all skills. `frontmatter` is a map with `name` and `description` and only
  `license`, `compatibility`, `metadata`, `allowed-tools`; its `name` must
  equal the entry `name` (`===`). `description` is 1 to 1,024 code points,
  `license` 1 to 1,024 bytes, `compatibility` 1 to 500 code points,
  `metadata` a map of at most 32 pairs of text keys (1 to 128 bytes) and
  text values (0 to 1,024 bytes), `allowed-tools` text of 0 to 4,096
  bytes. Each other field value it accepts is a binary. Skill refusals are
  `:invalid_skill` and, for a count or size over its bound, `:too_large`.
  The package identity is the SHA-256 of canonical JSON of all fields but
  `identity`; the checked example
  `pieces/domain/recipe-package/examples/recipe_package.exs` shows a valid
  package and how the identity is computed.
- `workflow/tool-registry` (ELZ-136): a source is exactly `"id"` (1 to 32
  bytes of `[a-zA-Z0-9_-]`), `"kind"` (`"pinned_skill"`, `"host_listing"`
  or `"other"`), `"callable"` (`"adapter"` or `"nested"`) and `"tools"`. A
  descriptor is exactly `"trust"` (`"untrusted"`), `"name"` (1 to 128 bytes
  of `[A-Za-z0-9_.-]`), `"description"`, `"annotations"` and
  `"input_schema"`. The alias is `id <> "_" <> name` when that matches
  `[a-zA-Z0-9_-]{1,64}`. A model-facing description over 4,096 bytes is
  cut; the input schema is not. `snapshot/1` refuses more than 64 tools.
- `workflow/agent-loop` (ELZ-142), `lib/elzoo/agent_loop.ex`: a completed
  outcome of a tool action is read only under `elzoo.agent-loop.tool-result`
  version 1; another schema gives `[tool result not readable]`. Under that
  schema, a payload that is a map with the one key `"declaration"` is a
  declaration. Its value must be a map with exactly the two keys `"skill"`
  and `"listing"` (`map_size == 2`); each may be `null`, not both. A skill
  is exactly `{"name": 1..64 bytes, "instructions": non-empty text}`. A
  declaration is permitted only when the called tool's source has kind
  `pinned_skill` (or `host_listing` without a skill). The checks in order:
  `invalid_declaration`, `declaration_not_permitted`, `already_loaded`
  (same `name` loaded before), `instructions_over_bound` (16,384 bytes of
  loaded instructions in all), the refusal of `ToolRegistry.refresh/3`,
  `state_over_bound`. A refusal changes nothing; the tool result is the
  notice `[declaration accepted]` or `[declaration refused: REASON]`. A
  declaration never goes to `ToolResultLimit`; each other payload under
  that schema goes to `ToolResultLimit.decide/3`. An outcome that is not
  completed gives `[tool call not completed: CLASS: REASON]` when its
  payload has a `"reason"` in `[a-z0-9_]{1,64}`. The state, which holds
  the snapshot and the loaded instructions, is bound to 65,536 bytes.
- `workflow/prompt-assembly` (ELZ-140): `role_instructions` holds at least
  one text; the one `system` message is each role instruction, then each
  skill instruction, joined by one empty line; role and skill instructions
  are never dropped.
- `workflow/tool-result-limit` (ELZ-139): a result is exactly
  `%{"content" => marked_map, "media_type" => text, "encoding" => "utf8" |
  "base64"}`. With `%{max_bytes: n, artifact_max_bytes: m}`, `decide/3`
  gives `{:ok, %{"content" => same_map, "cut" => nil}}` for text of at
  most `n` bytes, `{:store, pending, payload}` for text over `n` or any
  binary result of at most `m` bytes, `{:ok, bounded}` with the note
  `over_artifact_max` above `m`, and `{:error, :unmarked}` when `content`
  is not a marked map. Its README states that a skill file is cut like any
  result and a `SKILL.md` body is refused as `:unmarked`.
- `workflow/untrusted-content` (ELZ-137): `decode/1` is the only way to
  make a marked value; the neutral map is exactly `schema_id`
  (`"elzoo.untrusted-content.marked"`), `schema_version` (1), `sources` (1
  to 16 texts of `[A-Za-z0-9._:/@-]`, 1 to 256 bytes each), `trust`
  (`"untrusted"` or `"derived"`), `max_bytes` (1 to 16,777,216) and
  `content` (UTF-8 of at most `max_bytes` bytes); `encode/1` gives it back.
- `workflow/version-pin` (ELZ-170): a running Run keeps the package
  identity that it pinned; `{:published, _}` changes nothing.
- ELZ-176 (`docs/dependencies.md`, section "YAML reader for skill
  frontmatter", and `test/elz176_yaml_provider_test.exs`) records for
  `yaml_elixir` 2.12.2 over `yamerl` 0.10.0, with options `[]`: keys and
  quoted values are strings; plain `true`, `null`, `~`, `12`, `1.5`,
  `0x10` and an empty value are `true`, `nil`, `nil`, `12`, `1.5`, `16`,
  `nil`; `!!binary` is decoded; an alias is expanded with no marker and no
  error, and no option and no result form refuses or shows it; a
  flow-style alias chain gives wrong values with no error; a merge key
  `<<` stays a key `"<<N"` with an unstable `N`; two documents give the
  last one, with no error; a duplicate key keeps the first value with no
  error; a tab-indented line is read as a key of the top level; a list or
  a scalar document is `{:ok, _}` of that term, and the empty string is
  `{:ok, %{}}`; an unknown tag (`a: !ruby/object:Foo {x: 1}`) and an
  unterminated flow collection (`a: [`) are
  `{:error, %YamlElixir.ParsingError{}}`; no input raised; the tags that
  run Erlang code are refused only while the `yamerl` parameter
  `node_mods` is `[]`; a 16,384-byte document parsed inside a limit of 5
  seconds, and a 1 MiB document used most of that limit.
  `read_all_from_string/2` is public but has no documented text.

## Interface: `Elzoo.Skill`

All refusals are `{:error, reason}` with a fixed atom from the lists
below. No error, log or telemetry event holds a path, a file byte, a
frontmatter value or a body.

### `read(name, version, tools, files)`

`name` is the folder name, `version` and `tools` the version and tool
identities that the caller declares for the skill (the public format has
no such fields). `files` maps a relative path to the bytes of that file.
It returns `{:ok, %{entry: entry, files: rest}}`, where

    entry = %{"name" => name, "version" => version, "tools" => tools,
              "frontmatter" => map, "body" => body}

and `rest` is `files` without the key `"SKILL.md"`. `read/4` does not
check `name`, `version`, `tools` or the fields of the frontmatter:
`RecipePackage.decode/1` of a package that holds the entry does that, and
it is the package check of this task. The checks of `read/4`, in this
order; the first that holds is the result:

1. `:invalid_input`: `name` or `version` is not a binary, `tools` is not a
   list, `files` is not a map, or a key or value of `files` is not a
   binary.
2. `:invalid_path`: a path is not valid UTF-8, is not 1 to 1,024 bytes,
   holds the byte NUL or `\`, or, split at `/`, has an empty segment, a
   segment `.` or a segment `..` (so no leading or trailing `/`).
3. `:folder_too_large`: more than 256 files, a file over 1,048,576 bytes,
   or more than 8,388,608 bytes in all (`SKILL.md` included).
4. `:missing_skill_md`: no key that is exactly `"SKILL.md"`.
5. `:invalid_utf8`: `SKILL.md` is not valid UTF-8.
6. `:missing_frontmatter`: `SKILL.md` does not start with the line `---`
   (the three bytes, then LF or CR LF), or no later line is exactly `---`
   (then LF, CR LF or the end of the file). A byte-order mark is not
   skipped, so a file that starts with one is refused here. The
   frontmatter is the bytes after the opening line and before the first
   closing line; the body is the bytes after the line end of the closing
   line, unchanged.
7. `:frontmatter_too_large`: the frontmatter, as cut in rule 6, is over
   16,384 bytes. This is the largest text that this Piece gives the
   reader.
8. The frontmatter scan below, which gives `:invalid_yaml`,
   `:not_a_map`, `:tab_indentation`, `:yaml_alias` or `:duplicate_key`.
   It also makes the text `T` of the frontmatter: each CR LF replaced by
   LF.
9. `:not_a_map`: `T` holds only spaces, tabs and LF.
10. `:invalid_yaml`: `YamlElixir.read_from_string(T, [])` gives
    `{:error, _}`.
11. `:not_a_map`: it gives `{:ok, term}` where `term` is not a map.
12. `:empty_body`: the body is empty (zero bytes). The agent loop refuses
    an empty `instructions`.

A value that YAML typed (a Boolean, a number, `nil`, a list, a map where
text is due) is not refused by `read/4`. `RecipePackage.decode/1` refuses
it, as `:invalid_skill`, or as `:invalid_shape` for a value that is not
plain UTF-8 data (for example `description: !!binary //4=`, whose bytes
are not UTF-8) or a key that is not a string (for example `1: x`). This
Piece does not map these reasons: the caller gets them from the package
check. A key `"<<N"` cannot occur, because the scan refuses each key `<<`.

### The frontmatter scan

The pinned reader expands an alias with no marker, gives wrong values for
a flow-style alias chain, keeps a merge key as an unstable `"<<N"`, keeps
the first of two equal keys, reads a second document over the first and
reads a tab-indented line as a key of the top level, all with no error
(ELZ-176); no option of `yaml_elixir` or `yamerl` refuses an alias. So
`read/4` scans the frontmatter before it calls the reader. The scan is
not a YAML reader: it only finds the places where a node can begin, and it
refuses more than YAML requires where it cannot tell (see Limits). It runs
in three passes, and the first refusal ends it.

**Pass 1, line ends.** Each CR LF becomes LF; the result is `T`. A CR
left in `T` (a CR not followed by LF) is `:invalid_yaml`. The reader gets
`T`, never a CR.

**Pass 2, document markers.** `T` is split at LF into lines. A line that
is `---` or `...`, or begins with `--- `, `---` and a tab, `... ` or `...`
and a tab, is `:not_a_map` (a second document). This pass looks at every
line before pass 3 starts.

**Pass 3, lines in order.** The indentation of a line is its number of
leading spaces; its column numbers start at 0. A line is blank when it
holds only spaces and tabs. A line is a comment line when its first byte
after the indentation is `#`. Within one line the rules apply from left
to right, and a key is checked before its value.

*Regions.* A region starts on one line, at an opening column, and holds
the following lines that are blank, or whose indentation is greater than
the opening column. The first other line ends the region; for a flow
region, a comment line does not end it.

- A *block region* starts where a node text `T'` (below) is `|` or `>`,
  followed by at most two bytes of `+`, `-`, `1` to `9`, then nothing,
  spaces, or spaces, `#` and a comment. Its opening column is the column
  of the key whose value it is; when `T'` came directly after a dropped
  indicator, the column of that indicator. Lines of a block region,
  comment lines and lines with `&`, `*`, `<<` or a tab included, are block
  text and are not scanned.
- A *flow region* starts where a node text `T'` begins with `[` or `{`,
  with the opening column chosen as for a block region. It holds the rest
  of that line from that byte and the lines of the region. In it, `<<`
  anywhere is `:yaml_alias`, and so is a byte `&` or `*` that is the first
  byte after the indentation of a line of the region, or the first byte
  after `[`, `{`, `,` or `:` and any spaces. Quotes are not tracked in a
  flow region.

*Other lines.* Outside every region, a blank line or a comment line is
skipped. A line whose first byte after the indentation is a tab is
`:tab_indentation`. Otherwise drop the indentation, then drop each
leading indicator `- `, `? ` or `: ` with the spaces after it, and a last
lone `-`. The rest is the node text `T'`, scanned so (the first case that
fits):

1. `T'` begins with `&` or `*`: `:yaml_alias`.
2. `T'` begins with `!`: drop the bytes up to the first space (or to the
   line end) and the spaces after them; scan the rest as `T'`. An empty
   rest is not scanned.
3. `T'` begins with `[` or `{`: a flow region starts.
4. `T'` is a block indicator as above: a block region starts.
5. `T'` begins with `'` or `"`: a quoted scalar. Its end is the first `'`
   that is not followed by another `'` (a pair `''` is skipped), or the
   first `"` that is not preceded by an odd number of `\`, on the same
   line. When the end is on the line and is followed by optional spaces,
   `:` and a space, a tab or the line end, the inner text is a key and the
   text after `:` and its spaces is a value, scanned as `T'`. Otherwise
   nothing more on the line is scanned.
6. Otherwise `T'` is plain. A key is the text before the first `:` that is
   followed by a space, a tab or the line end, with trailing spaces
   dropped; the text after that `:` and its spaces is a value, scanned as
   `T'`. A plain text with no such `:` is not scanned further, so `*` and
   `&` inside it pass (`Use for *.xlsx files`, `R&D`, `a & b`).

A key that is `<<` (plain, or the inner text of a quoted key) is
`:yaml_alias`. The *top-level key* of a line is the first key of a line
of indentation 0 from which no indicator was dropped; a later key on the
same line (for example inside `license: MIT # see: name`) is not one. Its
text is the plain key, or the inner text of a quoted key (in single quotes
each `''` read as `'`; in double quotes the bytes as written). A top-level
key equal to the top-level key of an earlier line is `:duplicate_key`.

### `source(id, package)`

`package` is a value that `RecipePackage.decode/1` gave; any other value
is outside the Contract. `id` must be 1 to 32 bytes of `[a-zA-Z0-9_-]`,
else `{:error, :invalid_input}`. A package with no skill is
`{:error, :no_skills}`. Otherwise `{:ok, source}`, exactly:

    %{"id" => id, "kind" => "pinned_skill", "callable" => "adapter",
      "tools" => [load, read_file]}

Let `names` be the skill names in the order of the package and `listing`
the texts `name <> ": " <> description` (the `description` of the
frontmatter) of those skills, in that order, joined by one LF. Then:

    load = %{"trust" => "untrusted", "name" => "load_skill",
      "description" => "Load the instructions of one skill by its name.",
      "annotations" => nil,
      "input_schema" => %{"type" => "object",
        "properties" => %{"name" => %{"type" => "string",
          "enum" => names, "description" => listing}},
        "required" => ["name"], "additionalProperties" => false}}

    read_file = %{"trust" => "untrusted", "name" => "read_skill_file",
      "description" => "Read one file of a skill by its relative path.",
      "annotations" => nil,
      "input_schema" => %{"type" => "object",
        "properties" => %{"skill" => %{"type" => "string",
          "enum" => names}, "path" => %{"type" => "string",
          "minLength" => 1}},
        "required" => ["skill", "path"],
        "additionalProperties" => false}}

The descriptions of the skills are in the input schema, which the
registry does not cut. The source names no tool of a skill and no
`allowed-tools` text.

### `load(package, arguments)`

`arguments` is the `arguments` member of the tool-call payload. In order:
`:invalid_arguments` when it is not a map with exactly the key `"name"`
whose value is a binary; `:unknown_skill` when no skill of the package has
that name; `:empty_body` when its body is empty (a package that a caller
built without `read/4` can hold one). Otherwise `{:ok, payload}`, exactly:

    %{"declaration" => %{
        "skill" => %{"name" => name, "instructions" => body},
        "listing" => nil}}

`instructions` is the `body` of the package entry, byte for byte: no
frontmatter, no mark, no cut. `"listing"` is always present and always
`nil`: a load lists no tool (see Limits).

### `read_file(package, files, arguments)`

`files` maps a skill name to the `files` value that `read/4` gave for
that skill (the host keeps them with the pinned version). In order:

1. `:invalid_arguments`: `arguments` is not a map with exactly the keys
   `"skill"` and `"path"` whose values are binaries.
2. `:unknown_skill`: no skill of the package has that name.
3. `:unknown_file`: the path is `"SKILL.md"`.
4. `:invalid_input`: `files` is not a map, or `files[skill]` exists and is
   not a map, or the value found for the path is not a binary.
5. `:unknown_file`: `files[skill]` does not exist, or it has no key equal
   to the path (exact bytes, no normalisation).
6. `:file_too_large`: the file is over 1,048,576 bytes.

Otherwise `{:ok, result}`, exactly
`%{"content" => marked, "media_type" => media_type, "encoding" =>
encoding}`. When the bytes are valid UTF-8, `media_type` is
`"text/plain"`, `encoding` `"utf8"` and the text is the bytes; otherwise
`"application/octet-stream"`, `"base64"` and the text is
`Base.encode64(bytes)` (padded). `marked` is the neutral map that
`UntrustedContent.encode/1` gives for the value that `decode/1` gives for
`%{"schema_id" => "elzoo.untrusted-content.marked", "schema_version" => 1,
"sources" => ["skill:" <> skill], "trust" => "untrusted", "max_bytes" =>
max(1, byte_size(text)), "content" => text}`.

## Host Needs and Limits

Fixed bounds, not Config: 256 files, 1,048,576 bytes for one file and
8,388,608 bytes for one folder; paths of 1 to 1,024 bytes; 16,384 bytes of
frontmatter, so the reader never gets more than 16,384 bytes. No time
bound is set: ELZ-176 shows a 16,384-byte document parsing inside 5
seconds. The scan and its reasons are this Piece's own. The bounds of
`domain/recipe-package` (16 skills, body 16,384 bytes each and 32,768 in
all, frontmatter fields) and of `workflow/agent-loop` (16,384 bytes of
loaded instructions in all, `already_loaded`, state 65,536 bytes) are
theirs; this Piece does not check them again.

Needs: a host that puts each entry of `read/4` into the recipe package and
publishes only a package that `RecipePackage.decode/1` accepts; that pins
the package of a Run (`workflow/version-pin`) and gives `source/2`,
`load/2` and `read_file/3` that pinned package and the files of that same
version, never those of a later one; that stores the skill files (this
Piece stores nothing: the caller holds the bytes); a source set that holds
the source of `source/2` and a truthful kind for each other source; a
`tool_call` binding that maps `{:adapter, id, "load_skill"}` to `load/2`
and `{:adapter, id, "read_skill_file"}` to `read_file/3`, gives `{:ok,
payload}` as a completed outcome under `elzoo.agent-loop.tool-result`
version 1, and gives `{:error, reason}` as an outcome of class `refused`
with the payload `{"reason": reason}` (the atom as text); skill
descriptions short enough that the snapshot fits the state bound of the
agent loop; the `yamerl` parameter `node_mods` left at `[]` (this Piece
never sets it); the `yamerl` application, which `yaml_elixir` starts.

Limits: trust is the host's pin of the package; a matching identity
authenticates nobody (ELZ-164). The body is trusted because the package
identity covers it. The other files are not in the package identity: they
are marked content, and that they belong to the pinned version is a host
Need, as the coordinator decided.

The scan refuses some texts that are not aliases: a continuation line of a
plain or quoted scalar that begins with `&` or `*`; a `&` or `*` after
`: ` inside a trailing comment (`license: MIT # note: *x`); a `&`, `*` or
`<<` inside quoted text of a flow collection; a plain value that holds
`: *` (a plain scalar of YAML cannot hold `: ` at all). A byte-order mark
is refused (`:missing_frontmatter`). A duplicate key below the top level,
a duplicate in a top level written in flow style or with `?` keys, and two
double-quoted keys that are equal only after their escapes are decoded
are not refused: the pinned reader keeps the first value.

RC-67 sentences that this task does not meet, or meets only in part:

- "A load that would pass 64 tools gives the instructions and the named
  refusal": not met. A load lists no tool; the declared `tools` of a skill
  are package declarations only. Listing the tools of a skill needs a
  change of `workflow/agent-loop` (a declaration whose listing is refused
  must still add its instructions) and is its own later task.
- "A skill whose declared tool is not permitted for the principal (the
  instructions load, the tool is refused at use)": the instructions load
  whatever the declared tools are (group 9); the refusal at use is the
  work of the engine and the registry, not of this Piece.
- "Scripts are stored and read, never executed": this Piece reads and
  never executes; storing is a host Need.
- "A changed skill version does not change a running Run": that is
  `workflow/version-pin` and the host's pin; here it is shown only by pure
  functions over the package given (group 10).
- "With the harness of RC-66, a load survives a restart and is not done
  again": shown by folding the agent loop again over a cut trace
  (group 9), not with the harness.

A file read is not tied to a loaded skill. The media type is `text/plain`
or `application/octet-stream`, never guessed from the path. No Markdown
is parsed; no script is run, compiled or evaluated. Telemetry, Config and
Control are not applicable: pure functions over intrinsic operands and
fixed bounds.

The manifest declares `kind: owned`, providers `elixir`, `yaml_elixir` and
`yamerl`, and the Piece dependencies `domain/recipe-package`,
`workflow/untrusted-content`, `workflow/tool-registry`,
`workflow/tool-result-limit` and `workflow/agent-loop` (the last three for
the tests of groups 5, 7 and 9).

## Named acceptance groups

Each skill folder is a literal map. A test that needs a package puts the
entries into the package of the checked example of
`domain/recipe-package` and computes its identity as that example does.

1. **`skill_md_split`**: an LF file and the same file with CR LF give the
   same frontmatter map (pass 1 turns CR LF into LF before the scan and
   the reader) and the body bytes after the closing line; a `---` with a
   trailing space is not a closing line; each case of
   `:missing_frontmatter` (no opening line, a byte-order mark first, no
   closing line); frontmatter of exactly 16,384 bytes reads and 16,385
   bytes is `:frontmatter_too_large`; `:invalid_utf8`;
   `:missing_skill_md` (also for `skill.md`); `:empty_body` for a file
   that ends at the closing line.
2. **`yaml_refusals`**: `read/4` of a folder whose `SKILL.md` has each
   frontmatter below (written as Elixir strings; `P` stands for
   `"name: s\ndescription: d\n"`) and a non-empty body gives exactly the
   result named:
   1. `"base: &b\n  x: 1\nuse: *b\n"`: `:yaml_alias` (line 1, value
      `&b`).
   2. `"- *b\n"`: `:yaml_alias` (node text after `- `).
   3. `"&k name: x\n"`: `:yaml_alias` (node text begins with `&`).
   4. `"a: !!str &x y\n"`: `:yaml_alias` (the tag is dropped).
   5. `"b: x\na: [c, *b]\n"`: `:yaml_alias` (flow region, `*` after
      `, `).
   6. `"metadata: {k: v,\n  j: *b}\n"`: `:yaml_alias` (line 2 is in the
      flow region; `*` after `: `).
   7. `"<<: x\n"` and `"m: {<<: x}\n"` and `"\"<<\": x\n"`:
      `:yaml_alias` each (a key `<<`; `<<` in a flow region; a quoted key
      `<<`).
   8. `"- a: |\n    t\n  b: *x\n"`: `:yaml_alias` (the block region
      opened at column 2 ends at line 3, whose indentation is 2).
   9. `P <> "license: MIT # see: name\n"`, `P` with the description
      `Use for *.xlsx files, R&D, a & b, 5 * 3`, `P <>
      "license: '*x'\ncompatibility: \"&x\"\nallowed-tools: \"<<\"\n"`,
      `P <> "metadata:\n  k: a\n  k: b\n"`, and `"name: s\n" <>
      "description: |\n  * one\n  & two\n  \tthree\n# c\n" <>
      "license: x\n"`, and the same with `>`: each gives `{:ok, _}` (no
      top-level key twice; a plain text; quoted scalars; a nested
      duplicate, of which the reader keeps the first value; block text
      with `*`, `&` and a tab, ended by the comment line at column 0).
   10. `"name: a\nname: b\n"` and `"name: a\n'name': b\n"`:
       `:duplicate_key`; `"name: a\nname: *x\n"`: `:duplicate_key` (the
       key before its value); `"name: *x\nname: y\n"`: `:yaml_alias`
       (the earlier line).
   11. `"a:\n\tb: 1\n"`: `:tab_indentation`.
   12. `"name: a\n...\nname: b\n"` and `P <> "--- # c\n"` and
       `P <> "--- x\n"`: `:not_a_map` (pass 2, before the duplicate of
       the first).
   13. `"name: a\rdescription: b\n"`: `:invalid_yaml` (a lone CR).
   14. A blank frontmatter (`"  \n"`), `"- a\n- b\n"` and
       `"just text\n"`: `:not_a_map`.
   15. `"a: [\n"`, `"a: !ruby/object:Foo {x: 1}\n"` and
       `"a: !<tag:yamerl,2012:fun> persistent_term:put(elz_skill, ran).\n"`:
       `:invalid_yaml` each; after the last, `:persistent_term.get/2` of
       `elz_skill` gives its default.
3. **`package_checks_fields`**: an entry of `read/4` passes
   `RecipePackage.decode/1`; through the package check, `:invalid_skill`
   for a frontmatter name that differs from the folder name, for each
   name rule (uppercase, edge hyphen, `--`), for a missing or empty
   description, for an unknown field, for plain `true`, `12` and `null`
   as a description and for `1.5` as a metadata value; `:invalid_shape`
   for `description: !!binary //4=` (bytes FF FE) and for a key `1`;
   `:too_large` for a 65-byte name, a description of 1,025 code points
   (multibyte text; 1,024 passes) and a body of 16,385 bytes. Each is the
   package's result; the test shows that `read/4` itself gave `{:ok, _}`.
4. **`folder_bounds_and_paths`**: `:invalid_path` for `/a`, `a/`, `a//b`,
   `./a`, `a/../b`, `a\b`, a NUL byte, invalid UTF-8 and 1,025 bytes;
   1,024 bytes passes; 256 files pass and 257 do not; a file of 1,048,576
   bytes passes and one more byte does not; 8,388,608 bytes in all pass
   and one more byte does not; `:invalid_input` for each operand rule; a
   folder with both an invalid path and too many files is
   `:invalid_path`.
5. **`pinned_skill_source`**: `source/2` equals the literal map above for
   a package with two skills; `ToolRegistry.snapshot/1` accepts it and
   `ToolRegistry.tools/1` shows the aliases `<id>_load_skill` and
   `<id>_read_skill_file`, the names in package order and each whole
   description in the input schema, also for a description of 1,024
   four-byte code points; `:no_skills`; `:invalid_input` for a 33-byte id
   and an id with `.`; the source holds no `allowed-tools` text and no
   tool identity of a skill.
6. **`load_gives_declaration`**: the payload equals the literal form for
   each skill of the package; `:unknown_skill`; `:invalid_arguments` for
   a missing key, an extra key and a non-text name; `:empty_body` for a
   package entry with an empty body.
7. **`file_read_is_marked_content`**: a text file gives `text/plain`,
   `utf8` and a marked map that `UntrustedContent.decode/1` accepts with
   the source `skill:<name>`; a binary file gives `base64`; an empty file
   gives `max_bytes` 1; with `%{max_bytes: 1_024, artifact_max_bytes:
   1_048_576}`, `ToolResultLimit.decide/3` gives `{:store, _, _}` for a
   text file of 2,000 bytes and `{:ok, %{"cut" => nil}}` with the same
   content for one of 1,000 bytes; `decide/3` of a result whose content is
   the body text is `{:error, :unmarked}`; `:unknown_file` for
   `SKILL.md`, an unknown path and a skill missing from `files`; each
   other refusal in its order.
8. **`scripts_never_run`**: a folder with `scripts/run.sh` and
   `scripts/run.exs` whose text would write a sentinel (a file in a
   temporary directory and `:persistent_term.put/2`): `read/4` and
   `read_file/3` give their bytes unchanged, and no sentinel exists after
   either.
9. **`agent_loop_accepts`**: `AgentLoop.step/3` folded over a recorded
   trace with the source in its sources and one role instruction, in the
   input forms of the tests of `workflow/agent-loop`. A proposal of
   `<id>_load_skill` gives one tool action; its completed outcome under
   `elzoo.agent-loop.tool-result` version 1 with the payload of `load/2`
   gives `[declaration accepted]`, and the system message of the next
   model call ends with an empty line and the body, outside every marked
   block. A second load of the same skill gives `[declaration refused:
   already_loaded]` and the body stays in the system message once. A
   load whose body would pass 16,384 bytes of loaded instructions gives
   `[declaration refused: instructions_over_bound]` and changes nothing. A
   `read_skill_file` outcome becomes a tool result inside a marked block.
   A `refused` outcome with `{"reason": "unknown_skill"}` gives `[tool
   call not completed: refused: unknown_skill]`. The tools of each model
   request are the same before and after a load of a skill with `tools`
   and `allowed-tools`. The same trace cut after each input and folded
   again from the start gives the same states and requests, and the load
   action identity appears in one request only.
10. **`pinned_version_answers`**: packages P1 and P2 differ in one skill
    (body, version, one file); `load/2` and `read_file/3` given P1 and
    its files give P1's body and bytes after P2 exists; the identities of
    P1 and P2 differ. One small checked example `examples/skill.exs`
    reads a folder, builds a package and answers one load and one file
    read.

## Evidence and gate

Test: the ten groups. Upstream: the Contracts of the reused Pieces and the
recorded behaviour of `yaml_elixir` 2.12.2 over `yamerl` 0.10.0 (ELZ-176),
scoped as they state them. This task selects no Cure law: its decisions
are byte and map checks; do not add a Boolean restatement. Negative
controls: temporarily remove case 1 of pass 3 (group 2 must fail: case 2.1
then reads), then temporarily leave the `"listing"` member out of the load
payload (group 9 must fail with `[declaration refused:
invalid_declaration]`). Restore both before the final gate.

Run `mix test pieces/workflow/skill/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. The copied consumer of the small gate must finish
within its existing 300 seconds; if it does not, stop and report the
measured time to the coordinator. One independent review checks the body
and the exact diff, including extra features.

## Not in scope

A file system, archive or folder reader; storage of skill files
(`state/artifact` or another); a listing of skill tools (a later task on
`workflow/agent-loop`); MCP `io.modelcontextprotocol/skills`; approval of
a skill digest; a check of the frontmatter fields (the package does it); a
YAML writer or a second YAML reader; script execution;
`runtime/recipe-test`; and any change of a ready Piece.
