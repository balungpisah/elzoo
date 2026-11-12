# ELZ-121 — Keep affected consumer selection test aligned with ready dependencies

- Dependencies: none
- Allowed implementation path: `test/export_test.exs` only.

The Run worker's gate on issue #227 found that the affected-selection test freezes the uncovered result at `["workflow/approval"]`. A new ready `workflow/run` dependent legitimately adds another affected ID. The selector computes uncovered as affected IDs minus the selected consumer closure; when no consumers are selected, every affected ID is uncovered.

In the existing affected-selection case, retain `selected == []` and aggregate selection, assert that `workflow/approval` is a member of the uncovered IDs, and replace the frozen singleton assertion with `uncovered == affected`. Preserve all fixed per-ID consumer inventory assertions and existing selection coverage. This is a finite test repair, not coverage expansion. Add no per-ID consumer and change no selector, runtime, pin or inventory.

## Acceptance

- The existing affected-selection case passes with current main and with `workflow/run` as a new ready dependency of `workflow/approval`; when `selected == []`, it asserts `uncovered == affected`, aggregate is true and `workflow/approval` remains a member.
- Existing fixed per-ID inventory assertions and selection coverage remain unchanged. Only `test/export_test.exs` changes in the implementation task.
- Run the targeted root test file with the required consumer test modules loaded, `mix check --affected origin/main`, and `git diff --check`. Record failures or unavailable services; no new consumer or coverage claim.
