# ELZ-263 — PatternStep v2 event waits

- Phase: Level 4
- Dependencies: ELZ-114, ELZ-258
- Output: extension of the existing workflow/pattern-step Piece; no new Piece ID.
- Owned paths: `pieces/workflow/pattern-step/**`; this Piece's existing row only in
  `registry/catalogue.json` and `docs/plans/release-plan.json`; generated
  `LEDGER.md`, `docs/plans/views.md`, and `docs/plans/dependencies.mmd`.
  Update `piece.json`, README, its catalogue summary as needed, and the existing
  release-plan `note`/`manifest_sha256` per AGENTS. Preserve ready status and all
  existing job/output ownership. No other Piece, shared runtime, dependency, pin,
  root-test, or CI changes.

Start after this task is published and ELZ-114/ELZ-258 are merged. Follow the
normal Piece tests, small gate, exact-head hosted check, review, queue, and
main-push checks. A selected gate is not full acceptance.

## Changed Contract

Keep `decode/1` strictly v1. Add `decode(map, 1 | 2)` with explicit selector/map
version equality; reject all other selectors and mismatches. `encode/1`, `open/1`,
and `accept/2` accept authentic v2 operands with distinct checked/tracker tags.
Preserve literal v1 tags, representation, bounds, return classes, fixed fixture,
and behavior. V2 preserves every v1 action/input kind and adds only action kind
`wait_event` and input kind `outside_event`.

A v2 `wait_event` action has exactly the existing five keys: `id`, `kind`,
`schema_id`, `schema_version`, `payload`. An `outside_event` input has exactly
eleven keys: `type`, `version`, `kind`, `at_ms`, `action_id`, `source_id`,
`correlation_id`, `event_id`, `schema_id`, `schema_version`, `payload`. Its type
is `input`, version 2, kind `outside_event`; IDs use existing nonempty exact
UTF-8 rules, `schema_version` is positive, and `at_ms` is nonnegative host-recorded
Unix milliseconds. Payload stays opaque. Do not add a `late` field to this input.

An outside event settles only an open `wait_event`; `person_answer` settles only
`ask_person`. Generic completed `action_outcome` cannot settle `wait_event`,
but a non-late, non-completed outcome may settle it using existing v2 outcome
rules. Late outcomes never consume a wait. First settlement wins; duplicate,
unknown, settled, or late operands retain the existing return shape. Authentic
mixed-version accept operands return exactly
`{:refused, :incompatible_version, original_tracker}` without mutation or echo.

This is pure shape/settlement bookkeeping. It reads no clock, source, callback,
or payload schema and performs no authentication, persistence, broker, timer,
or retry. Keep v2 provenance and application-payload validation outside this
Piece. Do not broaden the existing Cure claim.

## Needs and grounding

The caller supplies matching explicit versions, recorded time, verified source
identity, Run/Attempt identity, payload validation, serialization, and durable
tracker ownership. On main, PatternStep exposes `decode/1`, `encode/1`, `open/1`,
and `accept/2`; current sets and payload are v1/opaque. These facts ground the
additive extension.

## Contract-to-test acceptance

1. Keep all v1 tests and the fixed v1 fixture unchanged. Exercise every v1 kind
   through the v2 selector and verify its v2 behavior; verify `decode/1` rejects
   v2 and explicit selectors require matching map versions.
2. Test exact v2 key sets, bounds, unknown fields/kinds/versions, malformed IDs,
   schema identities/version, and mixed tags. Mixed tracker refusal must preserve
   the original tracker.
3. Cover independent waits, matching event/action IDs, first settlement,
   duplicate/unknown/settled waits, `ask_person` versus `person_answer`,
   `wait_event` versus generic completed and non-completed outcomes, and late
   outcomes that never consume. Include outside-event payloads outside any app
   schema and confirm no source or callback is read.
4. Temporary control: allow a second settlement of a settled v2 wait. The named
   first-settlement assertion must fail. Restore production bytes exactly.
5. Run the v2 cases from an actual copied Piece/dependency closure as well as the
   root, with copied-source/loaded-module provenance. A selected gate does not
   independently export every already-ready Piece. Retain the production Cure
   law/audit and distinguish it from finite v2 validator/mapper tests.
6. Update README/manifest limits and grounding. Run Piece tests/source guards,
   then `mix check --piece "$(git merge-base origin/main HEAD)"` and
   `git diff --check`. Keep the selected-gate scope explicit; required hosted
   and main checks still apply.
