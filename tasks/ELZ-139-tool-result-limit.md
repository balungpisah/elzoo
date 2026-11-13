# ELZ-139 — Bounded tool results

## Scope and reuse

- Dependencies: ELZ-033, ELZ-096, ELZ-137, ELZ-114, ELZ-023, ELZ-009
- Output: `workflow/tool-result-limit`; release V1B; bot-platform level 2.
- Owned paths: `pieces/workflow/tool-result-limit/**` and its index/generated changes under AGENTS.md section 3.

A tool result that is larger than a declared bound does not go whole to a model. It is kept whole as an Artifact, and the pattern goes on with a reference and a bounded preview. This Piece holds two things: the pure decision, and the `delivery/effect-intent` Adapter for the one outside write, the put of `state/artifact`. The result is a marked value of ELZ-137 at every step.

Implement only the acceptance groups below. Add no options, layers, behaviours, generic helpers or future hooks: no tool that reads an Artifact, no reconciliation service, no result sink, no engine code, no summary. Change no ready Piece, shared path, dependency pin or CI file. The independent reviewer flags extra features for removal.

## The record bound of the engine (agreed with ELZ-127)

The ready `assembly/run-engine` records an outcome payload only when its compact JSON has at most 65,536 bytes and a depth of at most 32. For a larger one it records the outcome `unknown` with the reason `outcome_too_large`, and the content is not in the record (README, "Failure, size and audit limits"). The engine also has one result schema key for each action kind. So:

- The cut stays in this Piece for every result that the engine recorded. Such a result is in the record before the cut, and the Adapter reads it there.
- A result that the engine did not record never reaches this Piece. To bound a result before the engine records it is a rule of the host's result sink. This task does not build that rule.
- The receipt of the store action has fixed fields and no schema key of its own. The host puts it under the key that its `tool_call` binding declares.

## Pure decision: `Elzoo.ToolResultLimit`

Two functions. No clock, storage or process.

A result is a map with exactly three string keys:

    %{"content" => marked_map, "media_type" => "text/plain", "encoding" => "utf8"}

`content` is the neutral map of ELZ-137. `media_type` is a media type as `state/artifact` takes it: UTF-8, no NUL, 1 to 256 bytes. `encoding` is `"utf8"` or `"base64"`. With `"base64"` the content text is the padded base64 of the bytes of a binary result. The bytes of a result are its content bytes, or the decoded bytes. `size_bytes` and `sha256` (lowercase hexadecimal) are taken over those bytes.

`decide(result, limits, source_action_id)`. `limits` is `%{max_bytes: n, artifact_max_bytes: m}`. `n`, from 1,024 to 1,048,576, is the declared bound. `m`, a positive integer, is the `max_bytes` of the Artifact store, which the host states. `source_action_id` is the ID of the tool-call action whose recorded outcome holds the result.

- Text of at most `max_bytes` bytes: `{:ok, %{"content" => marked_map, "cut" => nil}}`, with the same map, unchanged.
- Text over `max_bytes`, and each binary result, of at most `artifact_max_bytes` bytes: `{:store, pending, payload}`. `payload` is the payload of one `tool_call` action under the schema key `elzoo.tool-result-limit.store` version 1. It has exactly the keys `source_action_id`, `sha256`, `size_bytes`, `media_type` and `encoding`, and it never holds content. The caller gives the action its ID. `pending` is plain data (no function, PID or reference) that the caller keeps until the outcome and passes back unchanged.
- A result of more than `artifact_max_bytes` bytes: `{:ok, bounded}` with the note `over_artifact_max`, and no store action.
- `{:error, :unmarked}` when `content` does not pass `Elzoo.UntrustedContent.decode/1`. `{:error, :invalid_input}` for each other malformed operand, base64 that does not decode included. No error holds content.

A skill file is a tool result of a `pinned_skill` source: it is marked content and is cut like any other result. The SKILL.md instruction body is an instruction and has no mark, so it is not a result: `decide/3` refuses it as `:unmarked` and cuts nothing. The caller (ELZ-142) never passes it, and refuses an instruction load over its own bound.

`settle(pending, outcome, receipt)` returns `{:ok, bounded}`. `outcome` is the outcome class of the store action, one of the words of `workflow/pattern-step`. `receipt` is the payload of a `completed` outcome, or `nil`.

- `completed` with a receipt of exactly the keys `artifact_id`, `version`, `sha256`, `size_bytes` and `media_type`, where `sha256` and `size_bytes` equal the pending ones: the bounded value holds the reference.
- `completed` with any other receipt, and `unknown`: the note `store_unknown`.
- `late`: `{:error, :invalid_input}`. A late outcome is never applied.
- Each other class: the note `store_refused`.

A bounded value is `%{"content" => marked_map, "cut" => cut}`. `cut` is `nil`, or a map with exactly the keys `size_bytes`, `sha256`, `media_type`, `preview_bytes`, `artifact` and `note`. `artifact` is `%{"artifact_id" => id, "version" => v}` or `nil`. `note` is `nil`, `"over_artifact_max"`, `"store_refused"` or `"store_unknown"`. Exactly one of the two is `nil`. So the cut is visible in the value, and also in its content: the content of a cut value is one notice line, and for text a line feed and the preview after it.

    [cut: first P of N bytes shown; whole result: artifact ID version V]
    [cut: first P of N bytes shown; whole result not stored: NOTE]
    [binary result: N bytes, MEDIA_TYPE; artifact ID version V]
    [binary result: N bytes, MEDIA_TYPE; not stored: NOTE]

The preview is the longest prefix of the content that has at most `max_bytes - 512` bytes and ends at the boundary of a UTF-8 code point. A binary result has no preview. So the content of a bounded value never has more than `max_bytes` bytes, and it never holds the full result. The new marked map is made through `encode/1` and `decode/1` of ELZ-137: `content` changes, `max_bytes` becomes the declared bound, and `sources` and `trust` are never written.

## The Adapter for the put: `Elzoo.ToolResultLimit.Adapter`

It implements the Adapter callbacks of `delivery/effect-intent` (README, "Binding and provider Needs"). It also exports `failures/0` and `no_send/0` for the host's `use Elzoo.EffectIntent.Binding`, and `arguments(payload, stream, sequence)`.

`arguments/3` gives the canonical argument bytes of an intent: one JSON object with sorted keys and no white space, with exactly `version` (1), `stream`, `sequence`, `sha256`, `size_bytes`, `media_type` and `encoding`. `stream` and `sequence` name the record of `state/event-log` that holds the outcome. `delivery/effect-intent` refuses arguments over 65,536 bytes; these never hold a result. `validate/2` accepts only this form.

The Adapter context is a map that the host fixes when it starts the intent owner. It has exactly these keys, all required, with no default:

- `log`: the Store tuple of the log. `extract`: a pure function of arity 1 from the payload binary of a log record to `{:ok, result}` or `:error`; the host knows the record layout of its engine.
- `artifact`: the value of `Elzoo.Artifact.new/1`. `caller`: `%{tenant, principal, scopes}`. `access`, `access_expires_at_unix_ms`, `retain_until_unix_ms`: the access terms and the retention of the caller of the Run.
- `sink`: a trusted function of arity 2. `seal_key`: 32 random bytes of the host, never stored.

`send_effect/1` does these steps in order and repeats none:

1. Read with `Elzoo.DurableLog.read(log, stream, sequence, 1)`. The row must have that sequence, and the sequence must not be above `head.revision`: a staged tail is not a record.
2. Give `row.payload` to `extract`. The result must have the `media_type` and the `encoding` of the arguments, and its bytes must have their `size_bytes` and `sha256`.
3. Call `Elzoo.Artifact.put(artifact, caller, key, input)` one time. `key` is the intent key, and it is the `artifact_id`: 64 lowercase hexadecimal characters, a valid ID segment of `state/artifact`, one for each logical request. `input` holds the bytes, the media type and the three terms of the context.
4. On `{:ok, record}` make the receipt `%{"artifact_id", "version", "sha256", "size_bytes", "media_type"}` from the record, with `"sha256"` the SHA-256 of the bytes checked in step 2 (the record's own `sha256` is the SHA-256 of `<<hash_format::8, bytes>>`, so it is never copied), call `sink.(key, {:receipt, attempt_id, receipt})`, then return the completed result. Its value holds only the SHA-256 of the canonical receipt and an HMAC-SHA-256 seal over the key, the attempt ID and that digest under `seal_key`. The intent store keeps a digest, so the receipt reaches the host only through the sink. A failure of the sink does not change the result.

| Tag | When | Result / dispatch / error class | Attests that `put` was not called |
| --- | --- | --- | --- |
| `invalid_arguments` | the arguments are not the canonical form | `rejected` / `not_dispatched` / `permanent` | yes |
| `record_unavailable` | the read fails; the record is pruned, absent or above the committed head; `extract` gives no result | `timed_out` / `not_dispatched` / `unavailable` | yes |
| `digest_mismatch` | step 2 finds a difference | `rejected` / `not_dispatched` / `permanent` | yes |
| `store_refused` | `put` returns `:too_large`, `:invalid`, `{:invalid, _}`, `:access_denied`, `:expired`, `:deleted` or `{:object_store_refused, _}` | `failed` / `dispatched` / `permanent` | no |
| `store_unknown` | each other return of `put`, and a raise, a throw or an exit in it | `unknown` / `dispatched` / `unclassified` | no |

`put` stages and then commits, so a refused `put` can leave a staged version. Only the first three tags attest that nothing was written. `validate_result/2` accepts a completed value only for this request, and `authenticate/2` only with a valid seal. `poll/1` returns `{:unavailable, :no_status}`: an unknown put stays unknown and leaves uncertain staging, and the Adapter never puts a second time. No failure detail holds content or a term of the store.

## Needs and limits

Needs. The caller (ELZ-142) applies `decide/3` to each tool result and never to an instruction body, sends the store payload as a `tool_call` action that the tool list of the model never shows, and keeps `pending`. The engine checks and performs that action like every other action. The host binding makes the five-field intent identity and the canonical arguments from the payload: it finds the record (`stream`, `sequence`) of the applied outcome of `source_action_id`. The host gives the receipt from the sink to the engine as the outcome payload. The host states `artifact_max_bytes`, `media_type` and `encoding` truthfully and does not prune the log stream while a store action is open. Activation, reconciliation and fencing are as `delivery/effect-intent` and `state/artifact` say; the host reconciles uncertain staging with `Elzoo.Artifact.status/3`.

Limits. No bound on a result before the engine records it (see above). No tool that reads an Artifact back for a model. No reap and no reconciliation of staging. No scan of stored bytes. The preview is a prefix, not a summary. Telemetry: none of its own. Config: the limits of a call and the context of an owner, fixed. Control: not applicable.

## Acceptance groups

Use the Memory Store of `state/event-log` with a test record layout and a test `extract`, a real `Elzoo.Artifact` over it, and a real `Elzoo.EffectIntent` owner with `allow_volatile: true`. For the object store use the loopback double of the test support of `state/artifact` (`artifact_test_helper.exs`: `fake_s3/0`, `fake_fail/3`), required by the two-location path that the tests of `state/audit-log` use for a helper of another Piece. No MinIO, no credential and no recorded provider fixture is used; each result is a literal neutral map.

1. **`under_bound_unchanged`**: text of `max_bytes` bytes and less gives the same marked map, byte for byte, with `cut` `nil` and no store payload.
2. **`over_bound_reference_and_preview`**: text of `max_bytes + 1` bytes gives a store payload with the five keys and no content. Through the owner and the Adapter the Artifact then holds the whole bytes, and `settle/3` gives the reference notice and the preview. A fixture with a character of several bytes at the cut point shows the code-point boundary. The content has at most `max_bytes` bytes. For a result of 60,000 bytes the intent arguments have less than 1,024 bytes.
3. **`skill_file_cut_body_never`**: a marked skill file over the bound is cut like any result. An instruction body, as plain text in `content` and as a map with no valid mark, is refused `:unmarked`, and no value comes back.
4. **`binary_by_reference_only`**: a base64 result smaller than `max_bytes` is never passed whole. After the store its content is the binary notice alone, and the Artifact holds the decoded bytes with the media type. Base64 that does not decode is `:invalid_input`.
5. **`store_refused_unknown_or_too_large`**: with a 403 of the object store the tag is `store_refused` and the note is `store_refused`. With a 500 the tag is `store_unknown`, the note is `store_unknown`, the staging stays uncertain and the double sees no second put. A result over `artifact_max_bytes` gives the note `over_artifact_max` with no store payload. An absent record, a record above the committed head and a record with other bytes give a no-send tag, and the double sees no request. In each case the value holds the preview and the named note, at most `max_bytes` bytes, never the full result.
6. **`mark_survives_cut`**: for each result of groups 2, 4 and 5, with each class and with two sources, the `sources` and `trust` of the bounded content equal those of the input, and the content passes `decode/1` and `render/1` of ELZ-137.

Negative controls (edit temporarily, run, record the failure, revert): make `settle/3` return the whole content after a failed store, and group 5 must fail; remove the comparison of step 2, and the last case of group 5 must fail.

## Evidence

Keep the kinds apart. Proof: one selected Cure law, `whole_only_under_bound`: the production decision over three Booleans (text, over the bound, over the Artifact bound) gives the whole result only for text that is not over the bound. If the pinned compiler cannot check it, ask the coordinator; do not weaken the claim. Test: the six groups, finite scenarios on Memory and loopback doubles. They are not evidence of durability or of a real object store. Upstream: the Contracts of `state/artifact`, `delivery/effect-intent`, `state/event-log` and `workflow/untrusted-content`; OTP `:crypto`. Assumption: the Needs above. Byte counts, the UTF-8 cut, the hash and the Adapter are tested, not proved.

Run the Piece tests, then `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. One independent review checks this body, the exact diff and needless features.
