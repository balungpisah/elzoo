# ELZ-093 — Bound the Anthropic text provider's response body while it is received

- Phase: hardening of a ready Piece (no Contract change)
- Catalogue IDs: integration/ai-text-anthropic
- Dependencies: ELZ-079

## Outcome

`integration/ai-text-anthropic` refuses a provider response larger than its 4 MiB raw-body bound
(`@max_raw_bytes`), but checks the size only after Req has buffered the whole body, so an oversized or endless
reply is held in memory before the refusal. Apply the bound while the body is received (the technique adopted by
ELZ-087 for the OpenAI text provider on a Devin finding: a Req `into:` function that stops reading past the
bound), so memory use stays bounded by the cap. The outcome for an oversized reply (its existing failure
classification) does not change.

## Admission record

1. **Responsibility and caller.** Resource safety of the ready Anthropic text provider; callers of ELZ-079.
2. **Interface and invariant.** Unchanged outputs: an oversized response maps to the same outcome as today. New
   invariant made true: at most the bound plus one receive chunk is held before refusal. A reply within the bound
   is decoded exactly as before.
3. **Reuse check.** Req 0.7.5 `into:` streaming option; no new dependency.
4. **Split test.** One Piece; class P. The same pattern in other provider Pieces is each Piece's own concern.
5. **Failure and evidence.** Tests: a stub that streams more than the bound is refused with the existing outcome
   and the receive stops early (measured bytes read below bound plus one chunk); a reply exactly at the bound and
   one byte below are accepted unchanged; all existing provider tests pass unchanged. Upstream: Req's `into:`
   contract at the pinned version.
6. **Composition record.** No Contract, Need or dependency change; implementation fix under the same ID
   (AGENTS "Evolving a ready Contract": restores an implied bound without changing behaviour).

## Scope

`pieces/integration/ai-text-anthropic/lib/` and tests; README limits line updated; work record.
- declare `config :req_llm, load_dotenv: false` through the install-configuration field added by ELZ-091
  (`piece.json`), replacing the README-only "Install configuration" workaround of ELZ-079 (added to scope by the
  main coordinator before any claim).

## Acceptance

- [ ] Oversized replies are refused while receiving, with a test measuring bytes read.
- [ ] Existing assertions unchanged; outputs for in-bound replies byte-identical.
- [ ] Independent review; hosted full check passes at the PR head.

## Out of scope

Other providers; changing the bound.

## Reference

ELZ-079 (#153), ELZ-087 (#157) Devin finding on PR #167.

