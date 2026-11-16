# ELZ-250 — Prepare bounded conversation state across Runs

- Dependencies: ELZ-024
- Release: V1B
- Output: state/conversation
- Change class: Piece-only

## Scope

Publish this data interface alongside ELZ-249 so the pure policy and runtime Assembly can be implemented independently. Create a pure conversation projection/preparation policy. It owns immutable message/association rules, not another event log, authentication, authorization engine, channel server, bot router or turn-taking framework. Persistence is the later consumer composition with CheckedCommand; this task does not claim that integration has run.

Expose `Elzoo.Conversation.prepare(snapshot, request, facts)` as the agreed pure preparation interface and `view(snapshot, scope)` as the bounded projection. Snapshot has exactly tenant/resource/revision/fields; request exactly operation_id/resource/expected_revision/payload. These data shapes agree with the simultaneously published ELZ-249 Contract; this Piece imports no unfinished module. Define strict version-1 portable state encoding in one resource field named `conversation`; no arbitrary application fields or migrations. Empty revision-zero resource is a new conversation. Malformed/unknown versions or inconsistent state are refused, not treated as empty. No I/O or clocks in these functions.

The outer DTO keys are atoms; payload keys are strings from decoded JSON. `prepare/3` returns `{:ok, [write], response}` or `{:refused, code}` with a fixed 1..64 lowercase alphanumeric/underscore code, matching ELZ-249. Write is exactly `%{target: request.resource, field: "conversation", value: portable_state}`. Response is a portable record containing the next `revision` and affected `message_id`, plus `run_id` for association/answer and `input_message_id` for answer. Use the existing Authorization tagged text/integer/boolean domain, not raw foreign values. `view/2` returns `{:ok, %{tenant: tenant, resource: resource, revision: revision, messages: messages, associations: associations}}`, `:not_found` for mismatched/ungranted scope, or `{:error, fixed_reason}` for malformed state. Declare exact message/association output and stored v1 shapes in the README and test their round trip.

Trusted facts are the ELZ-249 wrapper `%{tenant:, actor:, data:}`. Data is an exact portable record selecting one operation mode and, for Run-owned operations, the host-verified Run/input association. Mode and all IDs/text use tagged portable text; completion is a tagged portable boolean. Append-input data has exactly mode/input_role; associate-run data exactly mode/run_id; append-answer data exactly mode/run_id/input_message_id/completed. Request payload cannot supply tenant, principal, role, authorization, mode or Run outcome. Facts are included in the checked-command canonical request. Tenant/resource must match the snapshot/request scope. A snapshot revision is not an approval or authentication token.

Modes:

- `append_input`: payload exactly `message_id` and `text`; host facts choose `user` or `source` attribution. Append an immutable input message attributed to the host principal. Never accept assistant role from payload.
- `associate_run`: payload exactly the existing input message ID; Run ID comes from trusted Run-host facts. Associate that input with one immutable Run ID. Refuse a missing/non-input message or an already associated input. Several inputs may belong to the same Run, so a later outside event can continue it. The association records a host-allocated stable identity, not proof that a process started or completed; global Run-ID uniqueness and safe start/recovery belong to the host.
- `append_answer`: payload exactly answer message ID and plain text; trusted facts identify Run ID and input message and attest a completed Run outcome. Require their stored association. Append an immutable assistant answer attributed to the Run host/bot; one answer per associated input. Caller text alone is not evidence that a Run completed.

Message IDs are unique across all roles. A new operation attempting an existing message ID conflicts even when bytes are equal; only CheckedCommand's equal operation repeat returns the prior result. No rewrite, delete, automatic role upgrade or implicit association. Consecutive inputs/answers and associations may span multiple Runs. This Piece starts no Run and promises no global ordering across conversations.

The preparer returns the exact single authorized field replacement for `conversation` plus a bounded response containing affected IDs and the next resource revision. It changes no other resource/field. CheckedCommand supplies the CAS, authority, receipt, approval and atomic commit boundary; do not append a separate conversation log before or after its receipt. The pure proposal is not a committed success.

## Bounds, reads and encoding

Use existing portable Authorization values, with a strict, deterministic version-1 record/list shape and exact keys. Keep message order, byte-exact text and role/actor/Run references; do not normalize Unicode or render markup. IDs use the 1..128 UTF-8/no-NUL rule. Text is valid UTF-8, 1..4,096 bytes. At most 64 messages and 64 input/Run associations, with total encoded state at most 65,536 bytes and existing portable value limits. All changes, including answers, can refuse at capacity; callers must handle this as a non-applied result, not silently drop content or claim an answer was recorded. No eviction or receipt reuse.

`view/2` requires a separate host-vouched read scope for the exact tenant/conversation, never just a conversation ID. A mismatched/ungranted scope returns `:not_found`; malformed state is a bounded error. Return only checked message/association data. The host authenticates and grants scope; the pure map does not prove provenance. Error outputs are fixed reasons without supplied content.

Refusal order is fixed: validate facts/scope; validate request representation/bounds; validate the complete snapshot; require expected resource revision; apply mode-specific message/association conditions; check prospective capacity. Cure owns the bounded decision policy when it fits; Elixir validates foreign values and encoding. Use ordinary library collection operations, not a new storage framework.

## Acceptance

1. Start empty, append input, associate a Run, append its answer, reconstruct the resource and continue through a second Run. Also associate a second input with the same Run without rewriting the first link. Preserve prior IDs/content/attribution and order exactly.
2. Reject duplicate IDs with equal/changed bytes, unknown/extra/control keys, forged assistant mode/actor/tenant, wrong Run/input association, uncompleted Run facts, duplicate association of one input and duplicate answers, wrong revision and malformed state. Test independent tenant and read-grant mismatches, all exact numeric/text/container boundaries and unchanged state on refusal.
3. The copied example/tests exercise the strict snapshot/request/facts/write/response data interface directly, with no fake database or unfinished-module import. The next consumer task, dependent on both ELZ-249 and ELZ-250, MUST exercise their actual Memory/PostgreSQL composition: authorized commit, retained denial, equal replay, conflicting identity, duplicate message and a conversation CAS race. Pure preparation is not persistence evidence, and that integration must pass before claiming durable conversation or Wave 4 completion.
4. Bounded capacity rejects without truncation/eviction. Unknown serialized versions and inconsistent message/association references fail closed. No artifact bytes, rich rendering, streaming chunks, account profiles or external channel identity resolution.
5. Temporarily bypass duplicate-ID and Run/input association checks; their adversarial tests must fail. Restore before final gates. Any Cure laws are named selected laws, not universal storage/authentication proofs.

Run Piece tests, the selected Piece gate, live roadmap/claims and diff checks. Independent review and exact-head hosted evidence remain mandatory.

## Owned paths

`pieces/state/conversation/**`, own catalogue/plan entry and generated indexes. Include source/codec, Cure where appropriate, tests, README, manifest and one pure preparation example. Declare the existing Authorization/provider closure actually used by source/examples/tests. No dependency on an unfinished CheckedCommand implementation, other Piece edits, root tests, provider pins, authentication, websocket/SSE server, upload implementation, general history migration or Store adapter changes.
