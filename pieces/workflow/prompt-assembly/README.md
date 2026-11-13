# workflow/prompt-assembly

`Elzoo.PromptAssembly.build(input, estimate)` builds one `integration/ai-text`
request from instructions, selected memory, history and a tool list. It keeps
one declared order and one declared drop order, inside a token limit and the
hard bounds of ai-text. It is pure: no clock, network, storage or process. The
token estimate is a host Need: a function that the caller supplies.

## Input

`input` is a map with exactly these atom keys:

| Key | Value |
| --- | --- |
| `model`, `max_output_tokens` | the members of the ai-text request |
| `role_instructions` | at least one text: the role instructions of the recipe |
| `skill_instructions` | texts, possibly none: named skill instructions, only from a tool source of kind `pinned_skill` |
| `memory` | `%{id: id, content: marked_map}` in selection order (already selected by `workflow/context-selection`) |
| `history` | entries in time order (below) |
| `tools` | maps in the ai-text tool shape; they go into the request unchanged |
| `window` | a window of `workflow/context-selection` with `unit: :tokens`; its `size` is the token limit |
| `max_request_bytes` | 1 to 65,536, the host's ai-text Config |
| `max_image_refs` | 0 to 256 |

`estimate` has arity 1. It takes canonical request bytes and returns `:error`
or `{:ok, %{size: n, unit: :tokens, direction: :upper_bound | :approximate,
estimator_id: id, estimator_version: v}}`; the estimator fields equal those of
`window`. It is never stored.

History entries (exact keys; each `id` is 1 to 1,024 bytes and unique in
`memory` and `history`; each `marked_map` is the neutral map of
`workflow/untrusted-content`):

    %{kind: :user, id: id, text: text}
    %{kind: :assistant, id: id, text: text, tool_calls: [%{"id" => _, "name" => _, "arguments" => %{}}]}
    %{kind: :tool_result, id: id, tool_use_id: text, content: marked_map, ref_media_type: nil | text}
    %{kind: :content, id: id, content: marked_map, ref_media_type: nil | text}
    %{kind: :record, id: id, keep: :goal | :open_action | :decision | :failed_approach, record: json_object}

An entry whose `ref_media_type` starts with `image/` is an image reference.

## Declared order

The request has `version`, `model`, `max_output_tokens`, `messages` and, when
the list is not empty, `tools`. Its messages:

1. One `system` message: each role instruction, then each skill instruction,
   joined by one empty line.
2. When `memory` is not empty, one `user` message: the rendered block of each
   item, joined by a line feed.
3. One message per history entry: `:user` gives a `user` message with the text;
   `:content` a `user` message with the rendered block; `:assistant` an
   `assistant` message with the text and, when not empty, `tool_calls`;
   `:tool_result` a `tool_result` message with `tool_use_id` and the rendered
   block; `:record` a `user` message with the canonical JSON of
   `%{"keep" => kind, "record" => record}`.

A rendered block is the text of `Elzoo.UntrustedContent.render/1`. Marked
content appears in no other form.

## Rules

A unit is an `:assistant` entry with the `:tool_result` entries that follow it
directly; each other `:user`, `:content` and `:assistant` entry is a unit
alone; a `:record` is in no unit.

1. Of the image references, the newest `max_image_refs` stay. Each older one
   gets the text `[image reference removed]` with the same sources and trust
   and the larger of the old bound and that text's size. The message stays.
2. Build, encode with `Request.canonical/1` and check: at most 256 messages,
   `Request.decode/2` with `max_request_bytes` accepts the bytes, and the
   estimate `size` is at most `window.size`.
3. On a size failure, drop one thing and go to rule 2: the oldest unit while
   more than one unit is left, then the last memory item. Role and skill
   instructions, tools, records and the newest unit are never dropped. With
   nothing left to drop: `{:error, :over_limit}`.

## Results

    {:ok, %{request: map, canonical: bytes, estimate: value,
            dropped: [%{part: :history | :memory, id: id}], image_refs_removed: [id]}}
    {:error, :invalid_input | :unmarked | :orphan_tool_result | :too_many_tools |
             :tool_description_too_large | :estimate_unavailable | :over_limit | {:request, reason}}

`dropped` is in drop order; `estimate` is the value for the returned request
with its direction unchanged. `:invalid_input` (wrong shape, unknown key such as
`image`, `document` or `parts`, repeated ID), `:unmarked`,
`:orphan_tool_result` (a result that does not follow its call with only results
between, or a second result for one call), `:too_many_tools` (over 64) and
`:tool_description_too_large` (over 4,096 bytes) come before any drop.
`{:request, reason}` is `:invalid_request` or `:unsupported_feature` of
`Request.decode/2`; its `:too_large` leads to a drop. `:estimate_unavailable` is
an `:error` of `estimate` or a value with other keys or estimator fields. No
error holds content.

## Grounding

`mix test pieces/workflow/prompt-assembly/test` runs the named groups
`drop_order`, `orphan_tool_result`, `hard_bounds`, `deterministic` and
`image_refs` with literal inputs and an estimate of one token per byte. Every
accepted request is checked with `Request.decode/2` and its bound. Negative
control: a drop that removes an assistant entry without its results fails
`drop_order`. These are finite scenarios, not a proof. ai-text's decoder decides
what a valid request is; `workflow/untrusted-content` owns the mark and the
block format. No Cure law is claimed.

## Needs and limits

Needs: the caller decides what is an instruction and what is content, stamps
marks truthfully, selected memory with its access check, keeps IDs unique, puts
no unmarked content of a tool, document or member in a record, and supplies a
pure estimate that tells its direction truthfully.

Limits: no claim that a provider accepts each order of messages the inputs
allow; no claim about estimate accuracy; no other optional request member; no
image part or image input; no claim that marking prevents prompt injection.

Telemetry and Control are not applicable: a pure function with no observations
and no process. Config is supported per call only: `max_request_bytes`,
`max_image_refs` and the window with its estimate come in each input; there is
no default, stored setting or hot change. Module `Elzoo.PromptAssembly` is
application-owned after copying. Apache-2.0; no new dependency or pin.
