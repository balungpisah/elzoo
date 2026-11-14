# ELZ-176 — Pin and exercise a YAML reader for skill frontmatter

## Scope and reuse

- Dependencies: ELZ-033
- Output: none; non-Piece provider prerequisite for RC-67 (`workflow/skill`), release V1B.
- Change class: non-Piece root dependency; full local and hosted check.
- Owned paths: `mix.exs`, `mix.lock`, `registry/providers.json`, `docs/dependencies.md`, `test/elz176_yaml_provider_test.exs`.

Owner decision, 2026-11-14: where a maintained library does the work, adopt
it as a dependency of the Pieces that need it; do not write a reader by hand.
RC-67 must read the YAML frontmatter of a `SKILL.md` file, and no YAML reader
is among the providers. This task adopts one and shows, on the pinned
version, the behaviour that RC-67 will rely on. It builds no Piece and no
public Elzoo API.

Implement only the acceptance groups below. Add no wrapper module, no skill
reader, no Mix task, no CI edit and no change of `runs-on`. Preserve every
existing pin. No index or generated-file edit belongs to this task.

Facts checked on 2026-11-14:

- `mix.exs` pins each Hex dependency exactly, for example
  `{:crontab, "== 1.2.1"}`. `registry/providers.json` records a Hex provider
  as `"source": "hex"`, `package`, `version`, `reference`, `license`, and
  `lib/elzoo/registry.ex` compares the version with the `mix.lock` entry.
- No dependency of `mix.exs`, no entry of `mix.lock` and no provider of
  `registry/providers.json` reads YAML.
- On hex.pm the latest stable `yaml_elixir` is 2.12.2 (MIT, released
  2026-05-30); it requires `yamerl ~> 0.10`. The latest stable `yamerl` is
  0.10.0 (BSD 2-Clause). `yamerl` is an OTP application that `yaml_elixir`
  starts.

## The adoption

Add exactly these two dependencies, both pinned:

```elixir
{:yaml_elixir, "== 2.12.2"},
{:yamerl, "== 0.10.0"}
```

`yamerl` is named and pinned although it is transitive, because it is the
parser: its version decides what a document means. Add the provider IDs
`yaml_elixir` and `yamerl` to `registry/providers.json` in the existing Hex
shape, with the license of each and a `reference` to its versioned
documentation or source tree. Add one adoption entry to
`docs/dependencies.md` for the pair: the API that is exercised, the failure
path, the licenses and the limits below. If the resolver cannot take these
exact versions with the existing pins, stop and report the conflict; change
no existing pin.

## What the adoption check shows

One root ExUnit file, `test/elz176_yaml_provider_test.exs`, with literal
documents in the test. It records the behaviour of the pinned versions; where
a line below says "record", the test asserts the result that the pinned
version gives and the dependency entry states it, whatever it is. RC-67 is
then written from these facts.

1. **`plain_frontmatter`**: `YamlElixir.read_from_string/2` on a document
   with string scalars (plain, single-quoted, double-quoted), a literal block
   scalar (`|`), a folded block scalar (`>`) and one nested map of string
   pairs gives `{:ok, map}` with string keys and string values; the two block
   scalars give the expected text with their line ends. Record the options
   that the call needs for string keys.
2. **`typed_scalars_are_visible`**: record what the reader gives for the
   plain scalars `true`, `no`, `on`, `null`, `~`, `12`, `1.5`, `0x10`,
   `2026-11-14` and an empty value, and for each of them in quotes. The
   skill reader must tell a string from a value that YAML typed, so the test
   fixes the exact terms.
3. **`aliases_and_merges`**: a document with an anchor and an alias, with a
   merge key (`<<:`) and with a nested alias chain of depth 6 ("billion
   laughs" form, small): record for each whether the reader expands it,
   refuses it or keeps a marker, and whether an option makes an alias an
   error or leaves it detectable in the result. If no option and no result
   form lets a caller refuse aliases, say so plainly in the entry: RC-67 then
   refuses a frontmatter that holds `&`, `*` or `<<` outside a quoted scalar
   before it calls the reader.
4. **`not_one_plain_map`**: a document that is a list, a scalar, empty, or
   two documents in one string; a duplicate key; a tab indentation; invalid
   UTF-8; a tag (`!!binary`, `!ruby/object`): record the result of each
   (`{:ok, _}` with which term, or `{:error, _}` with which struct), and that
   no input raises out of `read_from_string/2` or kills the caller.
5. **`no_atoms_no_code`**: reading 2,000 documents whose keys are 2,000
   distinct new strings does not grow the atom count (compare
   `:erlang.system_info(:atom_count)` before and after, with the option set
   that group 1 fixed); no document makes the reader call a function named in
   the document.
6. **`bounded_time`**: a frontmatter of 16,384 bytes and one of 1,048,576
   bytes of nested plain maps each parse inside a `Task` with a limit of 5
   seconds; record the measured times in the pull request body. A document
   that does not end inside the limit is a finding to report, not a test to
   loosen.
7. **`hosted_check_runs_it`**: the file runs, without skip, in the exact-head
   full hosted check.

## Host Needs and Limits

Needs: Hex access during `mix setup`; the pinned toolchain; the normal
disposable services of the full check. `yamerl` runs as an OTP application
that `yaml_elixir` starts; record whether a copied consumer must start it.

Limits: this task shows finite behaviour of two pinned versions on literal
documents. It is not a claim that the reader is safe for hostile input of
any size, and it adopts no YAML writer. Telemetry, Config and Control are not
applicable: no Piece and no running service of Elzoo.

## Evidence and gate

Test: the seven groups. Upstream: the two libraries at the pinned versions;
quote in `docs/dependencies.md` the documented contract of each call that
the test uses. Record assumptions and test results separately.

Because `mix.exs` and `mix.lock` change, run `mix setup` and then `mix check`
with no flag (the full check; take the one full-check turn of the host from
the coordinator first), then `git diff --check`. The hosted check is the full
check. One independent review checks the body and the exact diff, including
extra features.

## Not in scope

`workflow/skill`, a skill reader, a frontmatter grammar, Markdown, a YAML
writer, any Piece, and any change of an existing pin.
