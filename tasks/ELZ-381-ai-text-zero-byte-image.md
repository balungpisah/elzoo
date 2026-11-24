# ELZ-381 — integration/ai-text refuses an image of zero bytes before any provider sees it

- Phase: repair of the ready Piece `integration/ai-text` before the first release (defect #914)
- Dependencies: ELZ-079, ELZ-364
- Release: V1B
- Output: none. A change in place of the ready Piece `integration/ai-text` (ELZ-079, image input ELZ-364) before the first release, with the same Piece ID (`AGENTS.md` section 4): one input that was accepted is now refused.
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: the Piece directory, its index row and generated files)
- Owned paths: `pieces/integration/ai-text/**`; the `manifest_sha256` and `note` of its `entries` row in `docs/plans/release-plan.json` and the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` (`AGENTS.md` section 3). No other Piece (the providers, `integration/ai-text-anthropic`'s schema fixture with its `minLength: 1` included), no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Defect and decision

Reported in #914. The coordinator decision recorded there: `integration/ai-text` refuses a zero-byte image artifact at admission, before any provider sees it, so no provider sends an empty image; `integration/ai-text-anthropic`'s fixture keeps `minLength: 1`. This publication does not settle #914; the build pull request does.

On `main`, `read/3` in `lib/elzoo/ai_text.ex` accepts an artifact answer of zero bytes: `size_bytes` 0 equals `byte_size(bytes)`, both bounds hold, and the hash matches. A provider that declares `:image_input` then gets `%{type: :image, media_type: m, bytes: ""}`, and `integration/ai-text-anthropic` sends an image block whose base64 `data` is empty. Whether a provider refuses that, and how, is not documented; a refusal would come after one request was sent.

## Facts on `main` that this task builds on

Checked at `a9b1badb`; confirm each before you start, and comment on the issue if one differs.

- `read/3` makes one artifact Need call per image part and accepts `{:ok, %{record, bytes}}` only when the record names the referenced `artifact_id` and `version`, `size_bytes` equals `byte_size(bytes)`, the bounds hold (`too_large` otherwise, checked before the hash) and `sha256` matches; a media type other than the part's is `invalid_request`; every other failure is `input_unavailable`.
- At admission (`admission/2` through `check/2`) these are local refusals before any intent, `{:error, {:refused, reason}}`. In the Adapter (`send_effect/1`), `Elzoo.AiText.prepare/2` resolves the parts again, and any resolution failure finishes with the tag `input_unavailable`, attested no-send, before the credential Need.
- The README states the rule in "Image input (Contract amendment 2)", the bullet that begins "After the neutral checks and before `translate/2`".

## The change

- An image whose answer otherwise passes the record, size and hash checks and holds zero bytes is refused `invalid_request`: a caller's fault, like a media type mismatch, and not `input_unavailable`, which `delivery/model-routing` would retry. It is decided with the media type check, after the hash, so an answer of zero bytes whose record or hash does not match stays `input_unavailable`.
- At admission it is the local refusal `{:error, {:refused, :invalid_request}}` before any intent and before `translate/2`. In the Adapter it is the tag `input_unavailable`, attested no-send, before the credential Need, as every resolution failure is there (an artifact version is immutable, so a reference admitted with bytes does not reach the Adapter with none unless the host's Need answers differently).
- Nothing else changes: no bound, reason, tag, outcome, capability or provider-facing shape, and a request with no image part, or with non-empty images, behaves byte for byte as today. The README bullet states the rule, `piece.json` (`contract`, `grounding`) follows, and the `note` and `manifest_sha256` of the index row follow `piece.json`.

## Acceptance

New tests in `test/elzoo/ai_text_test.exs`, through `check/2`, `admission/2` and the Adapter with the Piece's stub provider that declares `:image_input`:

1. **Zero bytes at admission.** An artifact Need that answers a matching record with `size_bytes` 0, the hash of the empty content and the part's media type: `admission/2` is `{:error, {:refused, :invalid_request}}`, no intent is started and the provider's `translate/2` is not called. On `main` this case fails: the admission succeeds.
2. **One byte.** The same with one byte: admitted, and `translate/2` gets the one-byte image.
3. **Zero bytes at dispatch.** An intent admitted with a non-empty image whose artifact Need answers a matching zero-byte record at dispatch: the outcome is the tag `input_unavailable`, attested no-send, the credential Need is not called and the provider makes no request.
4. **Order.** A zero-byte answer whose `sha256` does not match is `input_unavailable` at admission.
5. **The rest is unchanged.** Every existing test of the Piece passes unchanged, the conformance kit's scenarios included, and the tests of the ready Pieces that depend on `integration/ai-text`, which the small gate runs.

Negative control, a temporary edit of `lib/` that is reverted and never committed: drop the zero-byte check, and case 1 fails. Record the failure in the pull request.

## Gate, review and build

Run `mix test pieces/integration/ai-text/test`, then the small gate `mix check --piece "$(git merge-base origin/main HEAD)"`, which also runs the tests of every ready Piece that depends on `integration/ai-text`, and `git diff --check`. The Piece holds credentials and an external-effect boundary, so it keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"); the hosted `check-piece` run on the exact head and the merge queue follow.

## Limits to state

- Only the empty image is refused; whether a provider accepts other degenerate images (for example a valid header with no pixels) is not checked here.
- Finite listed scenarios, not a proof.
