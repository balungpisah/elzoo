# workflow/skill

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
| 8 | `invalid_yaml` | a CR is left after each CR LF became LF |
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

## Needs and limits

Fixed bounds, not Config: 256 files, 1,048,576 bytes for a file, 8,388,608 bytes
for a folder, paths of 1 to 1,024 bytes and 16,384 bytes of frontmatter. Needs: a
host that puts each entry into the recipe package and publishes only a package
that `RecipePackage.decode/1` accepts; stores the skill files; leaves the
`yamerl` parameter `node_mods` at `[]`; and starts the `yamerl` application,
which `yaml_elixir` starts. No Markdown is parsed and no script is run.

Telemetry, Config and Control are not applicable: pure functions over intrinsic
operands and fixed bounds.

## Evidence

The named test groups are `skill_md_split` and `folder_bounds_and_paths`, with
literal folders in `test/elzoo/skill_test.exs`. They are finite scenarios, not a
universal proof.
