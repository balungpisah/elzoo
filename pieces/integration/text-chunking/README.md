# integration/text-chunking

Bounded text chunking with byte offsets to a frozen source (ELZ-081). A pure Recipe over
[`text_chunker`](https://hexdocs.pm/text_chunker/1.0.1/TextChunker.html) 1.0.1 (MIT): the
caller hands over the source binary, its SHA-256 and an opaque reference; `text_chunker` chooses
the cut points; Elzoo owns the bounds, the digest binding, the offset re-check, the dense index,
the content digest and the error table. No I/O, no process, no storage, no embedding, no
tokenizer.

Callers: C7 scoped context retrieval indexes a document before embedding it; a later store keeps
the chunks; retrieval results feed `workflow/context-selection` candidates, which can cite and
re-read a chunk from `start_byte`/`end_byte` and verify it by `content_digest` without trusting
the chunk text.

## Interface

```elixir
{:ok, %{source_ref: ref, source_digest: digest, source_bytes: n, chunks: chunks}} =
  Elzoo.TextChunking.chunk(source, :crypto.hash(:sha256, source), "doc:42",
    format: :markdown, chunk_size: 2000, chunk_overlap: 200)

# each chunk: %{index, start_byte, end_byte, content, content_digest}
```

| Input | Admissible values | Default |
| --- | --- | --- |
| `source` | binary, 1..`max_source_bytes` bytes, valid UTF-8 | — |
| `source_digest` | 32-byte SHA-256 of `source` | — |
| `source_ref` | UTF-8 binary, 1..1024 bytes, opaque (shape-checked only) | — |
| `:max_source_bytes` | 1..1 048 576 | 1 048 576 (1 MiB) |
| `:chunk_size` | 16..65 536 graphemes | 2000 |
| `:chunk_overlap` | 0..div(chunk_size, 2) graphemes | 200 |
| `:format` | `:plaintext`, `:markdown` (selects separators only; no parsing) | `:plaintext` |
| `:max_chunks` | 1..65 536 | 4096 |

`Elzoo.TextChunking.limits/0` returns the same table. Sizes are graphemes (`String.length/1`), as
`text_chunker` measures them; there is no caller-supplied measure (`get_chunk_size`) and no
`strategy` option in this Contract; a byte or token measure would be a new Piece ID. A repeated
or unknown option is refused.

## Results and errors

Invariants of every `{:ok, result}`: (a) `binary_part(source, start_byte, end_byte - start_byte)
== content`; (b) `content_digest == SHA-256(content)`; (c) `0 <= start_byte < end_byte <=
byte_size(source)` and `index` is dense from 0; (d) the first chunk starts at byte 0 and starts
never decrease; (e) at most `max_chunks` chunks from a source within the bound, refused as a
whole above it, never truncated; (f) equal inputs give equal outputs; (g) nothing is computed when
the digest does not match. Chunks may overlap; overlap is not guaranteed (upstream); the output
is **not** promised to be a non-overlapping partition or to cover every byte.

Errors, checked in this order (`{:error, reason}`; never raised; never containing source bytes,
chunk bytes or option values):

| Reason | When |
| --- | --- |
| `{:invalid_option, name}` | `name` is one of `:source`, `:source_digest`, `:source_ref`, `:opts` (not a keyword list), `:unknown_option`, `:max_source_bytes`, `:chunk_size`, `:chunk_overlap`, `:format`, `:max_chunks` |
| `:source_too_large` | more than `max_source_bytes` bytes; nothing is hashed |
| `:empty_source` | `source == ""` |
| `:digest_mismatch` | SHA-256 of `source` differs from `source_digest`; no UTF-8 scan, no split |
| `:invalid_utf8` | `source` is not valid UTF-8 (`text_chunker` would raise) |
| `:too_many_chunks` | the grapheme pre-check, or more than `max_chunks` chunks returned |
| `:chunker_invariant` | the upstream result fails the re-check below |

**Offset re-check (fail closed).** Every upstream result is re-checked before it is returned, in
this order and before any slicing: chunk shape (integer offsets, binary text), bounds
`0 <= start_byte < end_byte <= byte_size(source)`, non-empty content, the byte range reproduces
the text, the first start is 0, starts never decrease. Any failure refuses the whole result as
`:chunker_invariant`. The pinned provider has not been observed to fail it; the tests reach it
through a private test seam (`__chunk__/5`) that injects the split function.

**Chunk-count pre-check.** Before splitting, `String.length(source) > max_chunks * chunk_size`
refuses `:too_many_chunks` without calling upstream. It is a sound necessary refusal only under two
named, version-pinned upstream assumptions of `text_chunker` 1.0.1 that its public `split/2`
interface does not promise:

- **U1** every returned chunk has at most `chunk_size` graphemes;
- **U2** the returned chunks together cover every byte of the source.

The tests check both against the production call over a seeded corpus (finite evidence, not a
proof). The post-check on the actual result is the sole authority for (e).

## Bounds and time

`text_chunker` 1.0.1 falls back to grapheme slicing for text without separators, and that path
is quadratic in the remaining text (each step re-measures and re-slices the remainder). Scratch
probe observations on one shared host (not a benchmark, not a guarantee): 1 MiB of `x` at the
defaults about 5.6 s, 2 MiB about 23.5 s, 1 MiB of four-byte emoji about 14.3 s; 1 MiB of prose
with spaces about 1.5 s. Hence the 1 MiB hard ceiling: larger sources need a later provider or
version, or an explicit asynchronous boundary, under a new Contract. CPU time is bounded only
through the source bound; there is no time guarantee.

**Keep it off request paths.** With a source near 1 MiB one call can take seconds of CPU
(observed up to about 14 s for four-byte text). Callers run it outside latency-sensitive request
handling, for example in a bounded task or job with its own deadline; the Recipe itself starts no
process and has no timeout. The hosted observation of the
no-separator case at the default bound is printed by test T10 as `ELZOO OBSERVATION
text-chunking ...`.

## Needs and operations

Needs: none (no credential, no configuration read, no process). Providers: `text_chunker` 1.0.1
(its one requirement `nimble_options` comes with it), Elixir, OTP `crypto`.

- Telemetry `not_applicable`: a pure function with no I/O or lifecycle to observe.
- Config `supported` per call: the five options above, validated against declared defaults and
  hard ceilings; values apply only to the current call; no hot reconfiguration.
- Control `not_applicable`: no process, no lifecycle.

No durability or delivery claim.

## Evidence and limits

- Proof: none. Type/contract check: none (typespecs are documentation).
- Tests (`test/elzoo/text_chunking_test.exs`): T1 seeded generator over mixed ASCII, multi-byte,
  emoji, combining marks, CRLF and separators in both formats; T2 determinism; T3 fixed cases;
  T4 every reason without raising or bytes; T5 digest mismatch computes nothing; T6 pre- and
  post-check; T7 each re-check failure; T8 invalid options and inputs; T9 an import-table audit of
  the lib sources the manifest lists (no I/O, process, environment or telemetry module); T10 the worst-case observation.
- Exported consumer: the aggregate consumer of the hosted `check-consumers-db` job takes every
  ready Piece, this one included, through the exporter and runs its tests in the consumer layout
  without the root Application. The database-free `check-consumers` job runs fixed per-ID
  consumers only and does not select this Piece. The evidence is a green exact-head run of
  `check-consumers-db`, cited in the PR.
- Upstream contract: `text_chunker` 1.0.1 split points and byte ranges, overlap behaviour; OTP
  `:crypto` SHA-256; Elixir `String.valid?/1` and `String.length/1`.
- Assumptions: U1 and U2 above; the caller's digest is of the bytes it means to cite (the Recipe
  checks consistency, not authenticity).
- Not provided: token counts, semantic quality, extraction from PDF, DOCX or HTML bytes, language
  detection, streaming input, storage, embedding, retrieval, source ownership or retention
  (`state/artifact`).

Upstream licences: `text_chunker` MIT (Revelry; its NOTICE credits langchainjs, MIT);
`nimble_options` Apache-2.0.
