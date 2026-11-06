# Ecosystem reference study, round 2 (ELZ-025)

Second adopt-or-distill round after the Raxol study in
orchestration-references.md. Seven concurrent study sessions pinned, read and
compared sixteen Elixir/Gleam packages with docs/capability-model.md,
docs/capability-coverage.md and registry/catalogue.json. Full reports with
file:line citations at the pinned revisions are under studies/round-2/. Dates
are observation dates (2026-11-06); the index corrects one report figure:
bankai's author split is 85/18 commits at tag ba16fc12 and 102/18 at main
727cd6ff, not 119/18; maintenance signals are public metadata,
not quality claims. No source is copied and no dependency is added.

Verdicts: adopt-candidate = a named deferred/planned handle and the exact
boundary a future task must exercise (never "ready"); distill = Elzoo writes
the idea as Contract text, design test or admission record; skip = dated
reason. Result: 0 adopt-candidates, 10 distill, 6 skip.

## Summary

| Package | Pinned revision | License (observed) | Pinned commit date (repo tip) | Verdict | Report |
| --- | --- | --- | --- | --- | --- |
| money_pattern 1.0.0 (Gleam) | Kelvin-Jesus/Money 4eb85e5f (tag v1.0.0) | conflict: Hex/gleam.toml Apache-2.0, shipped LICENSE MIT | 2026-02-18 (tag = tip) | skip: 49 lines, free-string currency, fixed 2 minor units, Float formatting | studies/round-2/money.md |
| dime 1.2.0 (Gleam) | horvathandris/dime 9c3e35e7 (tag v1.2.0) | Apache-2.0 | 2025-10-28 (HEAD 2026-06-30 unreleased) | distill → ELZ-031 domain/money registry Contract and dataset tests; Gleam-only, no backend adoption | studies/round-2/money.md |
| pricing 0.6.9 (Elixir) | arthurcolle/pricing 4989d40c (HEAD, no tag) | Hex "Colle" (non-SPDX); MIT text retitled | 2023-01-31 (HEAD) | skip: Black-Scholes via C/GSL shell-out; tests do not compile; unrelated to domain/pricing | studies/round-2/money.md |
| jido 3.0.0-beta.2 | agentjido/jido eb5f5818 (tag) | Apache-2.0 (transitive runic/multigraph unchecked) | 2026-10-19 | distill → ELZ-009/010/023/027, workflow/run, state/audit-log; mandatory host (13 requirements incl. two sibling betas, one alpha) | studies/round-2/jido.md |
| jido_action 3.0.0-beta.22 | agentjido/jido_action 9fe61b13 (tag) | Apache-2.0 | 2026-10-22 | distill → ELZ-026 issue kinds, integration/ai-model resolution rule, ELZ-010 restart budget; execution delegated to runic alpha | studies/round-2/jido.md |
| pixir 0.1.17 | Ranvier-Technologies/pixir 7eb163da (main; no tags) | MIT | 2026-09-08 | distill → ELZ-024/023/022/028/029, workflow/run; 78 kLOC single author, finch 0.23 exact pin conflicts with Elzoo | studies/round-2/pixir.md |
| fabric 0.2.0 (Gleam) | gleam-dream/fabric 3a1ca2ac (tag v0.2.0) | Apache-2.0 (json_blueprint MIT) | 2026-11-04 (first public commit 2026-10-24) | distill → ELZ-024/023/009/010/022/028, domain/metering, idempotency key derivation; backend Gleam host excluded by gleam-libraries.md | studies/round-2/fabric.md |
| bankai 0.4.0 (Gleam) | moneyacademyKE/bankai ba16fc12 (tag v0.4.0) | Apache-2.0 (dep aarondb 4.2.0 without source link) | 2026-10-11 (main 727cd6ff 2026-10-27) | distill → ELZ-026, ELZ-009, workflow/work-item, state/lease, state/artifact, ELZ-030; Mnesia daemon host | studies/round-2/bankai.md |
| lux 0.5.0 | Hex tarball (no reproducing commit; nearest 37f05ab3) | MIT | 2025-05-14 | distill (negative tests) → integration/ai-model, delivery/aggregation, ELZ-023/024/027; stale, 9 mandatory deps | studies/round-2/frameworks.md |
| sigil 0.1.4 | sigilframework/sigil fa3513fd | MIT | 2026-04-04 | distill → ELZ-009, ELZ-023, ELZ-024, workflow/run, ELZ-030; one-week-old 0.1.x at pin | studies/round-2/frameworks.md |
| shifts 0.0.2 | Hex tarball only (repo history starts after release) | Apache-2.0 | 2024-06-21 | skip: dormant, TODO moduledocs; one correlation sentence folded into delivery/aggregation | studies/round-2/frameworks.md |
| staff_ai 0.0.4 (Gleam) | chainyo/staff-ai b549de4a (tag) | conflict: Apache-2.0 declared, no LICENSE text, "All rights reserved" header | 2024-03-21 | skip: 163 lines of record constructors; the universal Task record the capability model warns against | studies/round-2/frameworks.md |
| theory_craft 0.1.0-dev | theorycraft-trading/theory_craft a19d6783 (no tag) | Apache-2.0 | 2025-12-26 (tip 2026-02-16) | distill → delivery/aggregation and delivery/data-stream design tests; adopt nothing | studies/round-2/finance.md |
| quant 0.1.0-alpha.1 | the-nerd-company/quant 463c70d2 (no tag) | CC-BY-NC-4.0: not adoptable | 2025-10-17 (tip 2026-08-22) | skip: non-commercial license; ideas already in C9/ELZ-022 | studies/round-2/finance.md |
| pluggy_ai 0.1.1 | fellipessanha/pluggy_ai_ex a0d33494 (tag v0.1.1) | MIT metadata; LICENSE.txt is the unfilled template | 2026-06-08 (tip 2026-07-20) | distill → ELZ-023 transport re-send case, ELZ-011 second source, integration/payments id derivation | studies/round-2/finance.md |
| ursatoro 1.0.1 (Gleam) | GG-O-BP/ursatoro 722aaed2 (tag) | BlueOak-1.0.0 | 2026-03-22 | skip: product-domain indicator math, no coverage case | studies/round-2/finance.md |

Why nothing is adopted: every orchestration package is a mandatory process
host (jido AgentServer, pixir, fabric, bankai daemon) or stale (lux, shifts,
staff_ai); the Gleam hosts are excluded for backend consumers by
gleam-libraries.md and AGENTS.md; four packages have license defects. The
mechanisms that matter are each small enough to state as Elzoo Contracts.

## Where the distilled material went

| Handle / task | Source | What was added |
| --- | --- | --- |
| ELZ-026 workflow/dependency-graph (new body) | bankai, jido_action, pixir | pure readiness + cycle-admission reducer; closed ≠ completed; three issue kinds; provenance-tagged readiness |
| ELZ-027 delivery/trigger (new body) | jido, lux | schedule occurrence identity `(schedule id, generation, instant)`, overlap policy skip/queue/replace |
| ELZ-028 state/lease (new body) | fabric, pixir, bankai | fencing by record revision, store clock, renew-only-live, disjoint claim_expired, stale/ambiguous fail closed |
| ELZ-029 runtime/os-isolation (new body) | pixir | process-group leader, term→grace→kill with observed stage, reaper, queue_full vs queue_timeout, non-zero exit is completed |
| ELZ-030 workflow/context-selection (new body) | sigil, bankai | window + reservations + access-checked versioned candidates; dropped-with-reason; derived items carry provenance |
| ELZ-031 domain/money (new body) | dime, money_pattern | closed versioned registry with exponent; malformed vs unknown parse; retired codes; dataset round-trip tests |
| ELZ-009 state/event-log, state/checkpoint, state/outbox | jido, fabric, bankai, pixir, sigil | three-way write result conflict/rejected/indeterminate; unavailable = unknown confirmed only by exact readback with nonce; single-advance revisions; head+version+event in one commit; replay-order backstop; checkpoint never ahead of the acknowledged tail; replay total over event kinds; provider conformance list; outbox batch transient, intent is committed state |
| ELZ-010 assembly/durable-job, state/schema-evolution | jido_action, fabric | retry budget persisted with the Run or bounded to one lifetime; down-level writer fails closed; frozen old-reader fixture (conditional on exercising evolution) |
| ELZ-011 runtime/adapter | pluggy_ai | second source for the no-atom-minting test |
| ELZ-022 workflow/budget | fabric, pixir, lux | sealed cap/unit per budget identity; unreadable owner state admits nothing; critical-path time admission before fan-out; turns as a budget unit |
| ELZ-023 delivery/effect-intent | fabric, pluggy_ai, pixir, lux, jido | total failure mapping at Assembly build; admission–dispatch schema drift; late settlement at most once; replay as a declared Adapter capability; transport-layer re-send; idle timeout after a durable output record is dispatched/unknown; exception-keyed retry negative test |
| ELZ-024 domain/authorization, workflow/approval | fabric, pixir, sigil, lux | release re-evaluates with current authority; approval reference `(Run, action, requirement, version, revision)`; approver evidence from the configured verifier; visibility is policy; restored pre-dispatch action re-enters the reducer; proposal carrying policy is denied; policy identity on every decision; denial is a retained record; static permission is an input; no model turn resolves an ASK; schema match is not authorization |
| workflow/run (reason text) | fabric, jido, pixir, sigil | outcome ≠ settlement; reciprocal parent/child attachment; cancellation names the Attempt, indeterminate cancellation terminates the owner; child spawn is an Effect with unknown outcome under timeout; owner observes attempt death by monitor; completed = durable evidence |
| delivery/aggregation (reason text) | lux, shifts, theory_craft, pixir | one result per declared branch identity; killed/timed-out branch recorded; correlate by Envelope key never arrival position; "no denials" ≠ "denial record unreadable" |
| delivery/data-stream (reason text) | theory_craft | in-band completeness marker; close-on-successor windows need end-of-stream and cancellation flush |
| integration/ai-model (reason text) | lux, shifts, fabric | provider Adapter returns tool-call proposals as data, never resolves or executes; usage carries a source tag `provider_reported`/`estimated`/`unknown`, never zero |
| integration/agent-runner (reason text) | jido_action, sigil | model-named tool resolves only through a host registry keyed `{stable id, version}`; resolution grants no authority |
| integration/payments (reason text) | pluggy_ai | client-supplied payment id derived from the logical request identity, never per attempt |
| domain/metering (reason text) | fabric | unreported provider usage is a distinct count, never zero; unverifiable budget stops admission |
| state/artifact (reason text) | bankai | SHA-256 over a versioned canonical encoding with a format-version prefix; verify on every read; format change is a declared migration |
| workflow/work-item (reason text) | bankai, lux | enumerated lifecycle transitions; completion bound to the current lease/authority holder; no-op transitions write nothing |
| state/audit-log (reason text) | jido, pixir | audit record commits atomically with the decision; bounded in-state list is not the retained trail |

### Non-binding references for ELZ-006 (claimed; Contract unchanged here)

From jido_action, jido, theory_craft and lux: retry eligibility is a property
of the classified failure, default not retryable; `timed_out`, `unknown` and
process-exit results are never retry-eligible by classification alone and
pass through delivery/effect-intent before any re-dispatch; a postponed-work
bound is not a mailbox bound and the Contract names which queue it limits; a
stage-level drop-oldest buffer in front of non-reconstructable input is
silent loss. ELZ-006's claimant decides whether any of this changes its
proposal.

### Skipped as a group

Agent-framework hosts, finance data providers, trading indicators, crypto or
exchange integrations, UI/admin layers, memory and self-improvement features:
product surfaces or mandatory hosts, outside the catalogue's reusable-Piece
scope.
