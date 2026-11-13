# ELZ-132 — Synchronize DY7 with actual Registry cleanup

- Dependencies: none
- Allowed implementation path: `pieces/runtime/dynamic-units/test/elzoo/dynamic_units_test.exs` only.

Contract: unchanged. Successful stop confirms child termination and supervisor-spec removal; Registry exit cleanup is asynchronous. Preserve the eventual `Registry.count == 0` assertion and all existing DY7 atom, directory, monitor, capacity and infrastructure-reset assertions. Use the existing bounded `eventually` helper without changing its deadline or polling interval. Do not change runtime code, cooldowns, test timeouts, selectors, provenance or required gates.

## Acceptance

- Hold the Registry cleanup partition after registration; public stop must finish with a dead child and zero supervisor specs, while the emptiness check cannot pass with cleanup held. Release cleanup and require count zero. A negative control retaining a live registration must fail the bounded emptiness assertion.
- Run `mix test pieces/runtime/dynamic-units/test`, `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`; independent review and exact-head hosted evidence under AGENTS.md are required. Original gate failure remains recorded.

Investigation #272 also tracks the separate C8 failure and the unresolved required ai-text follow-up; this task does not claim to resolve them. No dependency or pin changes or new framework. Stop for scope review if the repair cannot fit this path.
