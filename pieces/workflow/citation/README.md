# workflow/citation

`Elzoo.Citation` checks a model's cited answer against the exact items that
were given to the model, and resolves each quote to the item's source, version
and byte range (ELZ-329). It is one pure module in plain Elixir: no I/O, clock,
process, storage, model call, retrieval or Unicode normalization. The rules are
exact byte comparisons, one byte search (OTP `:binary.match/2`) and counts; no
Cure law is claimed.

A citation is evidence of where the text came from, not of truth: the Piece
checks that the quoted bytes are in the cited item. It does not check that the
answer is true, that a quote supports the sentence around it, or that the
host's item metadata is right.

## `schema/0`

`Elzoo.Citation.schema()` returns the decoded JSON Schema object (string keys)
of a cited answer, version 1. Its schema identity on the host's output Port is
`elzoo.citation.answer` version 1:

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

`maxLength` counts characters, not bytes, so the schema never refuses an answer
that `check/3` accepts; the byte bounds are `check/3`'s.

## `check(answer, items, policy)`

Returns `{:ok, %{citations: resolved}}` or `{:error, reason}`. It never raises,
for any term in any argument.

```elixir
answer = %{"text" => text, "citations" => [%{"item_id" => id, "quote" => quote}]}
item   = %{item_id: id, source: id, version: version, content: binary}
         # plus start_byte: offset when the item is a chunk of a larger source
policy = %{min_citations: 0..32}
resolved_entry = %{item_id: id, source: id, version: version,
                   start_byte: offset, end_byte: offset}
```

| Input | Bounds |
| --- | --- |
| `answer` | a map with exactly the string keys `"text"` and `"citations"` (the `value` of a `workflow/typed-decision` `decided` finish) |
| `"text"` | valid UTF-8, 0..65,536 bytes; not read beyond its shape |
| `"citations"` | a proper list; each a map with exactly `"item_id"` and `"quote"`, each valid UTF-8 of 1..1,024 bytes |
| `items` | a proper list of 0..256 maps with exactly `item_id`, `source`, `version`, `content` and the optional `start_byte` |
| `item_id`, `source` | valid UTF-8, 1..1,024 bytes; `item_id` unique in the list by exact bytes |
| `version` | integer 1..2^31−1 |
| `content` | a binary of at most 1,048,576 bytes, at most 8,388,608 bytes over all items: exactly the bytes the model was shown as the item's content (for a `workflow/untrusted-content` marked value, its content, not the rendered block) |
| `start_byte` | integer ≥ 0 with `start_byte + byte_size(content) <= 2^53−1` |
| `policy` | a map with exactly `min_citations`, an integer 0..32 |

Rules, in this order; the first failure is returned:

1. `items` and `policy` outside the shapes and bounds above: `:invalid` (host
   input, checked before the model's answer).
2. The answer's shape and bounds, over the whole answer: `:malformed`.
3. More than 32 citations: `:too_many`.
4. Two citations with equal `"item_id"` and equal `"quote"` bytes:
   `:duplicate`. One quote cited from two items, or two quotes from one item,
   is not a duplicate.
5. A citation whose `"item_id"` equals no item's `item_id` by exact bytes:
   `:unknown_item`.
6. A citation whose quote bytes do not occur in its item's `content`:
   `:quote_not_found`. No normalization, case folding or whitespace change: an
   NFD quote of NFC content is not found.
7. Fewer citations than `min_citations`: `:uncited`.

`resolved` has one entry per citation in the answer's order, with the cited
item's `item_id`, `source` and `version`. With `p` the lowest byte position at
which the quote occurs in the content and `s` the item's `start_byte` (0 when
it has none), `start_byte` is `s + p` and `end_byte` is
`s + p + byte_size(quote)`, exclusive as in `integration/text-chunking` and
`integration/search-data`: the quote is
`binary_part(source_text, start_byte, end_byte - start_byte)`. For a chunk of
an ingested document the source text is the parsed text of that version, not
the uploaded bytes.

Errors are bare fixed atoms. None echoes an ID, a quote, a text or content, or
names which citation failed.

## Composition

```elixir
# 1. workflow/context-selection selects the items for the model.
{:ok, %{selected: selected}} = Elzoo.ContextSelection.select(request, context)

# 2. The host builds each item from a selected candidate, adding start_byte
#    from the integration/search-data candidate with the same item_id
#    (a context-selection candidate has no start_byte key).
items =
  for c <- selected do
    %{item_id: c.item_id, source: c.source, version: c.version, content: c.content,
      start_byte: Map.fetch!(start_bytes, c.item_id)}
  end

# 3. workflow/typed-decision asks for an answer of the cited-answer schema on an
#    output Port with schema_id "elzoo.citation.answer", version 1.
{:ok, step} =
  Elzoo.TypedDecision.new(%{id: "answer", request: request, port: port,
                            answer: {:schema, Elzoo.Citation.schema()}, repairs: 1})

# 4. check/3 checks the decided value against the same items.
case Elzoo.Citation.check(value, items, %{min_citations: 1}) do
  {:ok, %{citations: resolved}} -> show_with_citations(value["text"], resolved)
  {:error, _reason} -> do_not_show_as_cited()
end
```

A refused answer is not shown as cited; the host decides whether to ask again.
The checked example `examples/citation.exs` checks two items, one a chunk with
`start_byte`, an accepted answer and a refused fabricated quote.

## Dependencies

The library code depends on no Piece and calls no other Piece. `core/payload-schema`
(with its closure `core/port`) is declared in `piece.json` only because the
tests build `schema/0` through `Elzoo.PayloadSchema.build/2` and check answers
with `Elzoo.PayloadSchema.check/3`; the library code does not call it.

## Kept open

Each of these can be added in place before the first release without breaking a
caller, because it is reached only through a key that an existing caller does
not pass:

- Inline markers in `text` as a citation key (for example `"marker"`), accepted
  only when an added policy member asks for it. Until then an unknown citation
  key is `:malformed`, as the schema's `additionalProperties: false` says;
  `schema/0` keeps giving its version 1 value, and a later `schema/1` can give
  the marked version.
- A map from parsed-text offsets back to the uploaded bytes: an optional item
  key that names the parser's offset map, and an optional resolved-entry key for
  the original byte range.
- Quotes that span two items: an optional policy member that lets one quote run
  across adjacent chunk items of one source and version.
- A near-match mode: an optional policy member `match` whose default is exact
  match; a near match reports its kind in an added resolved-entry key.

The policy, item and resolved-entry maps may gain optional keys and the error
set may gain members in a later in-place version; the result of every input
that is valid now stays equal, and a caller matches on the keys and members it
uses.

## Grounding and limits

Tests only: `mix test pieces/workflow/citation/test` runs groups 1–10 of the
task's acceptance (schema through `core/payload-schema`; every rule at its edge;
Unicode; first occurrence; source offsets; `min_citations`; the fixed error
order; host input; untrusted terms; the example). Expected offsets are written
out by hand. Finite scenarios, not a proof.

- A citation shows that the quoted bytes are in the content of the cited item,
  not that the answer is true or that the quote supports it.
- The item's `item_id`, `source`, `version`, `start_byte` and content are
  host-vouched: the Piece does not check them against a store, a digest or the
  source text.
- Offsets of an ingested document are in its parsed text, not in the uploaded
  bytes.
- Matching is by exact bytes: a paraphrase, a changed space or another
  normalization is not found, and the host decides whether to ask again.
- The first failing rule is reported, without the index of the citation.
- The relation between `"text"` and the citations is not checked.
- Through `workflow/typed-decision`, `Elzoo.PayloadSchema.check/3` refuses an
  answer whose compact JSON is over 65,536 bytes (`:too_large`), so a `"text"`
  of 65,536 bytes, or 32 citations near their byte bounds, reaches `check/3`
  only when the host calls it directly.
- The answer's shape is checked over the whole citation list before the count,
  so a directly supplied list longer than 32 is walked once; through
  `workflow/typed-decision` the 65,536-byte payload bound limits it.
- No retrieval, ranking, model call or repair. No telemetry, configuration or
  control: a pure function with fixed bounds.
