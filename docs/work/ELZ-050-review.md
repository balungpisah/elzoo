# ELZ-050 independent read-only review

> Redacted before publication (ELZ-070): local paths, session, dispatch, task and message ids, the test database name and role, and runner and machine names are replaced by placeholders or role words; hashes and byte-equality records in this file refer to the unredacted text.

Reviewer: an independent review session
Reviewed SHA: `3604181713d800dfa3fc0e3a27c2fe02cde44610`
Base SHA and observed origin/main: `ade0e45ca2ff961fff33812212d3b7a26f008d69`
Branch: `task/ELZ-050`
Contract: https://github.com/balungpisah/elzoo/issues/103

I reviewed the actual pinned diff, task Contract, work record, owner decisions, ranking, all 53 rendered dispositions, and relevant existing boundary documentation without editing the repository.
All requested executable checks passed, the task copy matches the live issue byte for byte, and the sampled Hex metadata and requested owner choices agree, but three documentation findings prevent unconditional clearance.
Remaining work is to correct the audit-log assumptions, explicitly reconcile dependency/order disagreements, and remove the conflicting Assembly-first admission wording before a focused documentation re-review and the coordinator's normal integration steps.

## Commands and exit codes

Working directory for repository commands: `<worktrees>/elzoo-ELZ-050`

| Command / check | Exit | Result |
| --- | --- | --- |
| `git rev-parse HEAD origin/main` | 0 | Exact SHAs above |
| `git status --short` (before and after review checks) | 0 | Empty |
| `git diff --name-only ade0e45 3604181` | 0 | 37 paths; 36 under docs/ plus only tasks/ELZ-050-catalogue-dispositions.md |
| Python path allowlist assertion over that diff | 0 | No registry/, pieces/, lib/, test/, LEDGER.md, mix.exs, mix.lock or .github/ change |
| `git diff ade0e45 3604181 -- docs/catalogue.md docs/plans/roadmap.md docs/plans/release-plan.json docs/work/ELZ-050.md` | 0 | Actual diff inspected |
| `gh issue view 103 -R balungpisah/elzoo --json body` | 0 | JSON-decoded body encoded as UTF-8 and compared to read_bytes(), no trimming |
| Python live-body byte comparison | 0 | Both 7012 bytes; equal; SHA256 3807b34168b9bab326762d1a562ee76400750a6c15b104652b1ea4ce6dc1f968 |
| `python3 scripts/check-roadmap.py` | 0 | 97 IDs, 2 separate candidates, 77 jobs, 12 products; acyclic/release-ordered; generated views agree; 277 local links |
| `python3 scripts/check-roadmap.py --live` | 0 | Same checks; live Contracts match |
| `python3 scripts/check-claims.py` | 0 | No tracked claim metadata |
| `git diff --check origin/main` | 0 | Clean, with no path exclusions |
| `python3 -I docs/work/ELZ-050-tools/render_dispositions.py . docs/work/ELZ-050-records docs/work/ELZ-050-evidence/hex-reverify.json /tmp/elz050-render-check.md /tmp/elz050-coverage.json` | 0 | 53 records, 53 targets, 0 problems |
| Python rendered-file comparison, normalizing only `Rendered <utc>` | 0 | Equal; rest of generated header also preserved |
| Python registry planned/deferred set versus `^### ` record headings | 0 | 53 targets, 53 unique headings; no missing/extra/duplicate IDs |
| Python regenerated coverage JSON versus committed JSON, excluding utc | 0 | Equal |
| Python read-only GETs to `https://hex.pm/api/packages/<name>` for five packages | 0 | All latest_stable_version and licenses values match; table below |
| Python isolated record/package coverage and local Markdown link/anchor scan | 0 | 50 listed relied-on packages, complete version/license/date metadata; 171 local links, no missing targets/anchors |
| `git log --oneline --parents ade0e45..3604181` | 0 | Normal merge 2e719e6 with parents 7d24dd2 and research tip 409d543 |
| `git diff --exit-code 409d543 3604181 -- docs/work/research/` | 0 | Research tree unchanged from merged tip |
| `git ls-remote --heads origin task/ELZ-027 task/ELZ-028 task/ELZ-029 task/ELZ-031` | 0 | No current remote claim branches |
| `gh issue view <44,45,46,48> -R balungpisah/elzoo --json state,title,labels` (four calls) | 0 each | All OPEN with ready label; labels treated as advisory |

Additional reviewer-command failures, disclosed and resolved: initial exploratory read of nonexistent `pieces/delivery/effect-intent/lib/elzoo/effect_intent/codec.ex` returned nonzero (combined command exit 1); subsequent actual `model.ex` read exit 0, identifying the imported `Elzoo.DurableLog.Codec`; first auxiliary Python AST literal-only package/link check exit 1 on `dict(...)` constructors, then rerun using the same isolated record-loading method as the renderer exit 0; neither failure a repository check failure or hidden pass

## Hex spot-check results

Committed metadata UTC: `2026-11-08T13:35:50.336745+00:00`

| Package | Live and committed latest stable | Live and committed licenses | Result |
| --- | --- | --- | --- |
| req_llm | 1.30.0 | Apache-2.0 | MATCH |
| req_s3 | 0.2.5 | Apache-2.0 | MATCH |
| ash_authentication | 4.15.1 | MIT | MATCH |
| phoenix_live_view | 1.2.13 | MIT | MATCH |
| khepri | 0.19.3 | Apache-2.0, MPL-2.0 | MATCH |

## Findings

### REQUIRED-DOCS R1 — Audit-log attribution and transaction limits

`docs/plans/catalogue-dispositions.md:886`: next action “use the effect-intent actor field”; no such field in the existing boundary: `pieces/delivery/effect-intent/README.md:22` defines identity as tenant, provider account, Adapter ID, operation kind and logical request reference; `pieces/delivery/effect-intent/lib/elzoo/effect_intent/model.ex:12` enumerates the exact model fields without actor; application-owned opaque arguments do not establish an actor field or authenticated attribution Contract

`docs/plans/catalogue-dispositions.md:876` says “consumer transaction/Repo” without carrying the known boundary limitation from `docs/plans/release-plan.json:1736`; `pieces/integration/sql/README.md:18` refuses Store calls inside caller transactions, while line 22 documents independently committed Writer calls; a trigger inside the Store transaction may be a candidate, but compatibility and actor propagation remain unexercised

Required correction: explicit unresolved attribution source and atomicity/provider-fit gate; preserve the owner's ELZ-023 mutation choice; no implied field, general Repo transaction composition, or silent ready-Contract expansion

### REQUIRED-DOCS R2 — Dependency and ordering disagreements remain implicit

Task Scope explicitly requires disagreements between ranking, actual dependencies and accepted decisions to be recorded

- `docs/plans/catalogue-dispositions.md:9`, `:694`, `:676`: object store second and notification third, but both require deferred integration/secrets; no explicit explanation of the prerequisite work or narrowly reviewed injected-credential alternative needed to preserve the owner's priority order
- `:881` and `:886`: audit-log requires deferred domain/principal while proposing work before principal exists; mandatory versus conditional prerequisite unresolved
- `:515` onward, domain/quota: V1 record requires V2 domain/metering, whereas canonical RC-08 does not depend on RC-21; roadmap's green release-order check validates the canonical graph, not this added disposition graph
- `:739` onward, integration/sdk: owner's MCP-client direction versus canonical RC-30's foreign-consumer/TypeScript-candidate scope and RC-17 prerequisite; divergence not expressly reconciled

Required correction: explicit discrepancy notes with a decision owner and next action, distinguishing owner priority from executable prerequisite order and distinguishing proposed record edges from canonical planning dependencies; no automatic reorder or extra task publication

### REQUIRED-DOCS R3 — Catalogue retains conflicting admission instructions

`docs/catalogue.md:24-26`: “select a real Assembly before opening implementation tasks”; `:67` defer definition: “must be pulled in by a concrete assembly and researched then”; both still read as current requirements alongside the new rule at `:49-59` that all planned/deferred entries belong to the build plan and demand-led admission applies only outside the catalogue

Required correction: reconcile or explicitly mark the old instructions as superseded; retain concrete caller, invariant, published task, and conditional no-caller gates without requiring a new Assembly for every catalogue Piece

### LOW L1 — Broader research wording than the evidence supports

`docs/plans/catalogue-dispositions.md:487`: “No tariff engine fits” stronger than ranking R32's “No exact tariff engine established”; prefer surveyed-fit wording and the bounded search result

`docs/plans/catalogue-dispositions.md:836`: telemetry as the mechanism “every surveyed library already emits through”; no per-library universal evidence attached; scope to the relevant libraries/boundaries actually examined

### LOW L2 — Static claimability assertions need observation scope

`docs/plans/catalogue-dispositions.md:9`, `:343`, `:437`, `:825`, `:912`: “claimable now” / “ready to claim”; live issue/remote observations agree at review time and these describe task claimability rather than Piece readiness, but qualify with observation date and recheck-live-branch instruction to avoid a permanent claim lock assertion

### LOW L3 — Auxiliary reviewer checks initially failed

Nonzero exploratory path read and literal-only record parser as disclosed above; both resolved through successful reads/checks; no outstanding task-check failure

## Owner-decision fidelity

| Record | Finding against owner record |
| --- | --- |
| integration/ai-model | NONE — ReqLLM to Anthropic directly; key Need; no gateway; TensorZero excluded |
| integration/object-store | NONE — MinIO S3-only; req_s3 first; ExAws conditional multipart fallback |
| integration/identity | NONE — AshAuthentication selected; later OIDC; explicit Assent version conflict |
| integration/agent-runner | NONE — Claude Code CLI and Codex CLI as OS processes through ELZ-029; no Elixir SDK |
| integration/payments | NONE — Provider deferred/open; Stripe conditional, no invented choice |
| integration/message-broker | NONE — Owner decision deferred/no caller/open provider, with registry status honestly still planned |
| state/crdt; state/replication; assembly/consent-records | NONE — Conditional/no caller; no implementation admission inferred |
| ui/component | NONE — Phoenix LiveView; Lustre optional; afternoon facts prevail |
| domain/metering | NONE — ReqLLM per-call usage through ready Store |
| workflow/run; delivery/trigger | NONE — Jido ideas clean-room/module by module; no literal copy; agent kernel rejected where relevant |
| integration/notification; state/audit-log | NONE for owner selection — plain SMTP/Swoosh and ELZ-023 mutation with Carbonite/AshPaperTrail comparison; R1 concerns unsupported implementation inference |

Wording audit: no new Piece readiness, tested provider boundary, formal proof or adoption badge asserted by the added dispositions/catalogue/roadmap prose; existing catalogue readiness descriptions concern previously merged scoped bundles; task-claimability statements flagged separately in L2; no contradiction found in the explicit Owner decision fields for the requested records; R1's invented field and L1's broad research statements remain unsupported reviewer assertions

Contract delivery: anchored coverage, required field structure, acyclic references, dependency status labels, committed coverage and Hex output, normal research merge, links, published ELZ-050 job with empty outputs, generated views, exact issue copy, and allowed path scope all present; unresolved Contract obligations concentrated in R1–R3's accurate boundary limits, explicit disagreement accounting, and consistent admission instructions

Grounding: documentation/structural checks and five live Hex metadata observations only; no library execution, provider-boundary test, Cure proof, mix setup, or mix check; no repository edits, commits, pushes, labels, or comments; PR/merge/cleanup outside this read-only review

Verdict: CONDITIONAL — correct REQUIRED-DOCS R1, R2 and R3, then focused re-review of the revised documentation
