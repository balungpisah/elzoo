# ELZ-025 — Adopt-or-distill study of sixteen Elixir/Gleam packages

- Phase: P0 research (no runtime)
- Catalogue IDs: none ready; reason text on deferred/planned handles only
- Dependencies: ELZ-021

## Outcome

A second reference round after ELZ-021. Sixteen packages from the Elixir and
Gleam ecosystems (money/finance and task/agent orchestration) were pinned,
read and compared with the capability model, the C1–C9 coverage cases and
the catalogue inventory by seven concurrent study sessions. Each package ends
with one of three verdicts: adopt-candidate (named handle and boundary a
future task must exercise), distill (Elzoo writes the idea as Contract text,
design test or admission record) or skip (dated reason). No package is a
dependency after this task; no source is copied.

Result: 0 adopt-candidates, 9 distill, 7 skip. The distilled material becomes
six new demand-led task bodies (ELZ-026 to ELZ-031), additive design tests on
open tasks, and reason text on deferred handles.

## Scope

- publish the seven study reports verbatim under
  docs/research/studies/round-2/ and the curated index
  docs/research/ecosystem-round-2.md (summary table with pinned revision,
  license and verdict per package; distilled text grouped by handle);
- add demand-led task bodies with admission records: ELZ-026
  workflow/dependency-graph, ELZ-027 delivery/trigger schedule occurrence,
  ELZ-028 state/lease, ELZ-029 runtime/os-isolation, ELZ-030
  workflow/context-selection, ELZ-031 domain/money;
- add additive design tests to open, unclaimed tasks ELZ-009, ELZ-010 and
  ELZ-011 and to the demand-led bodies ELZ-022, ELZ-023 and ELZ-024;
- leave ELZ-006 (claimed) untouched; its four relevant findings are recorded
  in the index as non-binding references for that task's claimant;
- update reason text on the affected deferred/planned catalogue entries,
  regenerate LEDGER.md, and add the task DAG rows and edges.

## Acceptance

- [ ] Every package row carries an exact revision, license finding and dated
      verdict; license conflicts are stated (money_pattern, staff_ai, quant,
      pluggy_ai).
- [ ] Each distilled item names a handle, a coverage case and the task body or
      reason text that now carries it.
- [ ] No dependency, source file, ready manifest or ready Contract changes;
      mix check passes on the inventory edit.
- [ ] ELZ-006's Contract and live issue are unchanged.
- [ ] Independent review of the Contract amendments is recorded on the PR.

## Evidence and limits

Prose and inventory. The study sessions ran nothing from the studied
packages; maintenance signals are dated public metadata, not quality claims.
Admission records are proposals for their future workers, not acceptance.

## Out of scope

Implementation of any Piece; publication of ELZ-026 to ELZ-031 as issues
before this task merges; amendments to claimed tasks.

## Reference

Study reports in docs/research/studies/round-2/ (money, jido, pixir, fabric,
bankai, frameworks, finance), each pinned to the revisions it names.
