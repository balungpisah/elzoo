# workflow/untrusted-content

A tool result, a retrieved document and a message from another member are
content, not instructions. `Elzoo.UntrustedContent` is the one shared mark for
such content and the one format in which a marked value appears in a model
request. A prompt builder and a guard can then treat it apart from the
instructions of the principal. The mark is payload data under its own schema
key; `core/envelope` is unchanged. No ready Piece is called.

## The marked value

The neutral form is a map with exactly these six string keys:

```elixir
%{"schema_id" => "elzoo.untrusted-content.marked", "schema_version" => 1,
  "sources" => ["mcp:files/read_file"], "trust" => "untrusted",
  "max_bytes" => 4096, "content" => "text of the result"}
```

| Key | Value |
| --- | --- |
| `schema_id`, `schema_version` | exactly this pair; a reader finds a marked value in a larger payload by it |
| `sources` | 1 to 16 distinct texts in order, each 1 to 256 bytes of `[A-Za-z0-9._:/@-]`; the trusted host or pattern writes it, content never supplies it |
| `trust` | `"untrusted"` (content as its source gave it) or `"derived"` (text a model made from other content); `derived` is the least trusted class |
| `max_bytes` | integer from 1 to 16,777,216, the size bound the caller declares |
| `content` | valid UTF-8 text of at most `max_bytes` bytes, possibly empty; bytes that are not text travel as base64 text with the encoding named beside the value (ELZ-139) |

Each field is JSON data, so the map goes into a record and comes back as it is.
Every marked value is content, whatever its class. A mark never grants and
never removes authority: authority comes only from the principal. Named skill
instructions are instructions and get no mark; the caller decides that from the
registry snapshot (kind `pinned_skill`), and this Piece never sees the kind.

## Interface

- `decode(term)` gives `{:ok, marked}` or `{:error, :invalid_shape}`. It is the
  only way to make a marked value. A missing or unknown key, another schema
  pair, a bad, repeated or 17th source, an unknown class, a bound out of range,
  and content that is not UTF-8 or is over `max_bytes` are all refused. No error
  holds a value.
- `encode(marked)` gives the neutral map; `decode/1` of it gives an equal value.
  To change content (a cut, for example), encode, replace `content`, decode.
- `concat(a, b)` gives `{:ok, marked}`: content of `a` then `b`; sources of `a`
  then each new source of `b`; the least trusted class; the sum of the bounds.
  `{:error, :too_many_sources}` above 16 sources, `{:error, :too_large}` above
  16,777,216 bytes.
- `wrap(marked, source, trust)` puts the mark of a second source around a
  marked value: same content and bound, `source` first then the earlier sources
  without repeat, class the least trusted of `trust` (the text `"untrusted"` or
  `"derived"`) and the inner class. `{:error, :invalid_shape}` for a bad source
  or class, `{:error, :too_many_sources}` as above.
- `render(marked)` gives `{:ok, text}`, the one format in a model request.

`concat/2`, `wrap/3` and `render/1` take only checked values. A binary, an
undecoded neutral map or any other term gives `{:error, :unmarked}` and nothing
is joined or rendered.

The checked value is `{:UntrustedContent, neutral_map}`. It is opaque to
callers and documented here for source-copy ownership; the marked-only functions
check its map again.

## Rendered format

Three parts joined by one line feed, with no line feed at the end:

    <<<untrusted-content TAG trust=TRUST bytes=N sources=SOURCE,SOURCE>>>
    CONTENT
    <<<end untrusted-content TAG>>>

`TAG` is the first 32 lowercase hexadecimal characters of the SHA-256 of the
content bytes (OTP `:crypto`); `N` is the content byte size; sources stand in
order with commas. The content is not changed and not escaped. Because the tag
depends on the content, the content cannot hold the closing line of its own
block unless someone finds a text that holds the first 128 bits of its own
SHA-256. That is a claim about the format, not about what a model does with
the block.

## Grounding

Cure owns the class decision `least_trusted/2` in
`cure/elzoo/untrusted_content.cure`; the selected law `derived_absorbs` says it
gives `Derived` when either operand is `Derived`, over the closed set of two
classes. The law says nothing about the map check, the rendering or what a
caller marks; Elixir owns those, and the hash.

`mix test pieces/workflow/untrusted-content/test` runs the named groups
`mark_survives`, `unmarked_refused`, `render_format` and
`nested_least_trusted` (finite scenarios with literal neutral maps), plus the
law compile, the source audit and the checked example
`examples/untrusted_content.exs` (mark a tool result, wrap it, render it).
Negative controls: a class decision that returns its left operand fails the
law check; a constant render tag fails `render_format`.

## Needs and limits

Needs: the host or pattern stamps `sources` and `trust` truthfully and decides
what is content. It marks each tool result, retrieved document and member
message before the value reaches a prompt builder, and keeps the neutral map
whole when it stores or forwards it. For memory that `workflow/context-selection`
selected, kind `:source` is `untrusted` and kind `:derived` is `derived`.

Limits: no claim that marking prevents prompt injection; that a model treats a
marked block as data is a stated assumption. No check of who made the content,
no authentication of a source and no detection of instructions inside content.
The checked value is not a security boundary against BEAM code that forges it.
A caller that copies `content` out of the value loses the mark.

Telemetry, Config and Control are not applicable: these are pure functions with
no observations, no settings (the bound is a field of each value) and no
process. Modules are application-owned under `Elzoo.UntrustedContent` and
`Cure.Elzoo.UntrustedContent`. Apache-2.0; no new dependency or pin.
