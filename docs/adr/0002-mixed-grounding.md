# ADR-0002: Use mixed grounding per claim

*Status:* accepted for bootstrap

*Date:* 2026-11-05

## Context

Cure is a good home for small pure decisions and selected laws. OTP and
maintained Elixir libraries already implement supervision, JSON, HTTP,
storage and other runtime concerns. Re-proving every upstream implementation
would be both impractical and misleading; treating a library call as a pure
theorem would be unsafe.

## Decision

Record grounding at the claim boundary. Use Cure checked terms/proofs for
selected pure invariants, Cure/schema checks for connections, executable tests
for model and integration behavior, monitoring for live operational claims,
and the upstream public contract for reused implementations. Foreign calls
remain explicit assumptions and their outputs are validated as untrusted
inputs. Pure upstream functions such as `Enum`, `Stream` or a hash may be
called directly when their contract is sufficient; an effectful or untyped
call stays behind an adapter. No operation requires a proof merely because it
is in the catalogue.

## Consequences

Evidence is honest about its scope: a passing Jason test supports Elzoo's
adapter translation, not Jason's implementation; a GenServer test supports
the tested lifecycle, not distributed crash equivalence. Every adapter records
the upstream version and the exact behavior it relies on. A claim with no
appropriate grounding remains a task, not an assurance badge.
