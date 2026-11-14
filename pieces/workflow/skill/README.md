# workflow/skill

`Elzoo.Skill` is four pure functions over a skill folder that the caller gives
as data (the public Agent Skills format: a folder with `SKILL.md`, which holds
YAML frontmatter and a Markdown body, and other files): `read/4` reads the
folder, `source/2` gives the tool source of the skills of a checked package, and
`load/2` and `read_file/3` answer one call of each tool. Every refusal is
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
   `[`, `,`, `:` or the end of a tag, with spaces, tabs and line breaks
   between, or none) is `yaml_alias`; a `?` at a token start that a space, a
   tab or the line end follows is `invalid_yaml`, and it is checked before an
   alias of the same line. Quoted text (a quote opens only at a token start;
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

The scan refuses some texts that are not aliases (a continuation line that
begins with `*` or with `? `, a `*` after `: ` in a trailing comment, `<<` in
quoted text or in a comment of a flow collection). `&` and `*` in quoted text
of a flow collection are literal and are accepted. It does not refuse a
duplicate key below the top level, one in a flow-style top level, or two
double-quoted keys equal only after their escapes: the reader keeps the first
value. A skill frontmatter needs no complex key, so `?` as an explicit key is
refused; text that is not an alias or a key, such as `Use for *.xlsx files`,
`R&D`, `what?` or `?x`, passes.

## `source/2`

`Elzoo.Skill.source(id, package)` takes `id` (1 to 32 bytes of `[a-zA-Z0-9_-]`,
else `invalid_input`) and a package that `RecipePackage.decode/1` gave (no skill
is `no_skills`). It gives the source `%{"id", "kind" => "pinned_skill",
"callable" => "adapter", "tools" => [load_skill, read_skill_file]}`. The model
sees the aliases `<id>_load_skill` and `<id>_read_skill_file`. The names of the
skills (in the order of the package) and the line `name: description` of each
skill are in the input schema of `load_skill`, which the registry does not cut.
The source holds no `allowed-tools` text and no tool identity of a skill.

## `load/2`

`Elzoo.Skill.load(package, arguments)`: `arguments` is the `arguments` member of
the call, a map with exactly `"name"` (a binary). Refusals in order:
`invalid_arguments`, `unknown_skill`, `empty_body`. Otherwise the payload of a
completed outcome:

    %{"declaration" => %{"skill" => %{"name" => name, "instructions" => body},
                         "listing" => nil}}

`body` is the body of the package entry byte for byte: no frontmatter, no mark,
no cut. A load lists no tool, so `workflow/agent-loop` applies the instructions
and refuses nothing for a tool count.

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
- pins the package of a Run (`workflow/version-pin`) and gives `source/2`,
  `load/2` and `read_file/3` that package and the files of the same version;
- stores the skill files (this Piece stores nothing);
- binds `{:adapter, id, "load_skill"}` to `load/2` and
  `{:adapter, id, "read_skill_file"}` to `read_file/3`, gives `{:ok, payload}`
  as a completed outcome under `elzoo.agent-loop.tool-result` version 1 and
  `{:error, reason}` as a `refused` outcome with the payload `{"reason":
  reason}`;
- keeps skill descriptions short enough for the state bound of the agent loop;
- leaves the `yamerl` parameter `node_mods` at `[]` and starts the `yamerl`
  application, which `yaml_elixir` starts.

Limits: trust is the host's pin of the package; a matching identity
authenticates nobody. The other files are not in the package identity. A load
lists no tool: `allowed-tools` grants nothing and the declared `tools` of a
skill are package declarations only. RC-67 "a load that would pass 64 tools
gives the instructions and the named refusal" is not met, and four sentences
are met in part: the refusal of a tool that is not permitted is at use, in the
engine and the registry; scripts are read and never executed, but storing them
is a host Need; a changed version does not change a running Run through
`workflow/version-pin` and the host's pin, shown here only by pure functions
over the given package; and the restart case is shown by folding the agent loop
again over a cut trace, not with the harness of RC-66. A file read is not tied
to a loaded skill. The media type is never guessed from the path. No Markdown is
parsed and no script is read as code, compiled, evaluated or run.

Telemetry, Config and Control are not applicable: pure functions over intrinsic
operands and fixed bounds.

## Evidence

Ten named test groups in `test/elzoo/skill_test.exs`: `skill_md_split`,
`yaml_refusals`, `package_checks_fields`, `folder_bounds_and_paths`,
`pinned_skill_source`, `load_gives_declaration`, `file_read_is_marked_content`,
`scripts_never_run`, `agent_loop_accepts` and `pinned_version_answers`, and the
checked example `examples/skill.exs`. They are finite scenarios, not a universal
proof; no Cure law is selected.
