# ELZ-020 — Measure and tune machine A CI parallelism

- Phase: P0 development infrastructure
- Dependencies: ELZ-019

## Outcome

Use measured machine A workloads to choose BEAM scheduler settings and assess whether another runner is worthwhile. Preserve owner-machine-only execution and all existing checks.

## Scope and acceptance

- [ ] Measure the same revision and toolchain at 2, 4 and 8 normal schedulers in isolated job-equivalent containers; record repeated warm checks, representative compilation, elapsed time, CPU and memory observations, commands and limitations.
- [ ] Select settings from the evidence; do not claim machine saturation or general speedup from configuration alone.
- [ ] Assess a second runner against CPU contention, queue delay and setup cost. Add it only if measurements justify it; retain one otherwise and document the decision.
- [ ] If adding a runner, use separate installations and exclusive backend/Gleam roles, allowing one job of each kind. Do not increase concurrent backend builds without measuring that workload separately.
- [ ] Document repeatable measurement and selected settings. No product/Piece behavior changes, weakened checks, hosted runner, or toolchain upgrade.
- [ ] Run mix check, obtain independent review, validate changed workflows on machine A, merge and record main validation and cleanup.
