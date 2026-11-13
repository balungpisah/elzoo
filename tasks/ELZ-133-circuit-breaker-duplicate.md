# ELZ-133 — Make C8 duplicate-reset evidence independent of arbitrary scheduling gaps

- Dependencies: none
- Allowed implementation path: `pieces/delivery/circuit-breaker/test/elzoo/circuit_breaker_test.exs` only.

Contract: unchanged. The original fixture owner has `cooldown_ms: 30`; the rejected duplicate's `cooldown_ms: 60000` does not extend it. Preserve duplicate refusal, original-owner/provider no-reset evidence, cold replacement and old-token rejection. Establish provider readiness and require a conclusive monotonic observation interval enclosing trip, rejected duplicate and provider sample wholly before the existing 30 ms reset boundary. Reacquire an inconclusive sample only within the existing bounded helper; fail if no conclusive sample is obtained. Never skip the provider assertion or accept the permitted later auto-reset as evidence of a duplicate reset. Keep all cooldowns, timeouts and wait bounds unchanged; no runtime, selector or provenance changes.

## Acceptance

- A controlled scheduling gap beyond 30 ms is recognized as inconclusive, not a passing or failing duplicate-reset verdict; the same bounded oracle must subsequently obtain and assert a conclusive sample or fail. A temporary duplicate provider-reset/reinstallation defect must fail that oracle.
- Run `mix test pieces/delivery/circuit-breaker/test`, including C3–C23 and unchanged original/renamed C20; `mix check --piece "$(git merge-base origin/main HEAD)"`; `git diff --check`; independent review and exact-head hosted evidence under AGENTS.md. Original copied-C8 failure remains recorded.

The bounded sampling oracle is an admission design, not yet demonstrated code. It must not turn repeated provider `:ok` results into inconclusive samples or let the reset-negative pass. If the negative survives or broader paths or limits are needed, stop implementation for coordinator scope review. Investigation #272 retains ai-text as an unresolved required follow-up. No dependency or pin changes or new framework.
