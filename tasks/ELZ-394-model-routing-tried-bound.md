# ELZ-394 — delivery/model-routing: bound the tried candidate refs

- Dependencies: ELZ-369
- Release: V1B
- Output: no new Piece ID; bound `request.tried` for #915.
- Change class: Piece-only implementation.
- Owned paths: `pieces/delivery/model-routing/**`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`.

## Contract

`select/3` accepts `request.tried` only when it is a proper list of distinct refs from the route and its length is at most the route's actual candidate count (1..16). Refuse anything else as `{:error, :invalid_input}` during whole-input validation, before any candidate decision. Stop walking an overlong list at the first element past the cap. Keep ranking, exclusion order, and all `after_failure/3` decisions, including no next Attempt after an unknown outcome.

## Acceptance

- A route with fewer than 16 candidates accepts empty, partial and exact-count lists of unique route refs; at the exact count, the result is `{:error, {:no_candidate, exclusions}}` with every exclusion `:tried` in rank order. An in-bound duplicate with all refs on the route returns `{:error, :invalid_input}`, as does the candidate count plus one. An unknown ref and an improper list remain invalid.
- Negative control: temporarily drop the distinct-ref check; the in-bound duplicate alone must fail its assertion. Review also checks that validation does not traverse an overlong input before applying the bound.

Untrusted input bound and routing after an unknown outcome: local small gate and full review. No new dependency.
