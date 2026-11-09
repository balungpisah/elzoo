# ELZ-081 final independent review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `b28041ec2816a08d455af88a7a0dd975278f498a`

## Inputs

- `origin/main...b28041ec2816a08d455af88a7a0dd975278f498a` diff and stat.
- Live issue #154 Contract as amended once, including the published body digest `aac060eb533707b3e82a1bceae47d2537c62be5e7b489b732d3511a4dcff4b93`; its task copy, the release-plan pin, `docs/work/ELZ-081.md`, and `docs/work/ELZ-081-early-review.md` at the reviewed SHA.
- PR #162 body; exported-consumer harness and hosted workflow selection at the reviewed SHA; the PR-head hosted result.

## Findings

1. **blocking — `pieces/integration/text-chunking/lib/elzoo/text_chunking.ex:230-253`; `pieces/integration/text-chunking/test/elzoo/text_chunking_test.exs:208-224`.** The malformed-upstream-result path is not exception-safe for an improper list. `is_list/1` accepts an improper list, then `build/6` consumes its valid head and calls itself with the non-list tail, for which no `build/6` clause exists; that raises instead of returning `{:error, :chunker_invariant}`. The same code also evaluates non-descending order in the guard before the required slice-match and first-start checks, and does not explicitly check non-empty text before slicing, contrary to the A1 order. Add a catch-all `build/6` clause that returns the invariant error, validate record shape, bounds, non-empty text, slice match, first start, then non-descending start in separate ordered steps, and add the improper-list seam case to T7.

2. **blocking — `pieces/integration/text-chunking/test/elzoo/text_chunking_test.exs:4`.** The PR-head hosted `check-plan` failed because this source comment names `docs/work/ELZ-081.md` without the required review classification; consequently `check-root`, `check-consumers-db`, and `check-consumers` were skipped. Remove the documentation-path reference from the test comment (or make the narrowly justified guard update) and obtain a green exact-head full hosted run before claiming the required checks or exported-layout evidence.

3. **should-fix — `pieces/integration/text-chunking/README.md:119-120`; `pieces/integration/text-chunking/piece.json:35`; `docs/work/ELZ-081.md:287-292`; PR #162 body, Grounding/Test.** These texts say that hosted `check-consumers` jobs run this Piece's tests. At this SHA, the only consumer that selects every ready Piece is the aggregate consumer, which belongs to `check-consumers-db`; the database-free `check-consumers` job contains only fixed per-ID consumers and does not select `integration/text-chunking`. The current run executed neither because of finding 2. State this precisely, cite `check-consumers-db` as the export-test evidence only after its successful exact-head run, and remove the unsupported plural-job claim.

4. **should-fix — `pieces/integration/text-chunking/test/elzoo/text_chunking_test.exs:274-281`.** T9 audits one hard-coded compiled module via `:code.which/1`; it neither obtains its audited source set from `piece.json` nor proves that the manifest's declared source list is the set audited. This misses the stated export-layout rule for source audits. Make the audit derive the applicable source-file list from the Piece manifest in both repository and exported layouts, without reading a README or scanning a relative `lib/` path, then audit that derived set.

## What was checked and found sound

- The source ceiling is 1 MiB by default and as the option hard ceiling, checked before hashing; the digest check precedes UTF-8, grapheme counting, and splitting. Positional inputs and all declared option ranges are validated, and errors use closed reasons without source or chunk bytes.
- The production result has dense indexes and per-content SHA-256; valid records check bounds before `binary_part/3`; empty input and invalid UTF-8 are refused before the upstream splitter. The grapheme pre-check is documented with U1/U2 as assumptions and the result-count post-check remains authoritative.
- T1--T10 cover the stated seeded and fixed cases, digest short-circuit, both count checks, option errors, and the timing observation. No proof or unchecked typespec is presented as proof, and timing is described as an observation rather than a guarantee. The README includes the required warning that near-1 MiB calls can consume seconds of CPU, including the observed four-byte-text case, and directs callers to keep work off request paths or use a bounded task.
- `mix.exs` adds only `text_chunker` 1.0.1 and `mix.lock` has one corresponding entry. The provider is declared with MIT licensing in `registry/providers.json` and `piece.json`; the Piece declares `text_chunker`, Elixir, and OTP, and its production module has no root-Application dependency.
- The catalogue row, release-plan job and output, roadmap views, dependency view, generated ledger, and task-copy digest pin are present and internally consistent. The changed test support is confined to the Piece. No public-writing exposure of credentials, session identifiers, network addresses, or non-repository filesystem locations was found in the committed diff or PR body.

## Verdict

**Request changes.** 2 blocking, 2 should-fix, 0 note findings.
