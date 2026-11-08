# ELZ-050 focused independent re-review

Reviewer: `orca_session_id:0e1ac343-b55f-4201-9987-f8083645211e`
Reviewed SHA: `8e0fe422bc194259af1764bff1f1211a979ea3e0`
Prior reviewed SHA / delta base: `3604181713d800dfa3fc0e3a27c2fe02cde44610`
Original task base: `ade0e45ca2ff961fff33812212d3b7a26f008d69`
Observed `origin/main`: `665d3e07c58fb9a3e7818a037a6910132535fa53`
Branch: `task/ELZ-050`; Contract: https://github.com/balungpisah/elzoo/issues/103

I independently re-reviewed the documentation delta against my prior findings and reran the requested documentation checks.
The original audit, admission, wording, and claimability fixes are present and all requested checks pass, but the new SDK disagreement description overstates the scope of canonical RC-30.
Correct that description before clearance, then merge the advanced main branch and assess the resulting changes under the normal integration workflow.

## Commands and exit codes

Working directory: `/Users/laptopdp/orca/workspaces/elzoo/elzoo-ELZ-050`

| Command / check | Exit | Result |
| --- | --- | --- |
| `git rev-parse HEAD origin/main` | 0 | Head and observed main above |
| `git status --short` | 0 | Empty before and after checks |
| `git diff --stat 3604181 8e0fe42` and `git diff 3604181 8e0fe42` over catalogue, dispositions, work record, renderer and record sources | 0 | Ten changed paths, all under docs/; delta inspected |
| `python3 scripts/check-roadmap.py` | 0 | 97 IDs, 2 candidates, 77 jobs, 12 products, acyclic/release-ordered, generated views agree, 277 links |
| `python3 scripts/check-roadmap.py --live` | 0 | Same; live Contracts match |
| `python3 scripts/check-claims.py` | 0 | No tracked claim metadata |
| `git diff --check origin/main` | 0 | Clean, no exclusions |
| `python3 -I docs/work/ELZ-050-tools/render_dispositions.py . docs/work/ELZ-050-records docs/work/ELZ-050-evidence/hex-reverify.json /tmp/elz050-rereview-render.md /tmp/elz050-rereview-coverage.json` | 0 | 53 records, 53 targets, 0 problems |
| Python comparison of rendered output and committed dispositions, normalizing only `Rendered <utc>` | 0 | Equal |
| Python comparison of coverage output and committed JSON, excluding utc | 0 | Equal |
| `git merge-base --is-ancestor origin/main HEAD` | 1 | Main advanced; not an ancestor of reviewed HEAD, expected integration work, not a requested validation failure |
| `git log --oneline HEAD..origin/main` | 0 | Includes merge PR #102 / ELZ-012 at 665d3e0 |
| `sha256sum docs/work/ELZ-050-review.md /tmp/elz050-review-report-0e1ac343-b55f-4201-9987-f8083645211e.md` | 0 | Both b3235c10635e9570aa3d1b77b0d2a5117d3e954c66add89ebdf92420bf1e6220 |
| `rg -n '"(oban|req|ecto|telemetry)": ' mix.lock` and `rg -n '"(finch|mint)":' mix.lock` | 0 each | telemetry 1.4.2; direct Oban/Ecto and transitive Req via Finch dependency evidence |

## Findings

### REQUIRED-DOCS R2-FOLLOWUP — RC-30 scope incorrectly described

`docs/plans/catalogue-dispositions.md:18` and its source `docs/work/ELZ-050-records/records_notes.py` state that canonical RC-30 scopes `integration/sdk` as “Python/TypeScript/Rust/Go foreign-unit SDKs”

`docs/plans/release-plan.json`, RC-30, instead specifies “One actual foreign language” with TypeScript first unless the target workflow supports another need and expressly states “no four-language promise”; its dependencies do include RC-17, and the owner's first MCP client differs from the canonical proposal as the new record correctly observes

Required correction: describe the canonical proposal as one foreign-consumer protocol, TypeScript a candidate, no four-language promise, preserving RC-17 and the decision owner/next action; regenerate the dispositions and rerun the renderer and applicable checks

### BLOCKING

NONE for the focused re-review; REQUIRED-DOCS R2-FOLLOWUP prevents a CLEAR verdict

### LOW

NONE newly identified; integration note: observed main advanced to `665d3e0` after the original base, so the clean `git diff --check origin/main` does not mean the reviewed branch includes main; merge normally and reassess the actual resulting head as required by AGENTS.md

## Prior findings and disposition table

| Finding | Observation at reviewed SHA | Result |
| --- | --- | --- |
| R1 | Audit record explicitly says effect-intent has no actor field; names both SQL caller-transaction refusal and independent Writer commits; Carbonite fit unexercised before ELZ-055 readiness; two questions with owners and next actions | Resolved; future actor input is an open proposal, not an existing ready field or granted Contract change; any change to a ready Piece Contract follows new-ID rules |
| R2 secrets | Owner priority, deferred secrets prerequisite, explicit injected-credential option, decision owner and next action recorded | Resolved as a decision record; no prerequisite automatically waived |
| R2 principal/audit | Principal dependency and missing actor, conditional prerequisite, decision owner and next action recorded | Resolved as a decision record; actual attribution remains open |
| R2 quota/metering | Quota no longer has metering in Depends on; C9 conditional input and V1/V2 canonical disagreement recorded with owner/action | Resolved |
| R2 SDK | MCP-client disagreement, RC-17, owner/action present | Partially resolved; new inaccurate four-language scope wording in R2-FOLLOWUP |
| R2 priority/prerequisite | Priority explicitly distinguished from prerequisite order with owner/action | Resolved |
| R3 | Assembly-first sentence explicitly superseded 2026-11-08; defer row now states plan membership and no mandatory Assembly | Resolved |
| L1 | Pricing limited to surveyed packages; telemetry claim refers to lockfile rather than all surveyed libraries | Resolved; Req relationship transitive via Finch |
| L2 | Former claimability assertions changed to observed open/ready/no-branch status at 2026-11-08T13:40Z with live issue and remote branch recheck | Resolved |
| L3 | Prior reviewer auxiliary failures retained in exact prior report | Correctly disclosed |

`docs/work/ELZ-050.md:97-104` accurately summarizes the edits and their stated purpose, with the substantive qualification that the new R2 disagreement section still misstates canonical RC-30 as described above; its table is not independent evidence of correctness

## Grounding and limits

Documentation/structural checks only; no runtime or provider tests, Cure proofs, `mix setup`, or `mix check`; no repository edits, commits, pushes, labels, or comments; prior Hex sampling and live body byte comparison are recorded in the earlier review, not rerun for this focused request

Verdict: CONDITIONAL — correct REQUIRED-DOCS R2-FOLLOWUP and regenerate; subsequent normal main integration needs an assessment of the resulting head
