# ELZ-174 — The Lua sandbox gets the safe helper set as policy version 2

## Scope and reuse

- Dependencies: ELZ-033, ELZ-163
- Output: none. This task changes the ready Piece `runtime/lua-sandbox` in place; the Piece ID stays. It completes RC-60.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/runtime/lua-sandbox/**`; in the one last commit the index and generated files of AGENTS.md section 3, and with them the removal of the planned ID `runtime/lua-stdlib` (below); `docs/plans/bot-platform.md` for the two lines named below.

Owner decision, 2026-11-14: the helper set is part of `runtime/lua-sandbox`
and is not a second Piece. Before the first release a ready Piece is extended
in place (AGENTS.md section 4). This replaces "option A" of the same day,
which made `runtime/lua-stdlib` a separate Piece. The host stays one C file
with one capability list, one Port owner and one policy identity.

Facts checked on main (`pieces/runtime/lua-sandbox`):

- `lib/elzoo/lua_sandbox/native/lua_sandbox_host.c` is the one host source.
  `init_env` builds a fresh environment with the libraries `string`, `table`
  and `math`; a missing name ends in `unlisted` and the refusal
  `unlisted_name`. `charge(L, n)` adds `n` to the step count and stops at the
  limit. `set_sticky` with `stop_raise` makes a stop that no `pcall` catches;
  `luaL_error` makes an ordinary error. The host already holds a JSON reader
  and writer for the request and the reply; they work on static arenas and
  are not callable from Lua.
- Inside Lua, JSON `null` is one light userdata, and a table that came from a
  JSON object is marked in a weak table, so an empty object and an empty
  array stay distinct. A source of policy version 1 cannot make `null` or a
  fresh empty object (README, Limits).
- `Descriptor.descriptor/0` holds `"policy_version" => 1`, `"helpers" => []`
  and `"bindings" => %{}`; the identity is `policy-v1:sha256:` plus the
  SHA-256 of its canonical JSON, with the prefix as a literal. `run/2`
  refuses every other identity as `policy_mismatch`.
- The capability lists exist in the C host, in `Descriptor` and in the tests.
  The `--audit` mode of the host gives the surface of the host, and the tests
  compare it with the descriptor and with fixed-name probes.
- A library table is an ordinary fresh table of one run with a strict lookup
  for missing names. A source can assign a field of it; the state of a run
  is not kept, so the next run is not changed.

Implement only what is below. Add no module binding, no callback to the
caller, no clock, no random source, no Unicode tables, no second host file,
no build option and no way to choose a policy at run time. Edit no other
Piece, shared path, pin or CI file. No fixtures directory is needed.

## Policy version 2

The Piece has one policy, version 2. Its descriptor has
`"policy_version" => 2`, and `"helpers"` is the list of exactly
`{"name": name, "version": 1}` for each helper below, sorted by name, where
`name` is the field name without `helpers.`, for example `"json_encode"`. The identity is
`policy-v2:sha256:` plus the SHA-256 of the canonical JSON of the descriptor.
A request with a `policy-v1:` identity, or any other, is `policy_mismatch`
before any source runs, as today. Everything else of version 1 is unchanged:
the names, the wrappers, the limits, the framing, the refusals and the host
outcomes.

A source reaches the helpers as fields of the global `helpers`: a fresh
table with the same strict lookup as the libraries, so `helpers.x` for a name
that is not listed is `unlisted_name`. As for a library table, a source can
assign a field of `helpers` in its own run, also a listed one; that changes
only that run, and the next run has every helper again. The bare names `json`, `text`, `time`,
`clock`, `now` and `helper_echo` stay `unlisted_name`.

Every helper is a C function of the host. It takes plain values and gives
plain values. It reads no clock, no environment and no file. It charges
steps for its work with `charge`: one step for each byte of text that it
reads, one for each byte of text that it gives back, and one for each table
entry that it visits or makes. A helper that reads and writes text charges
both. A limit that it reaches
(`steps`, `value_bytes`, `memory_bytes`) is a sticky stop with the existing
refusal or host outcome. Wrong arguments and bad data are an ordinary Lua
error with a fixed message that holds no data; a source can catch it with
`pcall`, and uncaught it is `lua_error`.

| Helper | Arguments and result |
| --- | --- |
| `helpers.null` | A constant: the JSON null of the host. It is not `nil`. |
| `helpers.object()` | A fresh empty table that encodes as a JSON object. |
| `helpers.json_encode(value)` | The canonical JSON text of a plain value, by the rules of a result (sorted keys, dense arrays, `null`, finite numbers, depth 32). A value that a result refuses (a function, a cycle, mixed keys, a hole, a non-finite number, depth 33) is an error. A text over `value_bytes` is the `value_size` stop. |
| `helpers.json_decode(text)` | The plain value of one JSON document, by the rules of an input (duplicate keys, trailing bytes, invalid UTF-8 and depth 33 are errors). `null` gives `helpers.null`; an object gives a table marked as an object. |
| `helpers.text_trim(text)` | The text without leading and trailing ASCII space, tab, line feed, carriage return, form feed and vertical tab. |
| `helpers.text_split(text, separator)` | A dense array of the parts of `text` between occurrences of the plain, non-empty `separator`, in order; `n` occurrences give `n + 1` parts, and empty parts are kept. An empty separator is an error. |
| `helpers.text_utf8_len(text)` | The number of code points of valid UTF-8 text. Invalid UTF-8 (also an overlong form, a surrogate, a value above U+10FFFF) is an error. |
| `helpers.time_parts(unix_ms)` | For an integer of milliseconds since 1970-01-01T00:00:00Z from 0 to 253402300799999: a table marked as an object with the integers `year`, `month`, `day`, `hour`, `minute`, `second`, `millisecond` and `weekday` (1 for Monday to 7 for Sunday), in UTC, proleptic Gregorian. Another argument is an error. |
| `helpers.time_unix_ms(parts)` | The inverse for a table with `year` (1970 to 9999), `month`, `day`, `hour`, `minute`, `second` and `millisecond` as integers of a real date and time; `weekday` and any other field are not read. A missing or wrong field of the seven is an error. |
| `helpers.time_iso8601(unix_ms)` | The text `YYYY-MM-DDTHH:MM:SS.mmmZ` for the same range. |

Time is a value that the caller puts in the input. No helper gives the
current time.

The JSON helpers use the reader and the writer rules of the host, so
`json_decode(json_encode(v))` gives a value that encodes to the same text.
Write them so that they do not share the static arenas of the request and
the reply in a way that a call from Lua can corrupt; how is the worker's
choice, and the tests of group 3 below show it.

No Unicode normalization and no case mapping beyond the ASCII rules of
`string.lower` and `string.upper`: they need Unicode data tables. The README
states this as a Limit.

## Index files and the planned ID `runtime/lua-stdlib`

In the one last commit, beside the usual step 3 for `runtime/lua-sandbox`
(the new `manifest_sha256` and `note`):

- `registry/catalogue.json`: remove the row `runtime/lua-stdlib`. In the row
  `runtime/lua-sandbox` replace the `reason` by one that says what the Piece
  is now: reference PUC Lua 5.4.9 outside the VM over a Port, hard limits,
  the capability policy version 2 with the safe helper set.
- `docs/plans/release-plan.json`: remove the `entries` row
  `runtime/lua-stdlib`; in the job RC-60 make `outputs` and `paths` empty
  and set its `status` to "all portions
  published: ELZ-163 sandbox and ELZ-174 helper set, inside
  runtime/lua-sandbox". Change no other job.
- In that same RC-60 job replace the `blockers` list by one line: the two
  portions are published and merged, and the helper set is part of
  `runtime/lua-sandbox`. Leave its `contract`, `acceptance` and `reuse` as
  they are: they are the record of the proposal.
- `docs/plans/bot-platform.md`: in the Wave 3 table, the RC-60 row names
  only `runtime/lua-sandbox`. The decision line is already there.
- Then `mix elzoo.ledger`, `python3 scripts/check-roadmap.py --write` and
  `python3 scripts/check-roadmap.py`. If one of them refuses the removal of
  the ID, stop and ask the coordinator; do not keep a placeholder row.

## Named acceptance groups

Keep every existing group green. An assertion that fixes policy version 1
(the identity prefix, `helpers == []`, a helper name that is refused, the
audit lists) changes to version 2; name each such change in the pull request
body.

1. **`policy_v2_identity`**: the descriptor names version 2 and the ten
   helpers; the identity has the prefix `policy-v2:sha256:` and equals the
   digest of the descriptor; a `policy-v1:` identity and an identity with
   one helper removed are `policy_mismatch`; the audit of the host, the
   descriptor and the fixed-name probes agree on the helper names, and a
   negative control that grants one more helper fails the audit.
2. **`helpers_surface`**: each listed helper is reachable; `helpers.x`,
   `helpers.json`, `json`, `text`, `time`, `clock`, `now` and `helper_echo`
   are `unlisted_name`; a source that assigns `helpers.json_encode` and a new
   field sees them in that run, and the next run has the helpers of the
   policy and no new field; the `helpers` table has no reachable metatable,
   and `tostring` of a helper function is the `lua_error` of version 1.
3. **`json_round_trip`**: each scalar type, `null`, an empty array, an empty
   object, nested containers at depth 32; depth 33, a function, a cycle,
   mixed keys, a hole and a non-finite number are errors that `pcall`
   catches (the helpers refuse 33 nested containers in both directions,
   whatever the reader of the request does); duplicate keys, trailing bytes and invalid UTF-8 in a decode are
   errors; a decode inside the function of a request whose input holds the
   same document leaves the input unchanged; 1,000 encode and decode calls
   in one run give equal results.
4. **`helpers_are_bounded`**: an encode whose text is over `value_bytes`, a
   split of a text of 65,536 separator bytes under a `steps` limit of
   10,000, a decode of a document near the bound in a loop: each ends in the named sticky stop (`value_size`, `steps` or the
   `memory` host outcome), a `pcall` around it does not continue, and the
   step count of one helper call grows with its input size.
5. **`text_helpers`**: trim of each ASCII space character and of none;
   split with a separator at the start, at the end, doubled, absent and
   empty; the code-point count of ASCII, two-, three- and four-byte
   characters; each invalid UTF-8 form is an error.
6. **`time_values`**: `time_parts` and `time_unix_ms` for 0, the last
   millisecond of 1999, 2000-02-29, 2100-02-28 and its next day, the largest
   value; they are inverse for 10,000 values spread over the range; each
   value outside the range, a fraction, a missing field and an unreal date
   (month 13, 30 February) is an error; the weekday of five known dates;
   the ISO text of three values; no helper result changes between two runs
   one second apart.
7. **`replay_and_survival_with_helpers`**: the cases of the existing replay
   group with a source that uses each helper: 20 fresh calls and two fresh
   BEAM processes give equal values or the same refusal; after each adverse
   case the owning BEAM is alive, the child is reaped and a next valid call
   succeeds.

## Evidence and gate

Test: the seven groups and the unchanged suite, as finite real-process
tests. The README and `piece.json` name the groups, the helpers with their
versions, and the Limits (no normalization, no clock, the private-layout
coupling that the Piece already states). Negative controls: temporarily let
a helper skip `charge` (group 4 must fail), then temporarily grant one more
helper name (group 1 must fail). Restore both before the final gate.

Run `mix test pieces/runtime/lua-sandbox/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.
The copied consumer of the small gate must finish within its existing 300
seconds; if it does not, stop and report the measured time to the
coordinator. One independent review checks the body and the exact diff,
including extra features.

## Not in scope

Module bindings and `bindings.<name>` (RC-62), a callback to the caller, an
extension point for other Pieces, a second policy in one build, Unicode
normalization, locale, time zones, formatting of durations, pooling, and
any change of `lua_source` or its pin.
