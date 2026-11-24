# ELZ-364 — integration/ai-text takes images in a user message by artifact reference, for a provider that declares image input

- Phase: in-place change of a ready Piece before the first release (Wave 9, Level 1; owner answer Q7 A of [the Wave 9 plan](../docs/plans/bot-platform-wave9.md#owner-answers-2026-11-24), which absorbs the `integration/ai-multimodal` handle)
- Dependencies: ELZ-079, ELZ-096
- Release: V1B
- Output: none. A change in place of the ready Piece `integration/ai-text` (ELZ-079), before the first release, with the same Piece ID (`AGENTS.md` section 4): Contract amendment 2. A request without image parts, and every provider that does not declare `:image_input`, behaves exactly as today.
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: the Piece directory, its index row and the generated files)
- Owned paths: `pieces/integration/ai-text/**`; the `manifest_sha256` and `note` of the `integration/ai-text` row of `entries` in `docs/plans/release-plan.json`, and the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` (`AGENTS.md` section 3). No other Piece (not `integration/ai-text-anthropic`, `integration/ai-text-openai`, `integration/ai-model` or `state/artifact`), no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

A user message may hold **content parts**: text parts and image parts, each image a reference to one immutable `state/artifact` version with its media type. The canonical request keeps its 65,536-byte bound, because it holds references only. The interface resolves each reference through a host **artifact read Need** before translation, checks the bytes against the version's content hash and size and against declared bounds, and hands the provider's pure `translate/2` the bytes. The capability set gains `:image_input`; a request with parts to a provider that does not declare it is refused `unsupported_feature`, as today. `"document"` stays refused. The image-capable providers come at Level 2 (`integration/ai-text-anthropic` in place, `integration/ai-text-google`, `integration/ai-text-compatible`); this task changes none.

Admission still refuses locally before any intent; the change adds one Need call there and in the Adapter, and a new attested no-send failure for a read that fails at dispatch. A wrong rule there would send a request that the Contract says is never sent, or call an unknown outcome a no-send, so this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"; `AGENTS.md` sections 5 and 6).

## Facts on `main` that this task builds on

Checked at `main` `2face3fc`. Confirm each before you start; if one differs, stop and comment on the issue.

- A message is `{"role": "system" | "user", "text": string}`, an assistant message with optional `"tool_calls"`, or `{"role": "tool_result", "tool_use_id", "text", "is_error"?}` (`lib/elzoo/ai_text/request.ex`, lines 9–14, 160–200). `@unsupported_parts ~w(image document parts)` (line 39) refuses a message holding any of those members as `:unsupported_feature` before the role checks (lines 173–174). Text is a binary of at most 65,536 bytes (line 327). `Request.decode/2` checks the raw bytes and then the canonical bytes (sorted keys, compact) against `max_request_bytes` (lines 35, 48–62, 110–120).
- `Elzoo.AiText.Provider` (`lib/elzoo/ai_text/provider.ex`): callbacks `capabilities/0`, `translate/2`, `call/2`, `decode/2`, `classify_failure/1`; capabilities are a map with `features` from the closed `@features [:tools, :structured_output, :sampling, :stop_sequences, :cache_hint, :reasoning]` (line 36), checked by `valid_capabilities?/1` at `configure/1` (`lib/elzoo/ai_text.ex`, line 49). `check/2` (lines 141–179) runs the neutral checks, refuses an undeclared feature (`unsupported?/3`, lines 181–189) and then calls `translate/2`; admission (lines 93–133) and `Adapter.send_effect/1` (`lib/elzoo/ai_text/adapter.ex`, lines 36–58) both call it. Admission "never creates an intent, reads the credential or calls the provider's transport". In the Adapter the code translates before it reads the credential, although the moduledoc and README lines 28–30 name the other order; this task makes the documents say what the code does (translation, then the credential).
- `configure/1` takes a closed option list (`@options`, lines 18–29) and the `Config` struct enforces its keys (`lib/elzoo/ai_text/config.ex`, lines 4–15); `inspect` shows no secret, Need or sink.
- Failure tags (`lib/elzoo/ai_text/outcome.ex`): the static table equals the Cure decision `Elzoo.AiTextOutcome` (`cure/elzoo/ai_text_outcome.cure`), checked by `Outcome.verify/0` at `configure/1`. `credentials_unavailable` is the one attested no-send tag (`{"timed_out", "not_dispatched", "unavailable"}`, `@no_send`), and `provider_tags/0` is every tag except `credentials_unavailable` and `adapter_error`. `Elzoo.AiText.Retry.next/4` retries only a tag in `Outcome.no_send()`. Today's amendment is Contract amendment 1 (README line 66).
- Usage counters use the closed unit set of `integration/ai-model`, which already holds `:images` (`pieces/integration/ai-model/lib/elzoo/ai_model/usage.ex`, lines 23–33); a counter the provider did not report is `:unknown`.
- `state/artifact`: `Elzoo.Artifact.get(art, caller, artifact_id, version)` returns `{:ok, %{record: record, bytes: bytes}}` after checking the bytes; a record holds `artifact_id`, `version`, `sha256`, `hash_format`, `size_bytes` and `media_type`, and `sha256` is the lowercase hex SHA-256 of `<<hash_format::8, bytes>>` (`pieces/state/artifact/README.md`, line 111; `lib/elzoo/artifact/record.ex`, lines 71–73), not of the bytes alone. Versions are immutable. `artifact_id` is 1..64 bytes of letters, digits and `-_.`. This Piece does not call `state/artifact`: the host Need wraps `get/4`, so `piece.json` gains no dependency.
- No golden byte test of a text-only request exists today. The nearest are `test/elzoo/ai_text_test.exs` ("request codec: canonical bytes ..." about line 471; the I2 local refusals about line 145) and the provider kits (`ai_text_anthropic_test.exs` A1, `ai_text_openai_test.exs` O1), which validate wire requests against schemas. So this task records a golden first (Acceptance 1).
- `integration/ai-text-anthropic` and `integration/ai-text-openai` declare `features` without `:image_input`, and their translators match `%{role: :user, text: t}`; since `check/2` refuses parts for them before `translate/2`, they are unchanged.

## The Contract change (amendment 2)

**Request.** A `"user"` message may be `{"role": "user", "parts": parts}` instead of `{"role": "user", "text": ...}`: `parts` is a list of 1..64 parts, each exactly one of
- `{"type": "text", "text": string}` (the text rule of today);
- `{"type": "image", "artifact": {"id": artifact_id, "version": integer}, "media_type": media_type}`, with `artifact_id` as in `state/artifact`, `version` 1..2^31−1 and `media_type` one of `image/png`, `image/jpeg`, `image/webp`, `image/gif`.

At least one part is an image. A request holds at most 8 image parts in all. Another part `type` (`"document"` among them), another member, `parts` on another role, and the `"image"` and `"document"` members stay `unsupported_feature`. A message with both `text` and `parts` is `invalid_request`. Normalized, a part is `%{type: :text, text: t}` or `%{type: :image, artifact_id: id, version: v, media_type: m}`, and the message is `%{role: :user, parts: parts}`.

**Capability.** `@features` gains `:image_input`. A request with any `parts` message to a provider that does not declare it is `unsupported_feature`, in `check/2` before any Need call or translation.

**Config.** `configure/1` takes two optional keys: `artifacts`, a one-arity Need given `%{artifact_id, version}` that returns what `Elzoo.Artifact.get/4` returns (the host wraps it with its own `art` and `caller`), and `image_bounds`, `%{max_image_bytes: 1..5,242,880, max_total_image_bytes: 1..41,943,040}` (default 5,242,880 and 20,971,520). A request with parts and no `artifacts` Need is `unsupported_feature`. Without these keys a Config is today's.

**Resolution.** After the neutral checks and before `translate/2`, the interface calls the `artifacts` Need once per image part, in order, and checks each answer: a result of the shape above whose `record.artifact_id` and `record.version` equal the reference, whose `record.media_type` equals the part's `media_type`, whose `byte_size(bytes)` equals `record.size_bytes`, and whose `record.sha256` equals the lowercase hex SHA-256 of `<<record.hash_format::8, bytes>>`. The translated request's image parts carry `%{type: :image, media_type: m, bytes: bytes}`. Each image is at most `max_image_bytes` and all images together at most `max_total_image_bytes`.

- **At admission** a failure is a local refusal before any intent: a size over a bound is `too_large`; a media type that differs from the record's is `invalid_request`; any other failure of the Need or of the checks (absent, refused, raised, a hash or size mismatch) is the new local refusal `input_unavailable`. Admission's refusal set becomes `invalid_request | unsupported_feature | too_large | input_unavailable`.
- **In the Adapter**, inside the send task and before the credential Need, any failure of the same resolution is the new failure tag `input_unavailable`: refused, `timed_out / not_dispatched / unavailable`, attested no-send (no byte reached transport), so `Retry.next/4` retries it as it retries `credentials_unavailable`. It is added to the Cure decision (a new `TagInputUnavailable` and `ReasonInputUnavailable`, with `no_send` true), to the static table, to `@no_send` and to the README table, and it is excluded from `provider_tags/0`, since it is the interface's own.

The outcome set gains `refused{input_unavailable}`. The image bytes are never part of the intent's arguments, its Store, an outcome, an error or `inspect`.

**Usage.** The interface adds no counter. A provider that reports an image count reports it in the existing `:images` unit; one that does not leaves it out, and image input tokens are in the input token counters as the provider reports them.

**Conformance kit.** `Elzoo.AiText.Conformance` gains one scenario `:image_input`, offered only for a provider that declares `:image_input`: one user message with a text part and one PNG image part from a Need double, and a stub completion. `check/3` asks for one request, as today. The Level 2 providers run it.

`piece.json` and the README state amendment 2: the contract text, the limit "vision and document input ... are not supplied" narrowed to "document, audio and video input and image output are not supplied", the new tag, the Need, the bounds and the claim of the tests.

## Kept open (owner's "no corner" rule)

The part type set, the media type set, the capability set, the Config map and the refusal set may gain members in place before the first release.

- *Documents* (Q7 B), as a part type; *audio and video input*; *image output*.
- *Inline bytes* for small images, as a part form with its own bound inside the canonical request.
- *An `:images` counter computed by the interface* from the parts sent, beside the provider's report.

## Acceptance

1. **Golden, recorded on the base first:** before any change, record in the test file the canonical bytes of a text-only request of each role and option that the request codec test uses, and the wire term that the test provider's `translate/2` gives for it. After the change the same requests give the same bytes and wire term, and admission and the Adapter give the same results.
2. A request with two image parts and a text part to a stub provider that declares `:image_input`: admission succeeds with the canonical request holding references only; the Adapter calls the Need twice, the provider's `translate/2` gets the bytes in order, and one call is made.
3. The same request to a provider that does not declare `:image_input`, and to a Config with no `artifacts` Need: `unsupported_feature`, with no Need call.
4. Each bound at its edge: 8 image parts accepted and 9 refused; an image of `max_image_bytes` accepted and of one byte more `too_large`; a total at `max_total_image_bytes` accepted and over it `too_large`; `parts` of 64 and 65; each media type of the set accepted and `image/svg+xml` refused.
5. A hash mismatch (the Need returns bytes with one byte changed), a size mismatch, another `artifact_id` or `version` in the record, a missing artifact (`{:error, :not_found}`), a Need that raises: at admission `input_unavailable` with no intent; a Need that answers at admission and fails at dispatch gives the attested no-send `input_unavailable`, and `Retry.next/4` returns `{:retry, _}` for it. A media type mismatch is `invalid_request`.
6. A `"document"` part, a `parts` message of another role, a message with `text` and `parts`, and a `parts` message with text parts only: refused as stated.
7. The outcome table equals the Cure decision with the new tag (`Outcome.verify/0`), and the classification test covers `input_unavailable`.
8. No image byte in the intent's arguments, in a refusal, in an outcome or in `inspect` of the Config.
9. The `:image_input` conformance scenario passes with the stub provider; `integration/ai-text-anthropic` and `integration/ai-text-openai` tests pass unchanged (the small gate runs the dependents).
10. Negative controls, one at a time, each restored before the final gates: skip the capability check (case 3's undeclared case reaches the Need); skip the hash check (case 5's mismatch case is sent); mark `input_unavailable` dispatched (case 5's retry case fails).

Run the Piece tests and the small gate locally (`mix check --piece "$(git merge-base origin/main HEAD)"`), which runs the ready dependents, the roadmap and claims checks and the diff check. The full independent review of the coordinator guide, the exact-head hosted check and the merge queue are required.

## Limits to state

The artifact Need, its caller and its access check are the host's; the interface checks only that the bytes match the record it is given. A changed artifact cannot change an admitted request, because versions are immutable, but a deleted one makes the dispatch fail `input_unavailable`. Up to 20 MiB of images are read into memory per call, twice (admission and dispatch). No image-capable provider is part of this task, so no provider's image handling is evidenced here. No documents, audio, video, image output or inline bytes.
