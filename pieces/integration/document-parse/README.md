# integration/document-parse

Bounded UTF-8 text from untrusted document bytes (ELZ-333). A pure Piece in plain Elixir:
bytes of the closed media-type set `text/plain`, `text/markdown` and `text/html` give text
of 1..1 MiB, with the raw SHA-256 of the input and of the text and a parser identity, that
[`integration/text-chunking`](../text-chunking/README.md) takes as its source. HTML is
parsed by [`floki`](https://hexdocs.pm/floki/0.38.5/Floki.html) 0.38.5 (MIT) with its bundled
`Floki.HTMLParser.Mochiweb`. No I/O, clock, process, storage, network, transcoding or model
call; no URL is fetched, no external entity is resolved and no script runs.

The input is untrusted bytes from a tenant's document, and the output is untrusted content:
the caller marks it with `workflow/untrusted-content`; this Piece does not.

## Interface

```elixir
{:ok, %{text: text, format: format, media_type: "text/html",
        source_sha256: <<_::256>>, text_sha256: <<_::256>>,
        parser: %{id: "integration/document-parse", version: 1, library: "floki 0.38.5"}}} =
  Elzoo.DocumentParse.parse(bytes, "text/html", max_bytes: 8_388_608)
```

| Input | Admissible values | Default |
| --- | --- | --- |
| `bytes` | binary, 0..`max_bytes` bytes, valid UTF-8 | — |
| `media_type` | exactly `"text/plain"`, `"text/markdown"` or `"text/html"` (no parameter, other case or space) | — |
| `:max_bytes` | 1..8 388 608 | 8 388 608 (8 MiB) |

`Elzoo.DocumentParse.limits/0` returns the same bounds, the text bound 1..1 048 576 and the
media types. `opts` is a keyword list; an unknown or repeated key is refused.

| Result key | Value |
| --- | --- |
| `text` | valid UTF-8 of 1..1 048 576 bytes |
| `format` | `:markdown` for `text/markdown`, `:plaintext` otherwise (text-chunking's `format`) |
| `media_type` | the given media type |
| `source_sha256` | raw SHA-256 of `bytes` as given, BOM included |
| `text_sha256` | raw SHA-256 of `text` |
| `parser` | `%{id: "integration/document-parse", version: 1, library: "floki 0.38.5" or nil}`; `version` names the text rules below |

## Errors

Checked in this order; the first failure is returned as `{:error, reason}`; never raised; no
reason holds a byte of the input or of the text.

| Reason | When |
| --- | --- |
| `{:invalid_option, :bytes}` | `bytes` is not a binary |
| `{:invalid_option, :opts \| :unknown_option \| :max_bytes}` | not a proper keyword list; an unknown key; `max_bytes` not an integer in 1..8 388 608, or repeated |
| `:unsupported_media_type` | not one of the three binaries |
| `:too_large` | more than `max_bytes` bytes |
| `:invalid_utf8` | `bytes` is not valid UTF-8 (no transcoding) |
| `:parse_failed` | HTML only: see below |
| `:unsupported_charset` | HTML only: a `meta` charset declaration that is not UTF-8 |
| `:empty_text` | the text is empty (0 bytes, a lone BOM, HTML with no kept text) |
| `:text_too_large` | the text is above 1 048 576 bytes; refused whole, never truncated |

`:parse_failed` covers: the input holds `</floki` in any ASCII case, or an end tag whose name
(after `</`, up to ASCII whitespace, `>`, `/`, `=` or the end) holds `&` — the parser's root
element is `floki` and it decodes character references in end-tag names, so either would
silently drop the rest of the document; a `title` or `textarea` text node that ends with
`</floki>`, which only an unclosed one at the end of the input gives, since it takes in the
parser's own closing wrapper (coordinator decision, option B); the parse gives `{:error, _}`,
raises, throws or exits, or gives a node of another shape; or text that goes into `text` is not
valid UTF-8. The shape check reads only the form of each node (text binary, `{tag, attributes,
children}`, `{:comment, _}`, `{:pi, _, _}`); names and attributes can be charlists or bytes
that are not UTF-8.

## Text rules (version 1)

**Plain text and Markdown.** One leading UTF-8 BOM is removed and each CR LF becomes LF in one
pass from the left (`"\r\r\n"` gives `"\r\n"`); a lone CR stays. Nothing else changes: Markdown
is not rendered and no entity is decoded.

**HTML.** One leading BOM is removed and the rest is parsed with
`Floki.parse_document(bytes, html_parser: Floki.HTMLParser.Mochiweb)`. Naming the parser means a
host's `config :floki, :html_parser` does not change the result (floki still reads it). Then, in
document order:

- A text node contributes its text, with entities as the parser decodes them (`&amp;` gives `&`,
  `&#xD800;` gives U+FFFD, `&bogus;` stays). `title` and `textarea` are raw text to the parser,
  so their entities stay as written.
- `script`, `style`, `template` and `noscript` are left out with their subtree; inside `head`
  only `title` text is kept; comments, processing instructions and attribute values never appear.
- Each element of the closed block set (`address`, `article`, `aside`, `blockquote`, `br`,
  `caption`, `dd`, `details`, `dialog`, `div`, `dl`, `dt`, `fieldset`, `figcaption`, `figure`,
  `footer`, `form`, `h1`–`h6`, `header`, `hgroup`, `hr`, `li`, `main`, `nav`, `ol`, `p`, `pre`,
  `section`, `summary`, `table`, `tbody`, `td`, `tfoot`, `th`, `thead`, `title`, `tr`, `ul`)
  breaks before and after its content.
- One U+0020 goes between two adjacent sibling nodes that are both not text nodes (the parser
  drops whitespace-only text nodes): `<b>Hello</b> <i>world</i>` gives `Hello world`, and
  `<b>Hel</b><i>lo</i>` gives `Hel lo`; `<b>Hel</b>lo` gives `Hello`.
- In each paragraph every run of ASCII whitespace (U+0009, U+000A, U+000C, U+000D, U+0020)
  becomes one space and the ends are trimmed; empty paragraphs are dropped and the rest are
  joined with `"\n\n"`. U+00A0 stays.

A **charset declaration** is a `meta` element's `charset` attribute (each, if repeated) or, with
`http-equiv` `content-type`, the value after the first `charset=` in `content` up to `;` or
whitespace, one pair of quotes removed. Each must be `utf-8` or `utf8` (ASCII case-insensitive,
trimmed); none means UTF-8. XML declarations are not read.

## Composition

The library code depends on no Piece and does not call `integration/text-chunking`; the tests
and the example use it (it is declared in `piece.json` so a copied consumer can run them).

```elixir
{:ok, %{bytes: bytes}} = Elzoo.Artifact.get(art, caller, artifact_id, version)  # state/artifact
{:ok, doc} = Elzoo.DocumentParse.parse(bytes, "text/html")
{:ok, %{chunks: chunks}} =
  Elzoo.TextChunking.chunk(doc.text, doc.text_sha256, source_ref, format: doc.format)

# Before any model sees it, the caller marks each chunk's text as untrusted content
# with workflow/untrusted-content, and records doc.parser with doc.text_sha256.
```

The checked example [`examples/document_parse.exs`](examples/document_parse.exs) parses an HTML
page with a `script` and chunks its text.

## Kept open

Each can be added in place before the first release through a media type, an option key or a
parameter that no existing caller passes; for every input version 1 accepts the result stays
equal: PDF, DOCX and other formats (each with its provider; today `:unsupported_media_type`);
headings and links as result keys behind an option; other charsets behind an option; media-type
parameters; an offset map back to the input bytes; stripping the wrapper suffix of an unclosed
`title` or `textarea` instead of refusing it; whitespace kept in `pre`, more block or left-out
elements and other inline spacing behind an option. Options, result keys and error members may
grow; a caller matches on those it uses.

## Bounds and time

CPU time is bounded only through the 8 MiB input bound. Observations on one shared host, not a
guarantee: about 1.4 million nested `<div>` (7 MB) parse in about 5 s; 8 MiB of comment in about
0.1 s. The tests print their own as `ELZOO OBSERVATION document-parse ...`. Keep large documents
off request paths (a bounded job, for example).

## Needs and operations

Needs: none (no credential, no configuration read, no process). Providers: `floki` 0.38.5,
Elixir, OTP `crypto`.

- Telemetry `not_applicable`: a pure function with nothing to observe.
- Config `supported` per call: `max_bytes` against its declared default and ceiling.
- Control `not_applicable`: no process, no lifecycle.

## Evidence and limits

- Proof: none. Type check: none (typespecs are documentation).
- Tests (`test/elzoo/document_parse_test.exs`): acceptance groups 1–12 with hand-written
  expected texts, seeded generators for left-out text and for the never-raise case, the
  `__parse__/4` seam for every parse failure, the `:floki` setting check, an import-table audit.
  These call the real `Floki.parse_document/2` with the bundled parser: the runtime check that
  adopts `floki`.
- Upstream: `floki` 0.38.5 tree shapes, wrapper, whitespace and entity behaviour as pinned by
  the tests; Elixir `String.valid?/1`; OTP `:crypto` SHA-256.
- Limits: the text is not a rendering (no CSS, `display` or `hidden`; `pre` collapsed); the
  space between adjacent elements is this Piece's rule, not the source's; documents with
  `</floki`, an `&` end-tag name or an unclosed `title`/`textarea` at the end are refused even
  when harmless; the left-out rules apply to the parsed tree, so a tag that the parser reads as part of an unclosed processing instruction, comment or attribute before it is no element (`<?x<style>s</style>` gives `s`); the bundled parser is not HTML5-compliant and no claim is made that it is safe
  for hostile HTML beyond the listed and generated cases; Markdown passes through as source,
  HTML inside it untouched; UTF-8 only, `meta` declarations only; no PDF, DOCX, fetch, storage or
  chunking. Parsing grants no authority and prevents no injection.
