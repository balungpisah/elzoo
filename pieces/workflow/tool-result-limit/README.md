# workflow/tool-result-limit

A tool result that is larger than a declared bound does not go whole to a
model. It is kept whole as an Artifact, and the pattern goes on with a
reference and a bounded preview. The result is a marked value of
`workflow/untrusted-content` at every step. This Piece holds the pure
decision `Elzoo.ToolResultLimit` and the `delivery/effect-intent` Adapter
`Elzoo.ToolResultLimit.Adapter` for the one outside write, the put of
`state/artifact`.

## Pure decision: `Elzoo.ToolResultLimit`

No clock, storage or process. A result is a map with exactly three string keys:

    %{"content" => marked_map, "media_type" => "text/plain", "encoding" => "utf8"}

`content` is the neutral map of `workflow/untrusted-content`; `media_type` is
UTF-8, no NUL, 1 to 256 bytes; `encoding` is `"utf8"` or `"base64"` (padded
base64 of the bytes of a binary result). `size_bytes` and `sha256` (lowercase
hexadecimal) are taken over the content bytes or the decoded bytes.

`decide(result, %{max_bytes: n, artifact_max_bytes: m}, source_action_id)`,
with `n` from 1,024 to 1,048,576 and `m` a positive integer (the `max_bytes`
of the Artifact store, which the host states):

| Result | Value |
| --- | --- |
| text of at most `n` bytes | `{:ok, %{"content" => same_map, "cut" => nil}}` |
| text over `n`, or binary, of at most `m` bytes | `{:store, pending, payload}` |
| more than `m` bytes | `{:ok, bounded}` with the note `over_artifact_max` |
| `content` that `decode/1` refuses | `{:error, :unmarked}` |
| each other malformed operand (base64 that does not decode included) | `{:error, :invalid_input}` |

`payload` is the payload of one `tool_call` action under the schema key
`elzoo.tool-result-limit.store` version 1: exactly `source_action_id`,
`sha256`, `size_bytes`, `media_type` and `encoding`, never content. `pending`
is plain data that the caller keeps until the outcome and passes back
unchanged:

    %{"content" => marked_map_with_preview, "size_bytes" => _, "sha256" => _,
      "media_type" => _, "encoding" => _}

Its marked map holds the preview, the `sources` and `trust` of the mark and
the declared bound `n` as `max_bytes`; never content beyond the preview.

`settle(pending, outcome, receipt)` takes the outcome class of the store action
(a word of `workflow/pattern-step`) and the payload of a `completed` outcome or
`nil`:

| Outcome | Value |
| --- | --- |
| `completed`, receipt of exactly `artifact_id`, `version`, `sha256`, `size_bytes`, `media_type` with the pending `sha256` and `size_bytes` | `{:ok, bounded}` with the reference |
| `completed` with any other receipt, `unknown` | note `store_unknown` |
| `late`, a word that is not an outcome class, a malformed `pending` | `{:error, :invalid_input}` |
| each other class | note `store_refused` |

A bounded value is `%{"content" => marked_map, "cut" => cut}`; `cut` is `nil`
or exactly `size_bytes`, `sha256`, `media_type`, `preview_bytes`, `artifact`
(`%{"artifact_id", "version"}` or `nil`) and `note` (`nil`,
`"over_artifact_max"`, `"store_refused"` or `"store_unknown"`); exactly one of
`artifact` and `note` is `nil`. The content of a cut value is one notice line,
and for text a line feed and the preview:

    [cut: first P of N bytes shown; whole result: artifact ID version V]
    [cut: first P of N bytes shown; whole result not stored: NOTE]
    [binary result: N bytes, MEDIA_TYPE; artifact ID version V]
    [binary result: N bytes, MEDIA_TYPE; not stored: NOTE]

The preview is the longest prefix of at most `n - 512` bytes that ends at a
UTF-8 code point boundary; a binary result has no preview. The content of a
bounded value never has more than `n` bytes and never holds the full result.
The new marked map is made through `encode/1` and `decode/1`: `content`
changes, `max_bytes` becomes `n`, `sources` and `trust` are never written.

A skill file of a `pinned_skill` source is marked content and is cut like any
result. A SKILL.md instruction body has no mark: `decide/3` refuses it as
`:unmarked`.

## Adapter: `Elzoo.ToolResultLimit.Adapter`

The host binds it with `use Elzoo.EffectIntent.Binding, adapter:
Elzoo.ToolResultLimit.Adapter, failures: Adapter.failures(),
no_send_attestations: Adapter.no_send(), ...`.

`arguments(payload, stream, sequence)` gives `{:ok, bytes}`: one JSON object
with sorted keys and no white space, with exactly `version` (1), `stream`,
`sequence`, `sha256`, `size_bytes`, `media_type` and `encoding`, where
`stream` and `sequence` name the `state/event-log` record of the outcome; or
`{:error, :invalid_input}`. It never holds a result. `validate/2` accepts only
this form.

The Adapter context, fixed by the host when it starts the intent owner, has
exactly `log` (Store tuple), `extract` (pure function of a log payload binary
to `{:ok, result}` or `:error`), `artifact` (`Elzoo.Artifact.new/1`), `caller`,
`access`, `access_expires_at_unix_ms`, `retain_until_unix_ms`, `sink` (trusted
function of arity 2) and `seal_key` (32 random bytes, never stored).

`send_effect/1`, in order and with no repeat: reads the record with
`Elzoo.DurableLog.read(log, stream, sequence, 1)` (that sequence, not above
`head.revision`); checks the extracted result against the media type,
encoding, size and SHA-256 of the arguments; calls `Elzoo.Artifact.put/4` one
time with the intent key (64 lowercase hexadecimal characters) as the
`artifact_id`; on `{:ok, record}` builds the receipt (its `sha256` is the
SHA-256 of the checked bytes, never the record's own), calls
`sink.(key, {:receipt, attempt_id, receipt})` and returns a completed result
whose value holds only `receipt_sha256` and an HMAC-SHA-256 `seal` over the
key, the attempt ID and that digest. A failure of the sink does not change the
result.

| Tag | When | Outcome / dispatch / error class | `put` not called |
| --- | --- | --- | --- |
| `invalid_arguments` | arguments not canonical | `rejected` / `not_dispatched` / `permanent` | yes |
| `record_unavailable` | read fails; record pruned, absent or above the committed head; `extract` gives no result | `timed_out` / `not_dispatched` / `unavailable` | yes |
| `digest_mismatch` | the check of step 2 finds a difference | `rejected` / `not_dispatched` / `permanent` | yes |
| `store_refused` | `put` returns `:too_large`, `:invalid`, `{:invalid, _}`, `:access_denied`, `:expired`, `:deleted` or `{:object_store_refused, _}` | `failed` / `dispatched` / `permanent` | no |
| `store_unknown` | each other return of `put`, a raise, throw or exit | `unknown` / `dispatched` / `unclassified` | no |

A refused `put` can leave a staged version; only the first three tags attest
that nothing was written. `validate_result/2` accepts a completed value only
for this request, `authenticate/2` only with a valid seal. `poll/1` returns
`{:unavailable, :no_status}`: an unknown put stays unknown, and the Adapter
never puts a second time. No failure detail holds content or a term of the
store.

## Grounding

- Proof: `whole_only_under_bound` in `cure/elzoo/tool_result_limit.cure`: the
  production decision over three Booleans (text, over the bound, over the
  Artifact bound) gives `Whole` exactly for text that is not over the bound.
  It says nothing about byte counts, the UTF-8 cut, the hash or the Adapter.
- Test: `mix test pieces/workflow/tool-result-limit/test` runs the groups
  `under_bound_unchanged`, `over_bound_reference_and_preview`,
  `skill_file_cut_body_never`, `binary_by_reference_only`,
  `store_refused_unknown_or_too_large` and `mark_survives_cut`, plus malformed
  operands, the law check with the source audit and the checked example. They
  use the Memory Store of `state/event-log`, a real `Elzoo.Artifact` over the
  loopback S3 double of `state/artifact` and a real `Elzoo.EffectIntent` owner
  (`allow_volatile: true`). Finite scenarios, not evidence of durability or of
  a real object store. Negative controls: a `pending` that keeps the whole
  content and a `settle/3` that returns it after a failed store fail
  `store_refused_unknown_or_too_large`; without the comparison of step 2 its
  last case fails.
- Upstream: the Contracts of `state/artifact`, `delivery/effect-intent`,
  `state/event-log` and `workflow/untrusted-content`; OTP `:crypto`; Jason.

## Needs and limits

Needs: the caller applies `decide/3` to each tool result and never to an
instruction body, sends the store payload as a `tool_call` action that the
tool list of the model never shows, and keeps `pending`. The host binding
makes the five-field intent identity and the canonical arguments from the
payload, finding the record (`stream`, `sequence`) of the applied outcome of
`source_action_id`; it gives the receipt from the sink to the engine as the
outcome payload; it states `artifact_max_bytes`, `media_type` and `encoding`
truthfully, does not prune the log stream while a store action is open, and
reconciles uncertain staging with `Elzoo.Artifact.status/3`.

Limits: no bound on a result before the engine records it (a rule of the
host's result sink). No tool that reads an Artifact back for a model. No reap
and no reconciliation of staging. No scan of stored bytes. The preview is a
prefix, not a summary.

Telemetry: none of its own. Config: the limits of each `decide/3` call and the
Adapter context of an owner, fixed at its start; no hot change. Control: not
applicable. Modules are application-owned under `Elzoo.ToolResultLimit` and
`Cure.Elzoo.ToolResultLimit`. Apache-2.0; no new dependency or pin.
