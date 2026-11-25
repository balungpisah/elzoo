# ELZ-390 — delivery/room: state when the host stops repeating open/3

- Dependencies: ELZ-348
- Release: V1B
- Output: no new Piece ID; clarify the existing host Need for #834.
- Change class: Piece-only Contract wording; no executable change.
- Owned paths: `pieces/delivery/room/README.md` and `pieces/delivery/room/piece.json`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`.

## Contract

The host repeats `open/3` with the same request after failure until `{:ok, _}`, `{:error, {:mailbox, :conflict}}` (returned only once the conflict release has finished), or a definite step 1 or step 3 refusal. Do not treat an indeterminate pin or release, or a later failure, as a stop. `resume/3` is not a substitute. Put the same stop set in the README and the manifest's repeated-open Need and assumption grounding; no behavior change.

## Acceptance

- Cite `room_test.exs`, case 2 (`open/3`), for the refusals, success and repeated conflict release. All room tests pass on their existing disposable PostgreSQL fixture.
- Wording negative control: trace the case 2 interrupted step-4 release against a rule that stops on any error. That rule would leave the losing pin, contradicting the case that removes it on repeated `open/3`; the winning link's own pin remains. No temporary source change for this wording check.

Durable state and unknown outcomes: local small gate and full review. No new dependency.
