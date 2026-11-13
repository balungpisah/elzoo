# ELZ-140 — Prompt assembly and history compaction

## Scope and reuse

- Dependencies: ELZ-033, ELZ-079, ELZ-030, ELZ-137, ELZ-114
- Output: `workflow/prompt-assembly` and `workflow/context-compaction`: one task, two Piece directories; release V1B; bot-platform level 2.
- Owned paths: `pieces/workflow/prompt-assembly/**`, `pieces/workflow/context-compaction/**` and their index/generated changes under AGENTS.md section 3.

`workflow/prompt-assembly` builds one `integration/ai-text` request from instructions, selected memory, history and a tool list, inside a token limit and the hard bounds of ai-text, with one declared order and one declared drop order. `workflow/context-compaction` is a pure step that asks a model for one summary of a range of history and carries the keep-rule records beside the summary. Both are pure: no clock, network, storage or process.

ELZ-138 is not a dependency: the token estimate is a host Need, a function that the caller supplies, and this task imports no token-count Piece.

Implement only the acceptance groups below. Add no options, layers, behaviours, generic helpers or future hooks: no template language, no tokenizer, no rule that decides when to compact, no tool alias, no join with the tool registry (ELZ-142 owns it), no image input. Change no ready Piece, shared path, dependency pin or CI file. The independent reviewer flags extra features for removal.

Facts checked on main:

- `Elzoo.AiText.Request` (request.ex) takes 1 to 256 messages, at most 64 tools with distinct names, a tool description of at most 4,096 bytes, and a payload whose bytes and whose canonical encoding are at most the bound given to `decode/2`, which is at most 65,536. A message with an `image`, `document` or `parts` member is refused `:unsupported_feature`. `decode/2` and `canonical/1` are public. This task calls them and writes no second validator.
- The ready OpenAI provider needs exactly one system message for a system cache point, so the request has exactly one.
- A window of `workflow/context-selection` has six keys: `provider_id`, `model_id`, `size`, `unit`, `estimator_id`, `estimator_version`. The token limit arrives in that form. Memory arrives already selected by `Elzoo.ContextSelection.select/2`. This task does not call it and checks no access.
- `workflow/pattern-step` holds the shapes of a request, an action and an outcome input. The engine has one result schema for each action kind, so every pattern step uses one model-call vocabulary (below).

## `Elzoo.PromptAssembly.build(input, estimate)`

`input` is a map with exactly these atom keys:

- `model` and `max_output_tokens`: the members of the ai-text request.
- `role_instructions`: a list of at least one text, the role instructions of the recipe. `skill_instructions`: a list of texts, which can be empty: the named skill instructions, which come only from a tool source of kind `pinned_skill` (ELZ-136). Both are plain text with no mark. They are built as instructions and never dropped.
- `memory`: a list of `%{id: id, content: marked_map}` in selection order.
- `history`: a list of entries in time order (below).
- `tools`: a list of maps in the ai-text tool shape (`"name"`, `"description"`, `"input_schema"`). The registry of ELZ-136 has already given each tool its alias and bounded the list. The list goes into the request unchanged.
- `window`: a window as above with `unit: :tokens`. Its `size` is the token limit.
- `max_request_bytes`: 1 to 65,536, the value of the host's ai-text Config.
- `max_image_refs`: 0 to 256.

`estimate` is a function of arity 1 that the host supplies. It takes the canonical bytes of a request and returns `:error` or `{:ok, value}`, where `value` has exactly the keys `size` (a non-negative integer), `unit` (`:tokens`), `direction` (`:upper_bound` or `:approximate`), `estimator_id` (text) and `estimator_version` (integer). The estimator fields must equal those of `window`. The function must be pure. It is never stored.

A history entry is one of these maps, with exactly the keys shown. Each `id` is a text of 1 to 1,024 bytes and is unique in `memory` and `history` together. Each `marked_map` is the neutral map of ELZ-137.

    %{kind: :user, id: id, text: text}
    %{kind: :assistant, id: id, text: text, tool_calls: [%{"id" => _, "name" => _, "arguments" => %{}}]}
    %{kind: :tool_result, id: id, tool_use_id: text, content: marked_map, ref_media_type: nil | text}
    %{kind: :content, id: id, content: marked_map, ref_media_type: nil | text}
    %{kind: :record, id: id, keep: :goal | :open_action | :decision | :failed_approach, record: json_object}

`:user` is a message of the principal. `:content` is marked content in the place of a user message: a summary, a document, a message of another member. `:record` is a keep-rule item. `ref_media_type` is set when the content is a text reference to an Artifact; it is the `media_type` of the `cut` of ELZ-139. The entry is an image reference when that text starts with `image/`. No entry has a field for bytes, so an image or a binary value appears only as such a marked text reference.

Declared order. The request has the members `version`, `model`, `max_output_tokens`, `messages`, and `tools` when the list is not empty. Its messages are:

1. One `system` message: each role instruction, then each skill instruction, in their order, joined by one empty line.
2. When `memory` is not empty, one `user` message: the rendered block of each item in order, joined by a line feed.
3. One message for each history entry, in order. `:user` gives a `user` message with the text. `:content` gives a `user` message with the rendered block. `:assistant` gives an `assistant` message with the text and, when the list is not empty, `tool_calls`. `:tool_result` gives a `tool_result` message with `tool_use_id` and the rendered block. `:record` gives a `user` message with the canonical JSON of `%{"keep" => kind, "record" => record}`.

A rendered block is the text of `Elzoo.UntrustedContent.render/1`. Marked content appears in no other form, and no instruction text appears in a block.

A unit is an `:assistant` entry together with the `:tool_result` entries that follow it directly and name its calls. Each other `:user`, `:content` and `:assistant` entry is a unit alone. A `:record` entry is in no unit.

Rules, in this order:

1. Image references. Of the image-reference entries, the newest `max_image_refs` stay as they are. In each older one the content becomes a marked value with the same `sources` and `trust` and the text `[image reference removed]`; its `max_bytes` is the larger of the old bound and the byte size of that text. The message stays, so no call loses its result.
2. Build the request, encode it with `Request.canonical/1` and check it: at most 256 messages; `Request.decode/2` with `max_request_bytes` accepts the bytes; the `size` of the estimate is at most `window.size`.
3. When a check fails for size, drop one thing and go to rule 2. Declared drop order: the oldest unit, while more than one unit is left; then the last memory item. The same order serves the message count, the bytes and the token limit. Never dropped: role instructions, skill instructions, tools, `:record` entries and the newest unit. When nothing is left to drop, the result is `{:error, :over_limit}`.

Results:

    {:ok, %{request: map, canonical: bytes, estimate: value,
            dropped: [%{part: :history | :memory, id: id}], image_refs_removed: [id]}}
    {:error, :invalid_input | :unmarked | :orphan_tool_result | :too_many_tools |
             :tool_description_too_large | :estimate_unavailable | :over_limit | {:request, reason}}

`dropped` lists each dropped entry in drop order. `estimate` is the value for the request that is returned, with its `direction` unchanged: an approximate value is never shown as a bound. These refusals come before any drop:

- `:invalid_input`: a wrong shape, an unknown key (`image`, `document` and `parts` included) or a repeated ID.
- `:unmarked`: content that `UntrustedContent.decode/1` refuses.
- `:orphan_tool_result`: a `:tool_result` entry that does not follow, with only `:tool_result` entries between, an `:assistant` entry that holds a call with its `tool_use_id`; or a second result for one call.
- `:too_many_tools`: more than 64 tools. `:tool_description_too_large`: a description over 4,096 bytes. This task refuses them and cuts nothing.

`{:request, reason}` is `:invalid_request` or `:unsupported_feature` of `Request.decode/2`. `:too_large` of `Request.decode/2` is the size check of rule 2 and leads to a drop. `:estimate_unavailable` is an `:error` of `estimate`, or a value with other keys or other estimator fields. No error holds content.

## `Elzoo.ContextCompaction`: `open/2`, `accept/2`, `check/2`

The model-call vocabulary is the one that every pattern step uses (ELZ-141 too). The action has the kind `model_call` and the schema key `elzoo/ai-text-request` version 1, the key of ai-text; its payload is the decoded request object. A completed outcome has the schema key `elzoo.ai-text.result` version 1; its payload holds `content` (text), `structured` and `finish` (`"stop"`, `"length"`, `"tool_calls"`, `"content_filter"`, `"refusal"` or `{"other": text}`). This step reads `content` and `finish`.

`open(input, estimate)` returns `{:ok, state, request}` or `{:error, reason}`. `input` has exactly these atom keys:

- `action_id`: the ID of the one model-call action. The caller keeps it unique in the Run.
- `entries`: 1 to 256 history entries in the shape above: the range to compact.
- `model`, `max_output_tokens`, `role_instructions`, `window`, `max_request_bytes`: for the summary request. The role instructions say how to summarize; the host writes them.
- `summary`: `%{id: id, source: text, max_bytes: n}`: the ID of the summary entry, and the source and the size bound of its mark. A `source` outside the source grammar of ELZ-137 or a `max_bytes` outside 1..16,777,216 is `:invalid_input`.

The `:record` entries are the keep-rule items. They are carried as they are and are not sent to the model. The other entries are the free text. `open/2` builds the summary request with `PromptAssembly.build/2` from the role instructions and those entries, with no skill instructions, no memory, no tools and `max_image_refs` 256. If that build drops an entry, the range does not fit one request: the result is `{:error, :over_limit}`, and the caller takes a shorter range. A range with no free text is `{:error, :nothing_to_summarize}`. Each other error of the build comes back unchanged.

`request` is a request of `workflow/pattern-step` with exactly one action: its `id` is `action_id`, and its kind, key and payload are as above. `state` is plain data (no function, PID or reference) that the caller keeps.

`accept(state, input)` takes a neutral input map of `workflow/pattern-step` and settles the action through `PatternStep.open/1` and `PatternStep.accept/2`:

- `{:late, state}` for an outcome of another action and for a late outcome. `{:error, :invalid_input}` for a map that `PatternStep.decode/1` refuses. `{:error, reason}` with the reason of `PatternStep.accept/2` (`:not_an_outcome`, `:incompatible_answer_kind`) for an input that it refuses.
- `{:error, {:model_call, outcome}}` for an outcome class other than `completed`.
- `{:error, :invalid_summary}` when the schema key is not the result key above, when `finish` is not `"stop"`, or when `content` is not a nonempty UTF-8 text of at most `summary.max_bytes` bytes. A refusal, an empty answer and an answer cut by the length limit are in this case.
- Otherwise `{:ok, compacted}`:

      %{entries: [record_entry, ..., %{kind: :content, id: summary.id, content: marked_map, ref_media_type: nil}],
        derived_from: [%{item_id: id, version: 1}, ...]}

The record entries are those of the range, unchanged and in order. The marked map has the one source `summary.source`, the class `derived`, the bound `summary.max_bytes` and the answer as content. `derived_from` names each summarized entry in order, in the reference form of `workflow/context-selection`. A history entry does not change, so its version is 1. `entries` can take the place of the range in a history.

`check(entries, compacted)` returns `:ok`, or `{:error, {:keep_items_lost, ids}}`, where `ids` is the set difference between the IDs of the `:record` entries of `entries` and those of `compacted.entries`. `accept/2` runs it on its own result before it returns the result, so a compaction that loses a keep-rule item is refused. A host that reads a compacted value from a record runs it again before the value replaces history.

In each error case there is no compacted value, and the caller keeps the original history. This step deletes nothing. The engine records the intent, the outcome and the original history.

## Needs and limits

Needs. The caller decides what is an instruction and what is content: role instructions come from the recipe, skill instructions only from a `pinned_skill` source, and each tool result, document, member message and summary is a marked value. The marks are stamped truthfully (ELZ-137). The `estimate` function is pure and tells its direction truthfully. Memory was selected with its access check. A `:record` entry holds no unmarked content of a tool, a document or another member. The caller keeps IDs unique and keeps the original history. The host's model binding gives a completed outcome in the vocabulary above.

Limits. No claim that a provider accepts each order of messages that the inputs allow. No claim about the accuracy of an estimate. No other optional member of the ai-text request is built. No image part and no image input. No claim about the quality of a summary. No claim that marking prevents prompt injection. Telemetry, Config and Control are not applicable to these pure functions; the manifests say why.

## Acceptance groups

Each test input is a literal map. No recorded provider fixture and no credential is used. The `estimate` function of a test is a plain function of the byte size.

1. **`drop_order`**: with an input over the token limit, the oldest unit goes first. A unit of an `:assistant` entry with two calls and its two results goes as a whole. Then the memory items go, from the last. Role instructions, skill instructions, `:record` entries and the newest unit are in every result. `dropped` equals an expected list that the test holds as a literal. With nothing left to drop the result is `:over_limit`.
2. **`orphan_tool_result`**: a result with no call, a result after a `:user` entry that stands between it and its call, and a second result for one call are each refused, and no request is built.
3. **`hard_bounds`**: 257 messages drop by the same order to 256. 65 tools are refused `:too_many_tools`. A description of 4,097 bytes is refused, and one of 4,096 bytes passes. A request over `max_request_bytes`, also with a configured value below 65,536, drops by the same order. Parts that are never dropped and are alone over a bound give `:over_limit`. Each `{:ok, _}` request is accepted by `Request.decode/2` with the configured bound, and `canonical` equals the encoding that it returns.
4. **`deterministic`**: the same input gives the same `canonical` bytes two times. For a fixed input the bytes equal a text that the test holds as a literal: it shows the declared order, the one system message and each rendered block. `estimate` is called only with canonical bytes.
5. **`image_refs`**: with five image references and `max_image_refs` 2, the three oldest have the fixed text with their `sources` and `trust` unchanged, and each other reference is untouched. With 0, none stays. An entry with an `image`, `document` or `parts` key is refused, and no message of a built request has such a member.
6. **`compaction`**: `open/2` gives a request that `PatternStep.decode/1` accepts, with exactly one `model_call` action whose payload `Request.decode/2` accepts and which holds no record. A completed outcome gives the records unchanged and a summary with the class `derived`, the given source and a `derived_from` that names each summarized entry. An outcome that is failed, refused or unknown, a `finish` of `"length"`, an empty `content` and another schema key each give the named error and no compacted value. An outcome of another action is late. `check/2` on a compacted value that lacks one record gives `{:error, {:keep_items_lost, [id]}}` with that ID, and `:ok` when none is lost.

Negative controls (edit temporarily, run, record the failure, revert): make the drop remove an `:assistant` entry and leave its results, and `drop_order` must fail; make `accept/2` leave out the first record entry, and `compaction` must fail with `keep_items_lost`.

## Evidence

Keep the kinds apart. Test: the six groups, finite scenarios. Upstream: the Contracts of `integration/ai-text` (its request decoder decides what a valid request is), `workflow/pattern-step` and `workflow/untrusted-content`; Jason. Assumption: the Needs above. Cure law: none. The decisions are list steps over rendered text and calls into the decoder of ai-text, so tests only. The laws of `workflow/context-selection` stay its own and are not claimed here.

Run the tests of both Pieces, then `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. One independent review checks this body, the exact diff and needless features.
