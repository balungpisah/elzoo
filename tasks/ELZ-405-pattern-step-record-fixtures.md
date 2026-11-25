# ELZ-405 — workflow/pattern-step: pin the frozen v1 and v2 neutral maps

- Dependencies: ELZ-114, ELZ-404
- Release: V2
- Stage: `release`
- Output: no new Piece ID.
- New external dependency: none.
- Change class: Piece-only implementation.
- Owned paths: fixture files and fixture test under `pieces/workflow/pattern-step/test/`, the file list in its `piece.json`, only its manifest hash and note in `docs/plans/release-plan.json`, and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`.

## Contract

Unchanged. This is X1 in `docs/plans/first-release.md`. First compare the `lib/` and `cure/` trees of this Piece at the build base with `0a76dd21` (F's merge); stop and report to the coordinator if they differ. They match at the publication base `00c842f9`. Use the frozen code at the build base; do not change any writer, reader or runtime Contract.

## Acceptance

- Write canonical JSON fixtures from `PatternStep.encode/1` of checked requests and inputs. For each version cover all its request action kinds: `model_call`, `tool_call`, `local_work`, `ask_person`, `nested_callable`, `resource_open`, `resource_use`, `resource_close`, `finish`, and in v2 also `wait_event`. Cover `start`, `message`, `resource_event`, `run_ended`, `action_outcome`, `person_answer`, `cancel`, `wake`, and in v2 also `outside_event`. For `action_outcome` in each version cover `completed`, `failed`, `refused`, `late`, `unknown`, `out_of_budget`, `retries_exhausted`, `expired`, and `resource_lost`.
- Pin each file's SHA-256 in the test. Read each JSON map with the pinned toolchain's built-in JSON support, assert `decode(map, version)` returns `{:ok, checked}`, and assert `encode(checked)` returns exactly the same map. `decode/1` is v1 only; `decode(map, 1)` delegates to it, and `decode(map, 2)` is the v2 path. The tracker from `open/1` is opaque and is not serialized; existing tracker tests still pass.
- Negative control: temporarily rename a required field in the decoder, show the fixture case fails, and restore before the passing gate. Add fixtures to `piece.json`'s `files`, update the index hash and ensure its note still equals the unchanged `contract`. Later additions do not rewrite pinned files.

Low risk: one light review. Run the Piece tests and `git diff --check`; use the local small gate or its exact-head hosted `check-piece` substitution under `AGENTS.md` section 5. Listed scenarios, not a proof.
