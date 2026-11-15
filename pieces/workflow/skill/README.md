# workflow/skill

`Elzoo.Skill` is four pure functions over a skill folder that the caller gives
as data (the public Agent Skills format: a folder with `SKILL.md`, which holds
YAML frontmatter and a Markdown body, and other files): `read/4` reads the
folder, `sources/3` gives the tool sources of the skills of a checked package,
and `load/4` and `read_file/3` answer one call of each tool. Every refusal is
`{:error, reason}` with a fixed atom that holds no path, file byte, frontmatter
value or body.

## `read/4`

`Elzoo.Skill.read(name, version, tools, files)` reads a skill folder that the
caller gives as data. `files` maps a relative path to the bytes of that file.
It gives `{:ok, %{entry: entry, files: rest}}` or `{:error, reason}`. It reads no
file system, starts no process and stores nothing.

    entry = %{"name" => name, "version" => version, "tools" => tools,
              "frontmatter" => map, "body" => body}

`rest` is `files` without the key `"SKILL.md"`. `read/4` checks nothing of
`name`, `version`, `tools` or the fields of the frontmatter: `name` and `version`
must be binaries and `tools` a list, no more. `Elzoo.RecipePackage.decode/1` of a
package that holds the entry checks the rest, and it gives the reasons of that
check.

## Checks of `read/4`

The first check that holds is the result, in this order.

| # | Reason | Holds when |
| --- | --- | --- |
| 1 | `invalid_input` | `name` or `version` is not a binary, `tools` is not a list, `files` is not a map, or a key or value of `files` is not a binary |
| 2 | `invalid_path` | a path is not valid UTF-8, is not 1 to 1,024 bytes, holds NUL or `\`, or has an empty segment, `.` or `..` when split at `/` |
| 3 | `folder_too_large` | more than 256 files, a file over 1,048,576 bytes, or more than 8,388,608 bytes in all (`SKILL.md` included) |
| 4 | `missing_skill_md` | no key that is exactly `"SKILL.md"` |
| 5 | `invalid_utf8` | `SKILL.md` is not valid UTF-8 |
| 6 | `missing_frontmatter` | `SKILL.md` does not start with the line `---`, or no later line is exactly `---` |
| 7 | `frontmatter_too_large` | the frontmatter is over 16,384 bytes |
| 8 | `invalid_yaml`, `not_a_map`, `tab_indentation`, `yaml_alias`, `duplicate_key` | the frontmatter scan below |
| 9 | `not_a_map` | the frontmatter holds only spaces, tabs and LF |
| 10 | `invalid_yaml` | the YAML reader gives an error |
| 11 | `not_a_map` | the YAML reader gives a term that is not a map |
| 12 | `empty_body` | the body is empty |

A line is `---` when it is exactly those three bytes followed by LF, CR LF or the
end of the file. A byte-order mark is not skipped, so a file that starts with one
is `missing_frontmatter`. The frontmatter is the bytes after the opening line and
before the first closing line, as written in the file; its size is measured
before CR LF becomes LF. The body is the bytes after the line end of the closing
line, unchanged. No refusal holds a path, a file byte, a frontmatter value or a
body.

The frontmatter text goes to `YamlElixir.read_from_string/2` with the option
list `[]`, the only call of the reader. A value that YAML typed (a Boolean, a
number, `nil`, a list, a map where text is due) is not refused here; the package
check refuses it.

## The frontmatter scan

The pinned reader expands an alias with no marker, keeps a merge key as an
unstable `"<<N"`, keeps the first of two equal keys, reads a second document
over the first and reads a tab-indented line as a top-level key, all with no
error, and no option refuses an alias. So `read/4` scans the frontmatter before
it calls the reader. The scan is not a YAML reader: it finds the places where a
node can begin and refuses more than YAML requires where it cannot tell. Three
passes; the first refusal ends the scan.

1. Each CR LF becomes LF (this is the text `T`); a CR that is left is
   `invalid_yaml`.
2. A line that is `---` or `...`, or begins with one of them and a space or a
   tab, is `not_a_map`. Every line is looked at before pass 3.
3. Lines in order. A block region (`|` or `>` with at most two modifier bytes)
   is not scanned. A flow region (`[` or `{`) is scanned token by token, with
   its state carried from line to line, until its brackets close: a `<<` is
   `yaml_alias` anywhere in it; a `&` or `*` that starts a token (after `{`,
   `[`, `,`, `:`, `]`, `}`, a comment or the end of a tag, with spaces, tabs and
   line breaks between, or none) is `yaml_alias`, also after a flow collection
   that closes on its line; a `?` at a token start (not after `]` or `}`) that
   a space, a tab or the line end follows is `invalid_yaml`, and it is checked
   before an alias of the same line. Quoted text (a quote opens only at a token start;
   `''` and `\"` are the escapes) and a comment (`#` after a blank) hide
   their `&` and `*`. Spaces and tabs both separate a key from its `:`, a `:`
   from its value and a tag from its node, because the reader accepts a tab
   there. Other lines: a tab first after the indentation is
   `tab_indentation`; after the indicators `- ` and `: ` the node text is
   `yaml_alias` when it begins with `&` or `*` (a tag is dropped first),
   `invalid_yaml` when it begins with `?` and a space, a tab or the line end
   (an explicit key, which can hide a key `<<`), and a key `<<` is
   `yaml_alias`. A key at indentation 0 that an earlier line already had is
   `duplicate_key`; a key is checked before its value.

   After the closing quote of a quoted scalar only spaces and tabs, then the
   end of the line, a comment (`#` after a space or a tab) or `:` followed by
   a space, a tab or the end of the line may come; in a flow region also `,`,
   `]`, `}` and `:`. Every other byte is `invalid_yaml`, so `'a':[x]`,
   `'k' ? x` and `"a"b` are refused and no text is glued on to a quoted scalar.
   A quoted scalar of a block region ends on its line: one that does not is
   `invalid_yaml` (a quoted scalar of a flow region may run over lines). A
   continuation line of a plain scalar that begins with a quote follows the
   same rule.

   A double-quoted scalar with an escape that the reader decodes to `<` is
   `yaml_alias`: `\x3c`, `\u003c` or `\U0000003c`, with the hex letter `c` in
   either case. The reader would decode the key `"\x3c\x3c"` to `<<`, and then
   name it with a counter, so two reads of one file would give two keys. The
   scan does not decide which scalar becomes a key, so the rule holds for a key
   and for a value, in block style and in flow style. Escapes are read from left
   to right: in `"\\x3c"` the first `\` escapes the second, and `x3c` is text, so
   it is accepted. A single-quoted scalar has no escapes. No other escape is
   decoded or refused.

The scan refuses some texts that are not aliases (a continuation line that
begins with `*` or with `? `, a `*` after `: ` in a trailing comment, `<<` in
quoted text or in a comment of a flow collection, a double-quoted scalar with an
escape that decodes to `<`). `&` and `*` in quoted text
of a flow collection are literal and are accepted. It does not refuse a
duplicate key below the top level, one in a flow-style top level, or two
double-quoted keys equal only after their escapes: the reader keeps the first
value. A skill frontmatter needs no complex key, so `?` as an explicit key is
refused; text that is not an alias or a key, such as `Use for *.xlsx files`,
`R&D`, `what?` or `?x`, passes.

## `sources/3`

`Elzoo.Skill.sources(id, package, descriptors)` takes `id` (1 to 32 bytes of
`[a-zA-Z0-9_-]`), a package that `RecipePackage.decode/1` gave and the tool
descriptors that the host gives. The package says only *which* tools a skill
brings (a list of identity texts); the descriptors are a host fact, as they are
for every other tool of a Run. It gives `{:ok, sources}`:

- first, the source `%{"id", "kind" => "pinned_skill", "callable" => "adapter",
  "tools" => [load_skill, read_skill_file]}`. The model sees the aliases
  `<id>_load_skill` and `<id>_read_skill_file`. The names of the skills (in the
  order of the package) and the line `name: description` of each skill are in the
  input schema of `load_skill`, which the registry does not cut. This source holds
  no `allowed-tools` text, no tool identity of a skill and no descriptor;
- then, for each skill at 1-based position `k` that declares at least one tool, in
  package order, one source `%{"id" => id <> "-" <> k, "kind" => "other",
  "callable" => "adapter", "tools" => []}`. It is empty at the start of a Run;
  the load of its skill fills it.

The first failing check is the result:

1. `id` is not 1 to 32 bytes of `[a-zA-Z0-9_-]`: `invalid_input`.
2. the package has no skill: `no_skills`.
3. `descriptors` is not a proper list of maps that are not structs:
   `invalid_input`.
4. the longest source id would pass the 32 bytes of the registry: `invalid_input`.
   A package whose skills declare no tool has no per-skill source, so only the
   rule of check 1 holds for it. With a skill that declares a tool at position 1
   to 9, `id` may have 30 bytes; at position 10 to 16, 29 bytes.
5. for each skill in package order and each declared identity in its order, the
   descriptors whose `"name"` equals the identity are counted: none is
   `undescribed_tool`, two or more are `invalid_input`. The first such identity
   decides.

A descriptor whose name no skill declares is ignored, so the host cannot add a
tool to a skill. One descriptor serves each skill that declares its name.
`sources/3` checks no other part of a descriptor: the registry checks the form
when a load lists it.

## `load/4`

`Elzoo.Skill.load(id, package, descriptors, arguments)`: `id` and `descriptors`
are those of `sources/3` and `arguments` is the `arguments` member of the call, a
map with exactly `"name"` (a binary). It keeps no state. Refusals in order:
checks 1, 3 and 4 of `sources/3` (`invalid_input`); `invalid_arguments`,
`unknown_skill` (a package with no skill is `unknown_skill`), `empty_body`; then
check 5 for the asked skill only, `undescribed_tool` or `invalid_input`: a
missing descriptor of another skill does not refuse this load. Otherwise the
payload of a completed outcome:

    %{"declaration" => %{"skill" => %{"name" => name, "instructions" => body},
                         "listing" => listing}}

`body` is the body of the package entry byte for byte: no frontmatter, no mark,
no cut. `listing` is `nil` for a skill that declares no tool. For a skill at
position `k` that declares tools it is `%{"source" => id <> "-" <> k, "tools" =>
tools}`, where `tools` is the one descriptor of each declared identity, in the
order of the `tools` of the skill, each as the host gave it.

`workflow/agent-loop` then applies the instructions and the listing in one step,
with no change of that Piece: the load refreshes the source of the skill, the
next model request lists the aliases of its tools (`<id>-<k>_<name>`, or the cut
form that the registry gives for a name outside its alias text), and a repeat
load is `already_loaded` before any refresh. A listing that would pass 64 tools in
all sources together (`load_skill` and `read_skill_file` included) is refused
whole with `too_many_tools`, and a descriptor that the registry refuses is
refused whole with its reason (for example `invalid_descriptor`); neither
instructions nor tools are added. A tool that two skills declare is listed in the
source of each skill and counts once for each loaded skill. The result of a listed
tool comes from a source of kind `other`, so it is never a declaration. The agent
loop does not check that a listing of a `pinned_skill` result targets a source of
that skill.

## `read_file/3`

`Elzoo.Skill.read_file(package, files, arguments)`: `files` maps a skill name to
the `files` value of `read/4` for that skill; `arguments` is a map with exactly
`"skill"` and `"path"` (binaries). Refusals in order: `invalid_arguments`,
`unknown_skill`, `unknown_file` (the path `SKILL.md`), `invalid_input` (`files`
is not a map, `files[skill]` is not a map, or the file is not a binary),
`unknown_file` (no such skill in `files` or no such path, exact bytes),
`file_too_large` (over 1,048,576 bytes, as in `read/4`). Otherwise the result of
`workflow/tool-result-limit`:

    %{"content" => marked, "media_type" => media_type, "encoding" => encoding}

Valid UTF-8 bytes give `text/plain`, `utf8` and the bytes; other bytes give
`application/octet-stream`, `base64` and `Base.encode64/1` of them. `marked` is
the neutral map of `workflow/untrusted-content` with the source `skill:<name>`,
trust `untrusted` and `max_bytes` of `max(1, byte_size(text))`. `SKILL.md` is
never read here: the body is an instruction, not marked content, and
`ToolResultLimit.decide/3` refuses it as `unmarked`.

## Needs and limits

Fixed bounds, not Config: 256 files, 1,048,576 bytes for a file, 8,388,608 bytes
for a folder, paths of 1 to 1,024 bytes and 16,384 bytes of frontmatter. The
bounds of the recipe package (16 skills, a body of 16,384 bytes, 32,768 in all)
and of the agent loop (16,384 bytes of loaded instructions, `already_loaded`, a
state of 65,536 bytes) are theirs and are not checked again.

Needs: a host that

- puts each entry of `read/4` into the recipe package and publishes only a
  package that `RecipePackage.decode/1` accepts;
- pins the package of a Run (`workflow/version-pin`) and gives `sources/3`,
  `load/4` and `read_file/3` that package and the files of the same version;
- gives the same descriptors to `sources/3` and to each `load/4`, and puts every
  source of `sources/3` into the source set of the Run at its start (a listing
  for a source that is not in the snapshot is `unknown_source`);
- stores the skill files (this Piece stores nothing);
- binds `{:adapter, id, "load_skill"}` to `load/4`,
  `{:adapter, id, "read_skill_file"}` to `read_file/3` and
  `{:adapter, id <> "-" <> k, name}` to the real Adapter of each listed tool, gives
  `{:ok, payload}`
  as a completed outcome under `elzoo.agent-loop.tool-result` version 1 and
  `{:error, reason}` as a `refused` outcome with the payload `{"reason":
  reason}`;
- keeps skill descriptions short enough for the state bound of the agent loop;
- leaves the `yamerl` parameter `node_mods` at `[]` and starts the `yamerl`
  application, which `yaml_elixir` starts.

Limits: trust is the host's pin of the package; a matching identity
authenticates nobody. The other files are not in the package identity. The
package says which tools a skill brings and the host says what each is; a tool of
a skill is an Adapter call, and a nested callable (a Lua tool, a graph) as a
skill tool is not part of this Piece. `allowed-tools` grants nothing, and a
listed tool still passes the engine checks at use. A declared identity outside
the registry name grammar can be described, but its load is refused by the
registry. Three sentences of RC-67 are met in part: the refusal of a tool that is
not permitted is at use, in the engine and the registry, and the test shows only a
recorded `refused` outcome of a listed tool; scripts are read and never executed,
but storing them is a host Need; a changed version does not change a running Run
through `workflow/version-pin` and the host's pin, shown here only by pure
functions over the given package; and the restart case is shown by folding the
agent loop again over a cut trace, not with the harness of RC-66. A file read is
not tied to a loaded skill. The media type is never guessed from the path. No
Markdown is parsed and no script is read as code, compiled, evaluated or run. The
test `scan_agrees_with_the_reader` calls the parser of the pinned `yamerl`
directly, in test files only, with an option that the pinned docs do not expand;
no file of `lib/` does, and the test opens with a positive control of that oracle.

Telemetry, Config and Control are not applicable: pure functions over intrinsic
operands and fixed bounds.

## Evidence

Eleven named test groups: ten in `test/elzoo/skill_test.exs`: `skill_md_split`,
`yaml_refusals`, `package_checks_fields`, `folder_bounds_and_paths`,
`pinned_skill_source`, `load_gives_declaration`, `file_read_is_marked_content`,
`scripts_never_run`, `agent_loop_accepts` and `pinned_version_answers`; the
eleventh, `scan_agrees_with_the_reader` in
`test/elzoo/skill_differential_test.exs`, feeds seeded random texts and every
short text to `read/4` and asks the token stream of the pinned parser about
each accepted text (no anchor, alias, other tag, key `<<` or explicit key),
and a fixed directed list of texts with the escapes that decode to `<`; and
the checked example `examples/skill.exs`. The cases of the listing are in the
same groups: `sources_literal_list`, `source_id_bound` and
`start_check_of_descriptors` in `pinned_skill_source`; `load_lists_declared_tools`
and `load_refusal_order` in `load_gives_declaration`; and in `agent_loop_accepts`,
folded over recorded traces, `skill_tools_listed_after_load`,
`repeat_load_adds_nothing`, `load_over_64_refused_whole`,
`two_skills_keep_their_tools`, `listed_tool_result_is_not_a_declaration`,
`declared_tool_refused_at_use` and `bad_descriptor_refused_whole`. Each of five
temporary edits that were reverted makes its test fail: a listing that names the
`pinned_skill` source instead of the source of the skill fails
`listed_tool_result_is_not_a_declaration`; a `load/4` that skips a declared tool
with no descriptor fails `load_refusal_order`; one shared source `<id>-1` for
every skill fails `two_skills_keep_their_tools`; a `sources/3` that skips check 5
fails `start_check_of_descriptors`; and a bound that checks only the 32 bytes of
`id` fails `source_id_bound`. They are finite scenarios and a finite sample, not a
universal proof; no Cure law is selected.
