# ELZ-130 — Measure a conservative tia test-selection trial

- Dependencies: none
- Allowed implementation paths: `mix.exs`, `mix.lock`, `docs/development/10-symbolic-ci.md` only. Change the documentation only if retaining the trial.

Trial upstream `tia` exactly `0.1.1` as a development/test-only dependency with `runtime: false`, never in Piece exports. The preflight found MIT licensing, a Hex release checksum of `aa6d1fac18e1a415dedf0a59b6e8a9392413166b80cb8f801bf9ce518820a939`, no consumer dependencies, and native function-counter prerequisites on the pinned VM; actual compatibility has not been tested. Record license, provider and dependency evidence. No gate integration, provider or manifest change, framework, shared selector change, dependency modernization or advisory repair.

Keep all mandatory gates and full main checks unchanged. Tia's default test glob omits Piece tests: include both `test/**/*_test.exs` and `pieces/**/*_test.exs`, and verify discovery and exclusions. Its list options replace defaults, so preserve upstream conservative globals and cover Piece lib and root/Piece support macro sources. Cover support, macros, fixtures, config, Cure and separate-VM consumer inputs conservatively; use unfiltered fallback for unknown or indirect dependencies, missing/corrupt/incompatible/incomplete maps or training, and Git uncertainty. Do not hide a Tia failure with a passing fallback. The disposable `_build/test/tia/map.json` is already ignored.

## Acceptance

- Measure setup, training, map maintenance and repeated representative warm comparisons against valid `mix check --piece` and `mix test --stale` baselines. Include unchanged, Piece, shared/compile-time, schema/data, config, unknown and separate-VM consumer-sensitive cases; count the unchanged mandatory final gate in total. A `--piece` refusal for an ineligible change is not a speedup.
- Deliberate behavior, test and schema failures remain visible and fail; inspect selected files and exercise conservative unfiltered fallback. Report timings, failure outcomes, assumptions and limits, including setup and maintenance costs.
- Retain the exact pin and minimal config only if demonstrated net end-to-end savings survive conservative fallbacks. Otherwise report the trial numbers without retaining either. A dependency pin requires full `mix check` and one independent review; run `git diff --check`. This is a bounded trial, not a new selection system.
