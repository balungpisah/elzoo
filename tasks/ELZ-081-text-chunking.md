# ELZ-081 — Specify bounded text chunking with byte offsets to a frozen source

- Phase: demand-led retrieval slice
- Catalogue IDs: integration/text-chunking (new row split from the `integration/search-data` family; see open question 1)
- Dependencies: none (pure Recipe; OTP `:crypto` supplies SHA-256)

## Outcome

Own a pure Recipe that splits one frozen UTF-8 source binary into bounded chunks, where
every chunk carries the source digest and the exact byte range it came from, so that a
later store (ELZ-082) and `workflow/context-selection` can cite, verify and re-read a
chunk without trusting the chunk text. Adopt `text_chunker` 1.0.1 (MIT) for the split
itself; Elzoo owns only the input and output bounds, the source-digest binding, the
offset invariant and the error table. No I/O, no storage, no embedding, no tokenizer.
`state/artifact` (content ownership, retention) is deferred, so the caller hands over the
binary itself plus its SHA-256 digest; the Recipe verifies the digest before splitting.
This is the first text slice of the owner's retrieval order (decision record:
`docs/plans/catalogue-dispositions.md#integration-search-data`; owner answer 1: "then
ReqLLM, then MCP client, text chunking and pgvector").

## Admission record

1. **Responsibility and caller.** Turn a frozen source into an ordered, bounded list of
   chunk records with provenance. Callers: C7 scoped context retrieval (index a document
   before embedding it); ELZ-082 stores the chunks with their embeddings; the result
   feeds `workflow/context-selection` candidates (`item_id`, `version`, `source`,
   `content`, `content_hash`) after retrieval.
2. **Interface and invariant.** Inputs: `source` (a binary), `source_digest` (32-byte
   SHA-256 of `source`, supplied by the caller), `source_ref` (an opaque caller identity,
   1..1024 UTF-8 bytes, shape-checked only) and options `chunk_size`, `chunk_overlap`
   (both counted in graphemes, as `text_chunker` measures them), `format` (one of a
   declared subset of `text_chunker`'s formats, at least `:plaintext` and `:markdown`)
   and `max_chunks`. Outputs: `{:ok, %{source_ref, source_digest, source_bytes,
   chunks: [%{index, start_byte, end_byte, content, content_digest}]}}` or
   `{:error, reason}` with `reason` in a finite table (empty input and invalid UTF-8 are
   rejected by Elzoo before `TextChunker.split/2` is called; `text_chunker` returns `[]`
   for empty input and can raise on invalid UTF-8): `digest_mismatch`,
   `invalid_utf8`, `source_too_large`, `too_many_chunks`, `empty_source`,
   `invalid_option{name}`, `chunker_invariant` (the Recipe re-checks every upstream result
   before returning it, in this order and before any slicing: chunk shape, bounds
   `0 <= start_byte < end_byte <= byte_size(source)`, non-empty content, a byte range that
   reproduces the text, a first start of 0, non-descending starts; any failure refuses the
   whole result). Invariants, each checked by tests: (a) for every chunk,
   `binary_part(source, start_byte, end_byte - start_byte) == content`; (b)
   `content_digest == SHA-256(content)`; (c) `0 <= start_byte < end_byte <=
   byte_size(source)` and `index` is dense from 0 in source order; (d) the first chunk
   starts at byte 0 and chunk starts are non-decreasing; overlap is allowed and is not
   guaranteed (upstream says "Overlap is not guaranteed"); (e) the output is bounded by
   `max_chunks` and by the source bound, and an over-bound result is refused as a whole,
   never truncated; (f) equal inputs give equal outputs; (g) nothing is computed when the
   digest does not match. Error terms never contain source or chunk bytes. The output
   need not be a non-overlapping partition, because overlap is not guaranteed; for every
   emitted chunk its byte range is exact. Non-goals: token counting, semantic quality, format parsing (PDF, DOCX and HTML bytes are not
   extracted; `format` only selects separators), language detection.
3. **Reuse check.** `text_chunker` 1.0.1 (MIT; one transitive dependency,
   `nimble_options`, already locked at 1.2.0) supplies the recursive splitter and the
   `TextChunker.Chunk{start_byte, end_byte, text}` struct
   (`lib/text_chunker/chunk.ex:7-15`, `lib/text_chunker.ex` options at the top of the
   module). Elzoo owns the digest check, bounds, the dense index, the content digest and
   the error table; a wrapper that only renamed `TextChunker.split/2` would earn no
   slot. Not adopted: Floki and Explorer (no workload yet, per the record).
4. **Split test.** Chunking is pure and has no Needs; the vector store (ELZ-082) has
   storage, a database Need and access evidence; embedding (ELZ-080) is an external
   Effect. Three lifecycles and evidence types, so three Pieces. Source ownership and
   retention are `state/artifact`'s (deferred) and are not taken here.
5. **Failure and evidence.** Dangerous paths: a chunk whose offsets do not reproduce its
   bytes (citations then point at the wrong text); a chunk computed from bytes that do
   not match the supplied digest; a silently truncated result; invalid UTF-8 crashing the
   caller (`text_chunker` raises `ArgumentError` on invalid UTF-8, observed in the
   orchestrator's scratch probe); an option error raised as an exception instead of a
   returned reason (`text_chunker` raises `TextChunker.Error` on invalid options); CPU
   time growing faster than input size on text without separators (scratch probe: 256
   KiB without separators split in about 0.3 s, 1 MiB in about 5.1 s, while 1 MiB of
   ordinary prose split in about 0.12 s; one host, one run each, not a benchmark).
   Proofs: none required; the offset invariant is checked by tests. Type/contract check:
   none beyond the Elixir validation of inputs (typespecs are documentation). Tests: the
   offset and digest invariants over a fixed, seeded generator of mixed ASCII,
   multi-byte UTF-8 and emoji inputs across the declared formats and several sizes, plus
   fixed cases for leading and trailing whitespace, separator-only text, overlap
   settings and empty input (the
   scratch probe ran 300 such inputs with zero offset violations; the Piece test is the
   evidence, not the probe); digest mismatch computes nothing; invalid UTF-8, empty
   source, oversize source, too many chunks and each invalid option return the declared
   reason without raising; the no-separator worst case at the default source bound is
   measured once on the hosted runner and recorded with the runner, input and options as
   an observation, never as an acceptance threshold. Upstream: `text_chunker`'s split strategy and its
   overlap behavior are named, not proved.
6. **Composition record.** No Piece dependency; SHA-256 comes from OTP `:crypto`
   directly. Needs: none (pure; no credential, no
   configuration read, no process). Telemetry `not_applicable` (pure function, no I/O or
   lifecycle to observe); Config `supported` per call for `chunk_size`, `chunk_overlap`,
   `format`, `max_chunks` and the source bound, validated with declared defaults and hard
   ceilings, no hot reconfiguration; Control `not_applicable` (no process). No
   durability or delivery claim.

## Scope

- add `pieces/integration/text-chunking/` with the Recipe module, README, `piece.json`,
  tests and one example; source audits in the Piece's tests read only the Piece's own
  files as listed in `piece.json` (never a relative README or `lib/` path, which differs
  in the exported consumer layout);
- add `text_chunker` 1.0.1 as a dependency and record it in `registry/providers.json`
  with its license; this is a `mix.exs`/`mix.lock` change, so one local full
  `mix setup && mix check` runs at the head (class X rule) besides the affected gate;
- decide and record the defaults: source bound 1 MiB default and 1 MiB hard ceiling
  (`text_chunker` 1.0.1's no-separator fallback is quadratic: about 5.6 s for 1 MiB of
  ASCII and about 14.3 s for 1 MiB of four-byte emoji in the scratch probe; these are
  observations, not a time guarantee; larger sources need a later provider or version, or
  an explicit asynchronous boundary, under a new Contract); chunk size 2000 and overlap
  200 graphemes by default, size 16..65536, overlap at most half the size; `max_chunks`
  4096 by default, ceiling 65536, with a grapheme-count pre-check that refuses
  `too_many_chunks` before the split when `graphemes > max_chunks * chunk_size` (sound only
  under two named, version-pinned upstream assumptions of `text_chunker` 1.0.1: each chunk
  has at most `chunk_size` graphemes, and the chunks cover the source; the post-check on
  the actual result stays the sole authority);
- add the catalogue row `integration/text-chunking` and its release-plan entry (or the
  ID main selects), regenerate `LEDGER.md` and the roadmap views.

## Acceptance

- [ ] For every chunk of every generated input, the byte range reproduces the chunk's
      bytes and `content_digest` is the SHA-256 of those bytes.
- [ ] A digest mismatch, invalid UTF-8, empty source, oversize source, too many chunks
      and each invalid option return the declared reason without raising and without
      chunk or source bytes in the error.
- [ ] The no-separator worst case at the default source bound is measured once on the
      hosted runner and recorded as an observation.
- [ ] The Piece's tests pass in the exported consumer layout (`check-consumers-db`).
- [ ] Operational applicability is declared per docs/operational-contracts.md.
- [ ] Full `mix setup` and `mix check` pass at the PR head on the pinned toolchain.

## Evidence and limits

Finite tests over listed and seeded generated scenarios; upstream contract of
`text_chunker` 1.0.1; no proof is claimed. Chunks need not be a non-overlapping
partition of the source;
token counts, semantic boundaries and extraction from binary document formats are not
provided. CPU time is bounded only through the source bound; no time guarantee.

## Out of scope

Embedding, storage, retrieval, tokenization, document text extraction (PDF, DOCX,
HTML), source ownership and retention (`state/artifact`), streaming input.

## Reference

Decision record `integration/search-data` (ADOPT; owner answer 1; conditions "Admit
slice by slice: `text_chunker` (S)" and invariant "Chunks keep byte offsets to a frozen
source"); RC-18 (its retrieval output stays with ELZ-082); `workflow/context-selection`
candidate shape.

## Open questions (none blocks a builder)

1. Catalogue ID: a new row `integration/text-chunking` (recommended: a ready Contract
   cannot later grow the pgvector store under one ID without a new ID, per AGENTS
   "Evolving a ready Contract") versus `integration/search-data` with coverage
   `subset`. Main decides at publication.
2. Whether the Recipe should also offer `get_chunk_size` (a caller-supplied measure such
   as a byte or token count). Recommended: not in this slice; graphemes only, stated.
