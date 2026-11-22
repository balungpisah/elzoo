# ELZ-329 — Check a model's cited answer against the exact items it was given

- Phase: Wave 7 Level 1
- Dependencies: ELZ-033, ELZ-030, ELZ-115
- Release: V1B
- Output: new `workflow/citation` Piece
- Change class: Piece-only
- Owned paths: `pieces/workflow/citation/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (including `workflow/typed-decision`, `workflow/context-selection` and `integration/search-data`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One small pure Piece in plain Elixir: a model's cited answer is checked against the exact items that were given to the model, and each quote is resolved to the item's source, version and byte range. The Contract source is the `workflow/citation` section of [the Wave 7 plan](../docs/plans/bot-platform-wave7.md) ("Level 1"). No I/O, clock, process, storage, model call, retrieval or Unicode normalization. The rules are exact byte comparisons, one byte search (OTP `:binary.match/2`) and counts; no Cure law is claimed.

The answer is model output, which is untrusted input. So this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"; `AGENTS.md` sections 5 and 6); the hosted `check-piece` run does not replace the local run.

The Piece checks that the quoted text is in the cited item. It does not check that the answer is true, that a quote supports the sentence around it, or that the host's item metadata is right (rule 8 of [bot-platform.md](../docs/plans/bot-platform.md): a citation is evidence of where the text came from, not of truth).

## Interface

- `Elzoo.Citation.schema()` returns the decoded JSON Schema object (string keys) of a cited answer, version 1, for `workflow/typed-decision` to ask for as `answer: {:schema, Elzoo.Citation.schema()}`; `Elzoo.PayloadSchema.build/2` (ELZ-115) accepts it with any output Port. It is exactly this value, and the README names `elzoo.citation.answer` version 1 as the schema identity of the host's output Port:

  ```json
  {"type": "object",
   "properties": {
     "text": {"type": "string", "maxLength": 65536},
     "citations": {"type": "array", "maxItems": 32,
       "items": {"type": "object",
         "properties": {
           "item_id": {"type": "string", "minLength": 1, "maxLength": 1024},
           "quote": {"type": "string", "minLength": 1, "maxLength": 1024}},
         "required": ["item_id", "quote"],
         "additionalProperties": false}}},
   "required": ["text", "citations"],
   "additionalProperties": false}
  ```

  `maxLength` counts characters, not bytes, so the schema never refuses an answer that `check/3` accepts; the byte bounds below are `check/3`'s.
- `Elzoo.Citation.check(answer, items, policy)` returns `{:ok, %{citations: resolved}}` or `{:error, reason}`, with `reason` one of the atoms below. It never raises, for any term in any argument.
  - `answer` is one decoded answer, the `value` that `workflow/typed-decision` gives in a `decided` finish: a map with exactly the string keys `"text"` and `"citations"`; `"text"` a valid UTF-8 binary of 0..65,536 bytes; `"citations"` a proper list whose every element is a map with exactly the string keys `"item_id"` and `"quote"`, `"item_id"` a valid UTF-8 binary of 1..1,024 bytes and `"quote"` a valid UTF-8 binary of 1..1,024 bytes.
  - `items` is a proper list of 0..256 items, the items that were given to the model. An item is a map with exactly the atom keys `item_id`, `source`, `version` and `content`, plus the optional key `start_byte` when the item is a chunk of a larger source. `item_id` and `source`: valid UTF-8 binaries of 1..1,024 bytes (the `workflow/context-selection` ID bound), `item_id` unique in the list by exact bytes. `version`: an integer 1..2^31−1. `content`: a binary of at most 1,048,576 bytes, at most 8,388,608 bytes over all items (the context-selection content bounds), and exactly the bytes that the model was shown as that item's content (for a `workflow/untrusted-content` marked value, its content, not the rendered block with its tag lines). `start_byte`: an integer ≥ 0 with `start_byte + byte_size(content) <= 2^53−1`. A `workflow/context-selection` candidate has no `start_byte` key, so the host takes it from the `integration/search-data` candidate with the same `item_id`.
  - `policy` is a map with exactly the atom key `min_citations`, an integer 0..32.
  - `resolved` has one entry for each citation, in the answer's order: `%{item_id, source, version, start_byte, end_byte}`, with `item_id`, `source` and `version` those of the cited item. Let `p` be the byte position of the first occurrence of the quote in the item's content (the lowest position at which the quote's bytes occur). Then `start_byte` is `s + p` and `end_byte` is `s + p + byte_size(quote)`, where `s` is the item's `start_byte`, or 0 when the item has none. `end_byte` is exclusive, as in `integration/text-chunking` and `integration/search-data`: the quote is `binary_part(source_text, start_byte, end_byte - start_byte)`.

For an item that is a chunk of an ingested document, the source is the parsed text of that version (the text whose SHA-256 a later `assembly/knowledge-ingest` records with the parser identity), not the uploaded bytes.

## Rules

`check/3` checks, in this order, and returns the first failure:

1. `items` and `policy` against the shapes and bounds above: `{:error, :invalid}` (host input, checked before the model's answer; coordinator decision, since the plan's sketch names no reason for a bad host input).
2. The answer's shape and bounds above, over the whole answer: `{:error, :malformed}`.
3. More than 32 citations: `{:error, :too_many}`.
4. Two citations with equal `"item_id"` and equal `"quote"` bytes: `{:error, :duplicate}`. One quote cited from two items, or two quotes from one item, is not a duplicate.
5. A citation whose `"item_id"` equals no item's `item_id` by exact bytes: `{:error, :unknown_item}`.
6. A citation whose `"quote"` bytes do not occur in its item's `content`: `{:error, :quote_not_found}`. There is no normalization, case folding or whitespace change: a quote that differs only by Unicode normalization (NFC against NFD) is not found.
7. Fewer citations than `min_citations`: `{:error, :uncited}`.

Errors are `{:error, reason}` with a bare fixed atom that never echoes an ID, a quote, a text or content, and never names which citation failed. `"text"` is not read beyond its shape: the Piece does not check that the text and the citations agree.

**Kept open (owner's "no corner" rule).** Each option below can be added in place before the first release without breaking a caller, because it is reached only through a key that an existing caller does not pass:

- *Inline markers in `text` as a citation key:* an optional citation key (for example `"marker"`) that `check/3` accepts only when an added policy member asks for it. Until then an unknown citation key is `:malformed`, as the schema's `additionalProperties: false` says, so every version 1 answer checks as before; `schema/0` keeps giving its version 1 value, and a later `schema/1` can give the marked version.
- *A map from parsed-text offsets back to the uploaded bytes:* an optional item key that names the parser's offset map, and an optional key of a resolved entry for the original byte range; an item without it resolves as now.
- *Quotes that span two items:* an optional policy member that lets one quote run across adjacent chunk items of one source and version; without it a quote lies inside one item's content.
- *A near-match mode:* an optional policy member `match` whose default is the exact match of this task; a near match reports its kind in an added key of the resolved entry.

The policy, item and resolved-entry maps may gain optional keys and the error set may gain members in a later in-place version under these rules; the result of every input that is valid now stays equal, and a caller matches on the keys and members it uses.

`piece.json` declares telemetry, config and control `not_applicable` (a pure Piece with fixed bounds). The library code depends on no Piece. `core/payload-schema` (and its closure) is used only by the tests; declare it in `piece.json` so the copied consumer can run them, and say in the README that the library code does not call it. The README shows the composition: `workflow/context-selection` selects the items, the host adds `start_byte` from the search-data candidates, `workflow/typed-decision` asks for an answer of `schema/0`, and `check/3` checks the decided value; a refused answer is not shown as cited.

## Acceptance

Expected offsets in the tests are written out by hand, not computed with the Piece's code.

1. Schema: `schema/0` equals the object above, written out in the test; `Elzoo.PayloadSchema.build/2` accepts it for an output Port; a well-formed answer passes `Elzoo.PayloadSchema.check/3`, and an answer with an extra top-level key, an extra citation key, a missing `"text"`, an empty quote or 33 citations gets `{:error, {:violations, _}}`. A quote of 1,024 bytes of four-byte characters (256 characters), cited from an item that holds it, passes the schema and `check/3`; a quote of 300 four-byte characters (1,200 bytes) passes the schema and is `:malformed` in `check/3`.
2. Every rule at its edge (with `min_citations` 0): 0, 1 and 32 citations are accepted and 33 are `:too_many`; a quote of 1 and of 1,024 bytes is accepted, and of 0 bytes, 1,025 bytes or invalid UTF-8 is `:malformed`; an `"item_id"` of 1,025 bytes is `:malformed`; `"text"` of 0 and 65,536 bytes is accepted and of 65,537 bytes is `:malformed`; an `"item_id"` that differs from a given item's only by case or by one trailing space is `:unknown_item`; a fabricated quote (text in no item) is `:quote_not_found`, and the same text quoted from the item that holds it is accepted; a quote that occurs in another given item but not in the cited one is `:quote_not_found`; a repeated pair is `:duplicate`, while one quote from two items and two quotes from one item are accepted.
3. Unicode: an item whose content holds "é" as U+00E9 (NFC) and a quote with "e" followed by U+0301 (NFD) is `:quote_not_found`, and the NFC quote is found. Multi-byte offsets: content `"héllo wörld"` (NFC, 13 bytes) and quote `"wörld"` resolve to `start_byte` 7 and `end_byte` 13 in an item without `start_byte`.
4. First occurrence: content `"abcabc"` and quote `"bc"` resolve to 1 and 3; content `"aaaa"` and quote `"aa"` resolve to 0 and 2.
5. Source offsets: the `"héllo wörld"` item with `start_byte` 100 resolves `"wörld"` to 107 and 113; an item with `start_byte` 0 gives the same offsets as one without the key; each resolved entry carries the cited item's `source` and `version`.
6. `min_citations` at its boundary: with 2, an answer of 2 citations is accepted and of 1 is `:uncited`; with 0, an answer of no citations is accepted; with 32, 32 citations are accepted; a policy of −1, 33, a non-integer or an extra key is `:invalid`.
7. Errors in the fixed order, each input with two faults: bad items with a malformed answer is `:invalid`; a malformed citation among 33 is `:malformed`; 33 citations with a repeated pair is `:too_many`; a repeated pair of an unknown item is `:duplicate`; an unknown item and, in an earlier citation, a quote that is not found is `:unknown_item`; with `min_citations` 2, one citation whose quote is not found is `:quote_not_found`.
8. Host input: 0 items with no citations is accepted; 257 items, a repeated `item_id`, an `item_id` or `source` of 0 or 1,025 bytes, a `version` of 0 or 2^31, a `start_byte` of −1, a `start_byte` with `start_byte + byte_size(content)` above 2^53−1, an unknown item key, a content of 1,048,577 bytes, and nine items of 1,048,576 bytes (eight are accepted) are each `:invalid`.
9. Untrusted terms: an answer that is a list, a tuple, a map with atom keys, an improper citation list, a citation that is not a map, and a non-binary `"quote"` are each `:malformed`, and `check/3` raises for none of them; no error result holds a byte of the answer or the items.
10. The checked example `examples/citation.exs`: two items, one a chunk with `start_byte`, an accepted answer and a refused fabricated quote.
11. Negative control, restored before the final gates: skip the substring check (accept any quote of a known item), and the fabricated-quote case of group 2 must fail.

Run the Piece tests and the new-Piece small gate locally (`mix check --piece "$(git merge-base origin/main HEAD)"`; the answer is untrusted input, so the hosted `check-piece` run does not replace it), the roadmap and claims checks and the diff check. The full independent review of the coordinator guide ("Reviewer by risk": it finds the code and a test for each rule above), the exact-head hosted check and the merge queue are required.

## Limits to state

A citation shows that the quoted bytes are in the content of the cited item, not that the answer is true or that the quote supports it. The item's `item_id`, `source`, `version`, `start_byte` and content are host-vouched: the Piece does not check them against a store, a digest or the source text. Offsets of an ingested document are in its parsed text, not in the uploaded bytes. Matching is by exact bytes: a paraphrase, a changed space or another normalization is not found, and the host decides whether to ask again. The first failing rule is reported, without the index of the citation. The relation between `"text"` and the citations is not checked. No retrieval, ranking, model call or repair.
