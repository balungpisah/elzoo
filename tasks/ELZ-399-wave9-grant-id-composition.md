# ELZ-399 — Wave 9: check grant identity across Plan and Entitlement without pinning its format

- Dependencies: ELZ-379
- Release: V2
- Output: no new Piece ID; prepare Wave 9 acceptance for #884. Leave #884 open for ELZ-395, which changes the Piece.
- Change class: shared root test; local `mix check --affected origin/main`, `git diff --check`, and the full hosted check. The task's publication alone is docs-only.
- Owned paths: `test/wave9_tools_doors_models_money_test.exs`, only the group 4 trial and renewal scenario. No Piece, runtime, manifest, or other root test changes.

## Contract

**Coordinator decision (owner can veto):** replace the three `sub-1/0` and `sub-1/1` literals in the Wave 9 money scenario (publication-base lines 482, 499 and 509) with assertions about the IDs emitted by Plan. Assert nonempty binary IDs for the trial and renewal grants, distinguish the two IDs, assert the duplicate renewal returns the original renewal ID without changing the row, and match the expected renewal ID in the result from Entitlement. Keep the rest of the scenario, including periods, fee line and entitlement decision.

This does not weaken the cross-Piece contract: Wave 9 acceptance checks how the Pieces compose, and the exact grant ID format belongs in Plan's own tests. Do not change the generator or its tests here; ELZ-395 keeps an exact-format vector for its revised format.

## Acceptance

- The revised group 4 scenario passes on current `main`'s implementation, before ELZ-395. Run it on disposable PostgreSQL through the existing application-role fixture, then run the full/affected gate. Check that the IDs flow from the Plan grants through the existing host harness to Entitlement and are not recreated from a test-side format.
- Negative controls: present the same ID for the trial and renewal grants, substitute a distinct wrong renewal ID at the host handoff, and substitute a new ID in the duplicate result. Each mistakes one identity boundary and the scenario fails; restore each edit before the final gate.

Money and durable cross-Piece composition: shared full/affected gate and independent review. No production behavior changes.
