# ELZ-194 — An escape that decodes to `<` in a double-quoted scalar of a skill frontmatter is refused

- Dependencies: ELZ-182
- Output: none. A repair of the ready Piece `workflow/skill`; the scan refuses one more kind of text, the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/workflow/skill/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row, because `piece.json` changes).

The automated review of pull request #419 found that the frontmatter scan
compares the raw text of a double-quoted key with `<<`, while the pinned
reader decodes the escapes first. The key `"\x3c\x3c"` passes the scan,
the reader decodes it to `<<`, and `yaml_elixir` then renames a `<<` key
with a counter. Two reads of the same folder give two different keys, and
under `metadata` such a key reaches the identity of the recipe package.

Facts checked on `main` (lines of `lib/elzoo/skill.ex` at the time of
writing; confirm each when you start, and if one differs, stop and ask):

- `scan_quoted/4` (about 562 to 589): for a double quote the key is
  `inner`, the raw text between the quotes. No escape is decoded.
  `key_value("<<", ...)` (about 618) compares that raw text and gives
  `{:error, :yaml_alias}`. This is the reason that a merge key gets today
  (test 2.7 of `yaml_refusals` covers `<<`, `{<<: x}` and `"<<"`).
- In a flow region `flow_line/2` (about 385 to 391) asks
  `String.contains?(line, "<<")`, also on the raw text, and `flow_bytes`
  steps over an escape pair of a double-quoted text (about 401) without
  reading it.
- Pinned yamerl 0.10.0 decodes `\xHH`, `\uHHHH` and `\UHHHHHHHH` in a
  double-quoted scalar (`yamerl_parser.erl`,
  `do_parse_flow_scalar_escaped`); an escape with a wrong digit is a
  warning and its text stays. Pinned yaml_elixir 2.12.2 gives a `<<` key
  the name `"<<"` plus a unique integer (`mapper.ex`, `key_for/2`).
  Confirm both in `deps/`.
- `Elzoo.RecipePackage` accepts each text key of 1 to 128 bytes under
  `metadata` (`pieces/domain/recipe-package/lib/elzoo/recipe_package.ex`,
  about 102 to 108).
- The README names the unstable `"<<N"` of the reader (about 61 to 62) and
  states a Limit only for two double-quoted keys that are equal after
  their escapes (about 106 to 109). `piece.json` has the same Limit
  (about line 19).
- The group `scan_agrees_with_the_reader`
  (`test/elzoo/skill_differential_test.exs`) cannot spell the case. Its
  alphabets (about 20 to 24) have `\`, `"` and `<` but no `x`, `u`, `U`,
  `3`, `0` or `c`, and a text has at most 24 random bytes. Its oracle does
  see the case: `findings/3` (about 76 to 83) compares the decoded text of
  a scalar after a mapping key with `<<`.

## The changed rule

In pass 3, wherever the scan reads a double-quoted scalar today (a node of
a block line, the text of a flow region, a continuation line that begins
with a double quote), the frontmatter is refused with the existing reason
`yaml_alias` when that scalar holds an escape that decodes to `<`:

    \x3c    \u003c    \U0000003c

with each hex letter in either case. The rule holds for a key and for a
value, in block style and in flow style: the scan does not decide which
scalar becomes a key, and it refuses more than YAML requires where it
cannot tell. Escapes are read from left to right, as the scan steps over
them today, so `\\x3c` (an escaped backslash and then the text `x3c`) is
not such an escape and is accepted. A single-quoted scalar, a plain scalar
and a block region have no escapes and are read as today. No escape is
decoded for any other purpose, and no other escape is refused.

Add no YAML reader, no general escape decoder, no option, no new reason
and no new public function. The check belongs to the two places that read
a double-quoted text today.

The Contract sentence of `piece.json` (`contract`) is unchanged. The
texts that change: the README section "The frontmatter scan" (the rule,
and the list of texts that are refused although they are not aliases),
the same Limit of `piece.json` (about line 18), the claim of the test
grounding that lists the cases of `yaml_refusals` and of
`scan_agrees_with_the_reader`, and the upstream claim on yamerl, which
now also relies on the three escape forms. `piece.json` changes, so the
`manifest_sha256` of the index row follows in the last commit before the
pull request is opened (in-place change of a ready Piece, same Piece ID;
Elzoo is not released).

## Named acceptance groups

1. **`escaped_merge_key_is_refused`** (new cases of `yaml_refusals`):
   each of the six spellings `\x3c`, `\x3C`, `\u003c`, `\u003C`,
   `\U0000003c`, `\U0000003C`, twice in one scalar and mixed with a
   literal `<` (`"<\x3c"`, `"\x3c<"`), is `{:error, :yaml_alias}` as a
   top-level key, as a nested key, as a key after `- `, as a key of a flow
   mapping, as an entry of a flow sequence, as a key on a later line of a
   flow region, and as a value.
2. **`same_refusal_twice`**: two calls of `read/4` on the folder of the
   finding (`"\x3c\x3c": x` under `metadata`) give the same refusal.
3. **`ordinary_escapes_are_accepted`**: `"a\tb": x`, `"\x41": x`,
   `"\u00e9": x` and `"\\x3c\\x3c": x` are read, and the frontmatter of
   the entry holds the key that the pinned reader gives; the same texts in
   a flow mapping are read.
4. **`scan_agrees_with_the_reader`** gets a directed part beside the
   random and the exhaustive parts. It is a fixed list, built from
   templates and not from random bytes: each spelling of group 1, each
   pair of two spellings, and each ordinary escape of group 3, put into
   each of these templates: `"S": x`, `k:\n  "S": x`, `- "S": x`,
   `k: {"S": x}`, `{"S": x}`, `k: ["S"]`, `k: {a: b,\n  "S": x}` and
   `k: "S"`. For each text the existing `disagreement/1` must give `nil`
   when `read/4` accepts it. A positive control comes first: for each
   template with a key `S` that decodes to `<<`, the oracle reports
   `merge_key`; a failure of the control fails the test. The directed part
   runs in the default run and in the full run. Record the count of
   directed texts and how many were accepted.
5. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged, the full differential run included
   (`ELZOO_SCAN_DIFFERENTIAL=full`); record its counts.

Negative control, by a temporary edit that is reverted: with the new check
removed, group 1 fails, the directed part of group 4 reports a
disagreement with `merge_key`, and the two reads of group 2 give two
entries with different keys. Record the three failures.

Run `mix test pieces/workflow/skill/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (untrusted text,
identity of stored packages).

## Not in scope

Two double-quoted keys that are equal only after their escapes (a stated
Limit), an escape that decodes to `&`, `*`, `!` or `?` (the reader does
not read an indicator from a decoded scalar; if you find a case where it
does, report it on the issue and do not repair it here),
`domain/recipe-package`, the YAML reader and its pin, and any other
Piece.
