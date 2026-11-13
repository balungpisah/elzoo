# workflow/context-compaction

`Elzoo.ContextCompaction` is a pure pattern step that asks a model for one
summary of a range of history and carries the keep-rule records of the range
beside the summary. It gives one `model_call` action; it deletes and stores
nothing. Functions: `open/2`, `accept/2`, `check/2`.

## Model-call vocabulary

The action has kind `model_call`, schema key `elzoo/ai-text-request` version 1
and the decoded ai-text request object as payload. A completed outcome has the
schema key `elzoo.ai-text.result` version 1; its payload holds `content`,
`structured` and `finish`. This step reads `content` and `finish`.

## `open(input, estimate)`

`input` has exactly these atom keys: `action_id` (unique in the Run, kept by the
caller), `entries` (1 to 256 history entries of `workflow/prompt-assembly`: the
range), `model`, `max_output_tokens`, `role_instructions` (how to summarize,
written by the host), `window`, `max_request_bytes`, and `summary`
(`%{id: id, source: text, max_bytes: n}`). A `source` outside the source grammar
of `workflow/untrusted-content`, a `max_bytes` outside 1..16,777,216 or an `id`
that an entry of the range already has is `:invalid_input` (this keeps the IDs
of `compacted.entries` unique).

The `:record` entries are carried as they are and never sent to the model; a
record that is not a JSON object is `:invalid_input`. The
other entries are built into the summary request by
`Elzoo.PromptAssembly.build/2` with no skill instructions, memory or tools and
`max_image_refs` 256. A build that drops an entry gives `{:error, :over_limit}`
(take a shorter range); a range with no free text gives
`{:error, :nothing_to_summarize}`; each other build error comes back unchanged.

Result: `{:ok, state, request}`, where `request` is a neutral request of
`workflow/pattern-step` with exactly one action (`id` = `action_id`) and
`state` is plain data that the caller keeps.

## `accept(state, input)`

`input` is a neutral input map of `workflow/pattern-step`; the action is settled
through `PatternStep.open/1` and `PatternStep.accept/2`.

- `{:late, state}`: an outcome of another action, or a late outcome.
- `{:error, :invalid_input}`: a map that `PatternStep.decode/1` refuses, or a
  map that is not an input (a request);
  `{:error, :not_an_outcome | :incompatible_answer_kind}` as `PatternStep.accept/2` refuses.
- `{:error, {:model_call, outcome}}`: an outcome class other than `"completed"`;
  `outcome` is the class as text, for example `"failed"`.
- `{:error, :invalid_summary}`: another schema key, `finish` other than `"stop"`,
  or `content` that is not a nonempty UTF-8 text of at most `summary.max_bytes`.
- Otherwise `{:ok, compacted}`:

      %{entries: [record_entry, ..., %{kind: :content, id: summary.id, content: marked_map, ref_media_type: nil}],
        derived_from: [%{item_id: id, version: 1}, ...]}

  The records are those of the range, unchanged and in order. The marked map
  has the one source `summary.source`, the class `derived`, the bound
  `summary.max_bytes` and the answer as content. `derived_from` names each
  summarized entry in order, in the reference form of
  `workflow/context-selection`. `entries` can take the place of the range.

## `check(entries, compacted)`

`:ok`, or `{:error, {:keep_items_lost, ids}}` with the IDs of the `:record`
entries of `entries` that are not in `compacted.entries`. `accept/2` runs it on
its own result. A host that reads a compacted value from a record runs it again
before the value replaces history. In each error case there is no compacted
value and the caller keeps the original history.

## Grounding

`mix test pieces/workflow/context-compaction/test` runs the named group
`compaction` and the open refusals with literal inputs. Negative control: an
`accept/2` that leaves out the first record fails `compaction` with
`keep_items_lost`. Finite scenarios, not a proof. `workflow/pattern-step`,
`workflow/untrusted-content` and `workflow/prompt-assembly` keep their own
Contracts; no Cure law is claimed.

## Needs and limits

Needs: the caller keeps `action_id` unique and keeps the state and the original
history; stamps the summary source truthfully; supplies a pure estimate; its
model binding gives a completed outcome in the vocabulary above.

Limits: no rule that decides when to compact; no claim about summary quality;
no claim that marking prevents prompt injection.

Telemetry and Control are not applicable: pure functions, no observations and
no process; the engine records the intent and the outcome. Config is supported
per call only: `max_request_bytes` and the window with its estimate come in the
input; no default, stored setting or hot change. `summary` describes the summary
entry and is data, not Config.
Module `Elzoo.ContextCompaction` is application-owned after copying.
Apache-2.0; no new dependency or pin.
