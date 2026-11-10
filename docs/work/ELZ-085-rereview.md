# ELZ-085 narrow re-review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed range: `e8e7eba542a1bcc9874ea652096e02755acd9627..46824d402fa2242708c9682d7971971f484f2ccd` (PR [#169](https://github.com/balungpisah/elzoo/pull/169)).

Scope: the final-review fixes for H1 and H2 only. I inspected Git objects and the live PR body, did not run Mix, call a provider, change the reviewed repository, push, or comment on GitHub. M3 is intentionally not re-raised, per decision record #119.

## H1 — resolved

`admit_submit/2` now calls `prepare/2` once, stores its exact `wire.body` in `staged`, and builds the canonical manifest with exactly `version`, `model`, `item_count`, `wire_bytes`, `wire_sha256`, and `provider_meta`. `SubmitAdapter.send_effect/1` fetches by the binding and manifest digests, checks both byte length and SHA-256 via `Submission.matches?/2`, then passes `%{body: bytes, meta: manifest.provider_meta}` to the provider without a second translation or encoding. Anthropic passes that binary as Req's `:body`; it revalidates the staged beta metadata before the request.

The finite tests support the stated cases: S1 and B1 compare the outbound body and manifest digest with `staged`; S8 checks a missing, modified, and foreign staged body makes no provider call and does not read the credential; B3 checks invalid staged beta metadata sends nothing. This is test evidence, not a proof.

## H2 — partially resolved

The arbitrary lookup closure has been replaced by `{module, server}`. `SubmissionStore.valid?/1` rejects a function, a binary or nil server, an unknown module, and an extra tuple element; S4 covers those invalid shapes. S1 serializes the actual owner state with `:erlang.term_to_binary/1` and checks staged bytes, prompt text, and the credential, so function environments are within the inspected representation. The restart limit remains documented in the store module and the `integration/ai-batch` README and manifest: unstored host state is lost after restart unless the host persists it.

### New finding

1. **High — the generic submission-store call is unbounded and can deadlock the dispatch task.**
   - `SubmissionStore.valid?/1` accepts any loaded module that exports `fetch/3` (`pieces/integration/ai-batch/lib/elzoo/ai_batch/staging.ex:18-21`). `SubmitAdapter.fetch/4` invokes that callback directly, with neither a timeout nor isolation (`pieces/integration/ai-batch/lib/elzoo/ai_batch/adapter.ex:180-190`). A conforming-looking custom store can therefore block forever; `receive_timeout_ms` is only passed to provider transport, and the reference `Agent.get/2` default does not bound arbitrary callback code.
   - This violates the requested no-deadlock/no-unbounded-wait property. Bound the store operation (including custom stores), cancel or isolate a timed-out worker, and add a finite test showing a non-returning store produces the conservative local failure without credential access or transport.

## Additional scope checks

- The exact current PR head returned by `gh pr view 169 -R balungpisah/elzoo --json body,headRefOid` is `46824d402fa2242708c9682d7971971f484f2ccd`; its body was inspected at that head.
- The range modifies only ELZ-085 task records/catalogue artifacts and the two task Piece trees. No other ready Piece ID is changed. The two task Piece manifests themselves are marked `ready` in the base commit, so this statement does not conceal the scoped H1/H2 edits to those two unmerged task Pieces.
- `git diff --check` reports no whitespace errors.

## Verdict

**request changes** — H1 is resolved and the owner-state part of H2 is resolved, but the unbounded generic store callback is a new high-severity liveness defect.
