# integration/ai-batch

The batch job mode of the `integration/ai-model` family for text requests:
submit a bounded set of `integration/ai-text` requests under caller-chosen item
ids, read the job's state, read bounded result pages joined by item id, and
cancel. Provider Pieces (the first is `integration/ai-batch-anthropic`) implement
`Elzoo.AiBatch.Provider`; a consumer copies the interface plus only the providers
it uses. Uses the family core's `job_ref` and `job_state`. Apache-2.0.

## Operations

| Operation | Kind | Path |
| --- | --- | --- |
| `submit` | write | `admit_submit/2`, then the `delivery/effect-intent` owner with a submit Binding (`Elzoo.AiBatch.SubmitAdapter`) |
| `cancel` | write | `admit_cancel/2`, then the owner with a cancel Binding (`Elzoo.AiBatch.CancelAdapter`) |
| `status` | read | `status(config, job_ref)`, call-scoped |
| `results` | read | `results(config, job_ref, cursor, join)`, call-scoped |

### Construction

`Elzoo.AiBatch.configure/1` builds the trusted Config: `submit_binding` and
`cancel_binding` (modules using `Elzoo.AiBatch.Binding` with `operation: :submit`
and `:cancel`; the provider account enters the intent key), `tenant`, `provider`
and its `provider_config`, the injected credential Need, the **submission store
capability** (`submissions: {module, server}`, see below), the model allowlist, the result sink and the
bounds: `max_output_tokens` (per item), `max_items` (1 to the provider's cap),
`max_create_wire_bytes` (1 to the provider's cap, measured on the exact encoded
create body), `max_submission_bytes`, `max_item_bytes` (at most 65,536),
`page_size` (1..1,000), `max_line_bytes`, `max_scan_bytes` and
`receive_timeout_ms`. Fixed for the Config's lifetime.

### Submit

The declaration (capability `integration/ai-batch`, operation `submit`, command
schema `elzoo/ai-batch-submission` v1, explicit `idempotency_key` = the dispatch
identity, deadline) carries `{"version": 1, "model", "items": [{"item_id",
"request"}], "provider_options"?}`. Item ids match `^[A-Za-z0-9_-]{1,64}$` and are
unique; every item uses the submission's model; each request is decoded and
checked by the text interface (`Elzoo.AiText.Request.decode/2`,
`Elzoo.AiText.check/2`, the item provider's pure translation), so an item is
admitted exactly when the same synchronous request would be. Provider options
are declared by the provider and validated; anything else is `invalid_request`.

`admit_submit/2` prepares the provider's create body **once** and returns
`{:ok, %{key, identity, arguments, deadline, binding_digest, manifest_digest,
staged, submission}}` or `{:error, {:refused, reason, %{retry_after: nil,
orphans: []}}}` (`invalid_request | unsupported_feature | too_large`) **before any
intent, credential read or request**, or `{:error, :declaration}`.

**Manifest arguments and the submission store.** The EffectIntent arguments are
bounded at 65,536 bytes and its `adapter_context` lives in owner state, so the
intent arguments are a canonical manifest `{version, model, item_count,
wire_bytes, wire_sha256, provider_meta}` naming the **exact provider create
body** (`staged`) and the provider's non-secret request metadata (for Anthropic,
the outer beta header value). The host stages `staged` in its store
(`Elzoo.AiBatch.Staging.put(staging, admission)`) and configures `submissions:
{Elzoo.AiBatch.Staging, pid_or_name}`. `configure/1` accepts only `{module,
server}` with `module` implementing `Elzoo.AiBatch.SubmissionStore` and `server` a
pid or a registered name; a function or any other term is refused, so the Config
(the owner's `adapter_context`) cannot hold staged bytes or a closure capturing
them. Inside the send task, before the credential is read, the Adapter fetches
the body for its intent key, binding digest and manifest digest, checks its length
and SHA-256 against the manifest and hands **exactly those bytes** to the
provider's `submit/2`; nothing is translated or encoded at dispatch. A missing or
substituted body sends nothing and is reported `unknown{provider_error}`: the
failure table attests no-send only for credentials. After a host restart the staged
bytes are gone unless the host persisted them. SHA-256 collision resistance is an
upstream assumption. `submission` (the canonical submission) is what the caller
keeps to build its result join.

Delivered outcome (volatile sink, once per attempt):
`{:submitted, %{job_ref, item_count, orphans}}`,
`{:refused, reason, %{retry_after, orphans}}` (`credentials_unavailable |
invalid_request | too_large | authentication_failed | permission_denied |
not_found | throttled | overloaded`) or `{:unknown, reason, %{orphans}}`
(`timeout | transport | malformed_response | provider_error`). `orphans`
(`%{kind, provider_ref}`) lists provider files a multi-step provider left behind
when creation was refused or unknown; it is present on every outcome.

### Cancel

The declaration (operation `cancel`, schema `elzoo/ai-batch-cancel` v1,
`idempotency_key` = the caller's cancel identity, at most 120 bytes) carries
`{"version": 1, "job_ref": {...}}`. The intent identity joins the provider job id
and the cancel identity, so one cancel identity names one job. Outcomes:
`{:cancelled, job_state}` (the provider acknowledged), `{:refused, reason,
%{retry_after}}` or `{:unknown, reason}`; a timeout or connection loss after the
request was sent is `unknown`, never "not cancelled". A status observation of
`:ending` or `{:ended, _}` lets the caller decide its business state but is **not**
a ground: it does not prove that this attempt caused it.

### Failure table and retries

Submit and cancel use ELZ-079's Cure decision `Elzoo.AiTextOutcome` unchanged
(both Bindings compile its static table; `configure/1` checks it against Cure).
Only `credentials_unavailable` is attested no-send and may be retried after
`:rearm` (`Elzoo.AiText.Retry.next/4`); `throttled` and `overloaded` are
failed/dispatched/retryable and **not** redispatched by default (ELZ-079
amendment 1); `unknown` is never retried. A lost submit or cancel stays unknown:
the owner refuses a second dispatch of the same identity without a ground, and no
provider in this slice offers a caller tag or receipt to reconcile by.

### Status and results

`status/2` returns `{:ok, %{state: job_state}}` or `{:error, reason}`,
`reason` in `read_reasons/0`. `results/4` returns `{:ok, %{items, next, join}}`
or `{:error, reason}`, `reason` in `results_reasons/0` (adds `malformed_page`,
`result_line_limit`, `result_scan_limit`).

- `cursor` is the ordinal of the first result line; it must equal the join's next
  cursor (pages are contiguous). `next` is the following cursor or `:done`.
- Every byte read in one call, including lines skipped before the cursor, counts
  against `max_scan_bytes`; a line over `max_line_bytes` is `result_line_limit`.
  A provider without paging re-reads from the start each page, so under a scan
  bound smaller than the result file a deep cursor is `result_scan_limit`.
- Items: `{item_id, {:succeeded, completed} | {:errored, class} | :cancelled |
  :expired}`; `class` is `invalid_request | provider_error | malformed_response`
  (a succeeded result that fails decoding may have been billed).
- `Elzoo.AiBatch.Join` (pure, carried by the caller, built from the submitted
  submission) joins by item id only: an unknown id or one already seen in this or an
  earlier page refuses the whole page with the join unchanged. `Join.missing/2`
  returns the absent ids only after `:done` of an `{:ended, _}` job; a missing
  item is never succeeded.
- `completed` is the text interface's `completed{content, tool_proposals,
  structured, finish, usage, provenance}`, built by `Elzoo.AiBatch.Completion`
  with the same checks as the synchronous Adapter (the ready text interface is
  unchanged); per-item usage is the family usage value (`:unknown`, never zero);
  no price is computed.

## Invariants

- One request per submit, cancel, status and results call.
- The credential comes only from the injected Need and never appears, with a
  prompt or output, in a result, error, inspect value, log, owner state or event;
  the staged bytes never appear in owner state (checked on the external term
  format of the owner state, which includes function environments).
- The bytes sent on submit are byte-identical to the body the admission manifest
  names.
- Tool proposals are inert data; structured output is validated.

## Conformance kit

`Elzoo.AiBatch.Conformance` holds provider-neutral scenarios (submit accepted,
lost and throttled; a status sequence; mixed, unknown-id, duplicate-id and
missing results; cancel accepted and lost; 401 and 404) and plain checks. A
provider's own test realizes each stub meaning in its documented format.

## Grounding, operations and limits

- Type/contract check: pinned Cure compiles the reused outcome decision; both
  Bindings' static table is checked equal to it at construction.
- Tests (`test/elzoo/ai_batch_test.exs`, scripted providers, volatile Memory
  store): the operations, refusals and bounds above, orphans, lost writes and
  refused second dispatches, staging, every job state, joins, bounds, a
  completion equality corpus against the synchronous text path (text, finishes,
  tool proposals well-formed and malformed, structured valid, invalid and
  missing, usage absent, request id absent, malformed responses), redaction and
  a source audit. Finite scenarios, not proofs; equality is claimed for the corpus
  only.
- Upstream: the ready `core/effect`, `delivery/effect-intent`,
  `delivery/retry-timeout`, `integration/ai-model` and `integration/ai-text`
  Contracts; Cure, Elixir 1.20.4, OTP 29.1.2 (`:crypto`).
- Telemetry `planned`; Config `supported` at construction only; Control
  `not_applicable` (the owner's Control covers dispatch, rearm and expiry; cancel
  is a request to the provider, not a local drain).
- Not supplied: poll scheduling, durable job storage, webhooks, embeddings or
  other endpoints in batch, cost computation, retention beyond the provider's
  window.
