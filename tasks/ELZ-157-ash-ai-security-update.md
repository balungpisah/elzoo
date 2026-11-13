# ELZ-157 — Update the AshAi spike pin for the tool-error disclosure advisory

- Dependencies: none
- Allowed implementation paths: `spikes/ash_foundation/mix.exs`, `spikes/ash_foundation/mix.lock`, `spikes/ash_foundation/README.md` only.

Issue #223 records advisory EEF-CVE-2026-119613 for AshAi 1.5.0: unrecognized tool errors can disclose internal details to MCP clients and the model. The advisory is fixed in 1.5.1. Update the spike's exact AshAi pin to 1.5.4 and reconcile its lockfile and README.

Contract: no Piece or Contract change. Change no other direct dependency pin. Change a transitive lock entry only when the dependency solve strictly requires it for AshAi 1.5.4; list every such change and its reason in the pull request. No root dependency, runtime code, test, CI or shared configuration change is in scope. If the update needs another path, stop for the coordinator's scope decision.

## Acceptance

- `mix.exs` pins `{:ash_ai, "== 1.5.4"}`; `mix.lock` records that release with its resolved dependency metadata and checksums. The README's version statement and AshAi reference agree with the new pin.
- Record the advisory output of `mix setup` and any available dependency-audit command, such as `mix deps.audit`, with exact commands and exit codes. EEF-CVE-2026-119613 must no longer be reported for the resolved AshAi dependency. State which audit mechanism ran; if no audit mechanism is available, state that limitation rather than treating silence as an audit result. Do not suppress an advisory or weaken a check.
- From the spike directory, `mix format --check-formatted` and `mix test --warnings-as-errors` exit 0. Existing direct/tool authorization, tenant isolation, invalid-input and supervised-execution scenarios remain unchanged and pass.
- From the repository root, run `mix setup`, full `mix check` with no flag, and `git diff --check` before delivery. Record exact commands and exit codes. A selected Piece gate is not a substitute for the full check.
- The implementation pull request references and closes issue #223 as well as its published task issue, and states every transitive lock change, or explicitly states that there is none.

## Limits

No exposure assessment of downstream deployments. The advisory and the dependency update do not establish whether any deployment was exploitable. No new Piece, upstream proof or universal security claim is made.

One worker owns the claimed branch/worktree. One independent review under AGENTS.md section 6.
