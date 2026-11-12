# ELZ-126 — Run with durable approval release, without dispatch

- Dependencies: ELZ-009, ELZ-023, ELZ-024, ELZ-028, ELZ-116, ELZ-123
- Output: `workflow/run-approval-release`; module `Elzoo.RunApprovalRelease`.

## Responsibility and first caller

Own a serialized durable Run and its approval events, with one additional command that commits or revalidates exact-action approval and returns without starting an EffectIntent owner, admitting an intent to EffectIntent, activating an owner, scheduling work or sending. RC-50 calls this command before the existing RunResource dispatch command, which continues to own the resource's current lifetime/FIFO check and commit-before-send barrier. The same release-only command can gate a host's non-Effect local action without pretending that local work is an Effect; this task's executable integration caller is the resource use.

This is a distinct Run implementation/Contract, not an authorization service and not a second approval owner beside Run. One live Run is owned by EITHER the existing `Elzoo.Run` OR this variant. RC-50 selects this variant for its Runs. Old `workflow/run`, `Elzoo.Run`, source bundle, tests and Contract remain usable and byte-unchanged. No mixed owners over one Run stream, migration, handoff or live owner substitution is supplied.

## Variant boundary

Build ONE explicit renamed source variant of the ready Run owner, with a narrowly added command branch using its existing private approval-release path. It retains existing commands and restart behavior. A wrapper or second approval owner cannot provide this boundary. No dummy Adapter, proxy process, read-only activation trick, monkey patch, compile-time source rewrite, generic copy framework or generic dispatch callback is admitted.

## Exact source/namespace footprint

Only `pieces/workflow/run-approval-release/**` is the worker lane:

- `lib/elzoo/run_approval_release.ex`: copy the pinned Run owner, rename its public module, add only the release-only command handling and any minimal internal return translation needed by that command. No new production module, behaviour, dispatcher, timer, callback or options framework.
- `test/elzoo/run_approval_release_test.exs`: copy the current nine Run scenario groups with module/path substitutions, preserve their assertions, and extend with the named new groups below. The retained commands are claimed by the new ID and require their own evidence; old Run tests alone cannot ground renamed bytes.
- `test/support/run_approval_release_test_helper.exs`: copy the current Run helper with all `Elzoo.Run.TestRepo/TestAdapter/TestBinding/ChangedTestBinding/TestHelper` names renamed under `Elzoo.RunApprovalRelease`. Keep existing SQL harness/provider facilities. Test-only aliases of the old production owner must not accidentally test old Run instead of this variant.
- `examples/run_approval_release.exs`: one checked release-then-resource-dispatch example; no real provider.
- `README.md`, `piece.json`: exact new command Contract, source provenance, inherited behavior, Needs and finite evidence. No Cure source is copied or changed: existing ready Approval owns its pure decisions and laws.

Unexpected additional production modules or broader behavior returns to coordinator before expansion.

Direct dependencies preserve Run's existing `workflow/approval`, `state/lease`, `state/event-log`, `delivery/effect-intent`, `integration/sql`; add `workflow/run-resource` for this Piece's copied executable integration test/example, not a production import or wrapper. No new external package/pin. ELZ-116 is the source Contract baseline and ELZ-123 the resource integration caller. No dependency on RC-50 or unmerged lifecycle. Providers remain pinned Elixir/OTP/SQL closure. Source provenance names baseline commit and copied paths, not private environment details.

Only final per-ID index/generated files are additional worker paths, following AGENTS.md; no edits to old Run, Resource, Approval, EffectIntent, root tests, scripts, config or pins.

## Public interface and invariant

Preserve the copied owner's existing `start_link/1`, `command/2`, `status/2`, `fold/0`, `limits/0`, `classify_attempt/2`, `outcome?/1`, existing command shapes, bounds and result families under the new module name. Construction still uses this variant's fold/limits, ready Lease/held Store and existing `effect_intent` binding-options map (which may be empty for release-only callers). The new command does not consult runtime binding/activation/task options. No new construction option.

Add exactly one command to the variant's command table:

```elixir
%{kind: :release_approved,
  run_id: run_id,
  attempt_id: execution_attempt_id,
  expected_revision: revision,
  request_key: full_ready_approval_request_key,
  context: fresh_trusted_ready_approval_context}
```

The full request key already binds the exact normalized action, writes, policy and requirement in ready Approval; it is not an uncorrelated permission. Deliberately omit an intent operand: approval release itself needs no provider and must also be meaningful for local work. RC-50 must record the exact action-to-resource/intent descriptor before it invokes this release and later dispatches; the variant neither creates nor admits that intent. No new descriptor registry or artificial Effect is added to the prerequisite. The retained dispatch_approved command still owns its original action-to-intent binding for Effects that it dispatches itself.

New success results:

```elixir
{:ok, revision, %{approval: :released, request_key: key}}
{:ok, revision, %{approval: :waiting, request_key: key}}
```

The first means that the exact release is durably retained and passes current revalidation for this command; it does NOT mean dispatch, provider completion, no prior send or a transferable permit. The second is an open approval with no usable fresh/retained evidence; no consent is invented. It is not a release and grants no work.

Preserve `{:unchanged, :stale | :terminal, revision}`, `{:refused, reason}`, `{:error, reason}`, `{:indeterminate, receipt}` and existing revision conflict behavior. Unknown request or request bound to another Attempt gives `{:refused, :unknown_request}` after currentness classification. Malformed commands retain invalid_command. Preserve ready Approval refusal/error reasons; do not turn absent consent into a refusal or erase a genuine revocation/authority failure. `:already_released` is never success.

The release-only command has no cached duplicate-success fast path. At the supplied current revision every repeat revalidates current trusted authority. After a previous commit, an old expected revision is a conflict, not permission; caller obtains status and repeats with fresh context/current revision. Stale Attempt and terminal Run classifications remain prior to revision conflict, as in Run. Do not make a new Attempt on restoration.

## Recorded state, restart and no-send guarantees

Keep the variant's ONE ready Approval state inside its existing guarded Run model, Approval event replay and once-consumption barrier. This command needs no new event type or state field: it retains the same approval release event as the original private path. No independent approval state, new consent format, separate authority database, capability token, new store or extra outbox.

For first release: require the existing request belonging to current execution Attempt; use stored fresh evidence unchanged when present. If none, select_retained must actually choose existing consent before passing `:retained`. Commit the release/consumption event before returning released. If an existing release is present, call only Approval.revalidate with current context. It must not call release again to interpret already_released as permission. The copied private helper currently builds waiting_approval from an effect entry (`run.ex:437–441`); translate its no-consent result without requiring that entry for this command, while preserving dispatch_approved's original result. This is a small internal return adaptation, not duplicated release logic.

Status is inspection and never substitutes for this command's revalidation. External resource effects and their settlement remain in RunResource/EffectIntent and the engine's correlation records, not new Run effects manufactured by release. The retained effect_result command applies only to an existing bound effect from the retained Run-owned dispatch path. RC-50 must display unknown resource effects independently of the Run's eventual terminal outcome; this command does not claim to observe them.

No call to EffectIntent.start_link/advance/rearm/observe, Host.activate, an Adapter, Task.Supervisor, or a network/provider operation occurs because of release_approved. Existing explicitly called dispatch_approved retains its old behavior; callers must select the correct dispatch owner, not invoke both commands to send a resource action. RC-50 never calls dispatch_approved for a resource action. This is an application-owned trusted API, not a BEAM security boundary against callers invoking the wrong command.

Crash windows:

1. Before release invocation/commit: no released reply or EffectIntent work. Caller persists its immutable dispatch descriptor separately before asking; retry only after resolving any uncertain append.
2. Request/evidence committed, release absent: no evidence stays waiting; fresh evidence/selected retained consent runs existing release gates.
3. Release append rejected: no released reply; preserve the existing Store/Lease failure result. No send or admission occurs.
4. Release append indeterminate or reply lost: stop/reconcile as existing Run requires. Host confirms and fences outstanding writes before replacement. Recovery either finds release and revalidates, or follows the existing unreleased path; never infer non-commit from absence.
5. Release committed, caller dies before Resource dispatch: recovery returns released only after current revalidation; Resource/EffectIntent records decide whether any first send remains permitted. Approval revalidation alone never decides this.
6. Resource reserved/sent before caller dies: this variant may revalidate approval again but sends nothing; Resource/EffectIntent reconcile and never resend a possibly-sent action because of a release reply.
7. Current Run cancellation, newer Attempt or terminal outcome before repeat: unchanged stale/terminal, no permission. An old cached success is never reusable. A delayed physical send already scheduled remains outside cancellation's guarantee.

No cross-stream transaction or atomic release-and-resource-dispatch is promised. Host serializes cancellation/new Attempt/admission and supplies current authority, exclusive owners and provider fencing. Retain complete Run history through reconciliation horizons; same 128-KiB event bounds. Memory is volatile; use the existing disposable PostgreSQL harness for the new durability scenarios.

## RC-50/RunResource call sequence enabled by this prerequisite

1. RC-50 selects the variant as the Run owner, keeps the engine's descriptor and gate/budget facts durable, and uses ready Authorization. ASK creates/persists the request and verified evidence in that owner. The engine never edits its Approval state.
2. Admit the exact resource action through RunResource.command. A queued action must wait. Resource read exposes the descriptor and current candidate only; it is not permission. Resource admission alone performs no send.
3. Immediately before a resource dispatch attempt, engine checks current nonterminal Run/current Attempt and calls variant release_approved with fresh context and the full request key correlated to its recorded descriptor. Waiting/refused/error/unknown/stale/terminal means no resource dispatch. Previously released state still revalidates now.
4. On released, call existing RunResource.command with `{:dispatch, identity, exact_effect_owner}`. That owner alone renews/checks FIFO/pause/deadline/closing, commits its dispatch reservation and calls EffectIntent.advance. EffectIntent activation is host-owned; read-only stays read-only, reserved intent never gains send authority from approval.
5. Consume resource input/budget entries durably in the engine; keep completion evidence and unknown outcomes separate from Run termination. At Run end, immutable cleanup follows Resource's existing preauthorized host cleanup boundary. This task does not bypass terminal Run checks to mint new approvals for cleanup after termination.

ALLOW-only Effects do not use this command or fabricate ASK; RC-50's separately specified direct EffectIntent path remains. An existing ordinary ASK Effect may still use the variant's retained dispatch_approved command. These routes share a Run approval owner but have distinct dispatch owners; no second approval protocol.

## Named acceptance groups only

Retain the copied Run's nine existing groups as the unchanged-behavior baseline. Add these six groups (cases belong inside these groups, not a new generic conformance framework):

1. **Release without dispatch:** real ready Authorization ASK + Approval + guarded SQL Run; fresh evidence and each ready scope; zero host activation/EffectIntent admission/send/task starts from release-only, both with an empty binding map and with a valid executable binding available. Release/consumption is committed before released reply; no intent record is created. Unknown request, wrong Attempt and mismatched action binding in current context refuse. Genuine ALLOW cannot be passed as an ASK request.
2. **Waiting and retained consent:** absent evidence without retained consent remains waiting across restart; selected retained consent releases only with current reviewer authority; no selected consent means no fabricated retention. Declined/revoked/expired/wrong binding/self-approval and unavailable current context preserve ready failures. Use existing ready test fixtures, not a second approval algorithm.
3. **Release restart windows:** faults before release invocation, after evidence/before release commit, rejected and indeterminate release append, and lost reply after commit. Reconcile through existing SQL/Lease harness. Repeat under fresh current context revalidates rather than sends or consumes again; old expected revision does not replay cached permission. Every case has zero EffectIntent work caused by this command.
4. **Currentness and authority change:** newer execution Attempt, current cancel and every terminal outcome suppress release; stale cancellation preserves current behavior. After a successful release, change current policy/authority or revoke evidence; repeated release fails or becomes unchanged, never uses previous success as permission. No new Run outcome or approval vocabulary.
5. **Resource-owned send:** with real ready RunResource and EffectIntent plus counting fake Adapter, release first gives zero sends; resource dispatch then gives one send after its own committed reservation. A queued use remains unsent; when current it revalidates before dispatch. Pause/closing/deadline between release and Resource command is refused by Resource without send. Crash after release/before dispatch and after reservation/before caller outcome leads respectively to permitted first dispatch or reconciliation, never a second send. Read-only activation gives no send. Check exact shared descriptor/binding and host-authenticated observations.
6. **Isolation, copy and checked example:** both old Run and new module can be copied/compiled without namespace collisions; they operate separate streams/owners. New module's inherited identity/children/completion/approval/dispatch scenarios still run. Execute the release-then-resource example. Check that copied tests exercise the renamed implementation, not an alias back to old Run. Verify unchanged old Run source by diff/evidence, not a retained source-hash assertion.

Negative controls: temporarily bypass the release-event commit in the NEW owner's production release path; Release without dispatch must fail on missing durable release after recovery, then restore the edit. Temporarily bypass revalidate for an existing release; Currentness and authority change must fail, then restore it. Both mutations use the actual production file, never a scratch copy or old Run. The no-send scenario also instruments real EffectIntent startup/activation and the counting Adapter; it does not infer no send merely from the returned approval tag. Do not commit mutations or replace executable checks with source-text assertions.

## Grounding, operations and local gates

- Tests: finite SQL/fake-Adapter scenarios above, baseline renamed tests, checked example and negative control. No universal no-send/cancellation/durability proof or production monitoring claim.
- Upstream: pinned OTP/GenServer serialization and current ready Approval, Lease, Store, EffectIntent, RunResource semantics. Reusing Approval's laws is not a new proof of this command's persistence/shell behavior.
- Needs: verified caller/approver evidence and fresh policy; canonical arguments and exact descriptor binding; host serialization of cancellation and dispatch; exclusive current Run/resource ownership; trusted clocks; full retained history; outstanding-write confirmation and physical fencing before replacement; authenticated external settlement evidence. A successful release reply authenticates none of these external facts.
- Telemetry inherited OTP diagnostics, redacted by consumer; no payload events or exporter. Config supported only for retained construction settings, no added options/hot changes. Control supported for retained commands plus release_approved with precise commit/no-send result meaning.
- Verification commands when implementation is authorized: Piece tests, selected gate `mix check --piece "$(git merge-base origin/main HEAD)"`, and `git diff --check`; existing per-ID copy checks must include the new bundle. SQL tests use one worker's disposable database. Independent review is one separate agent/model session as AGENTS.md requires, checking the full variant diff and no unnecessary abstractions. Reviewer must see copy provenance and behavior delta rather than being shown only the small command hunk.
