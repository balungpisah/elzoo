# ELZ-031 final diff review

Copied for publication; no redaction was needed; SHA-256 of the reviewer's original report: d9fbac6db49031bc57cf030ab5df4b409049a76de55770dc7557d3752bb742e5

Reviewer: the independent reviewer (Codex), final diff review. Reviewed commit `02c84a4bea20bc1e3a604c9aacf5d8c341c2b7eb` against `origin/main` at `3297219af46741442a3ccd49a15be9c93468d130`. The live branch and PR advanced to `c270e1bd72d1864b15a3f3833c68605577fda020` during this assignment, adding production and test changes; the full assessment below is of the requested earlier commit, with only focused inspection of the later change. Review of the new head and its exact-head full check remain necessary.

## Findings

**BLOCKING — codec accepts values it cannot replay.** `pieces/domain/money/lib/elzoo/money.ex` accepts arbitrary integer minor units; `pieces/domain/money/lib/elzoo/money/codec.ex` encodes them without a length bound, but rejects every encoded binary longer than 128 bytes. For example an amount constructed with `Integer.pow(10, 100)` produces a successful encoding longer than 128 bytes that `decode` rejects as `malformed_amount`. Arithmetic can also produce large valid integers. This violates the recorded canonical codec and replay guarantee; add a boundary-compatible design and a regression covering values constructed and calculated beyond the limit without silently narrowing the live Contract. Inspection indicates the later head retains this 128-byte mismatch; it was not executed in this review.

**BLOCKING — dated extract terms remain unverified (G5).** `pieces/domain/money/piece.json` and `docs/work/ELZ-031.md` explicitly say the extract's redistribution terms were not verified, while G5 requires licensing and the earlier independent review required the applicable terms to be verified before committing the extract. Attribution, hashes, and the coordinator's option choice do not establish those terms. Resolve or deliberately amend this gate with the appropriate decision and review; no legal conclusion is made here.

**REQUIRED — final head and check evidence.** The PR body states its checked head is `02c84a4`, but the live head now contains substantive changes. The reported `mix setup`/full `mix check` at that SHA, 32 and 683 passes, stage marker, times and two disclosed interrupted/failed runs appear in the PR body; the committed `docs/work/ELZ-031*` records contain the provider and derivation runs but do not independently record that full-check transcript, timestamps, marker or two failures. Treat these as author-reported, not independently corroborated by the committed records. The reviewer ran no Mix command; the current head needs a new full check, matching PR evidence and independent review. Checks observed on the live head: fast check pending, Gleam passed, automated review completed; these are not the required full acceptance run.

**REQUIRED — public-repository rule.** `docs/work/ELZ-031-confirmation.md`, `docs/work/ELZ-031-early-rereview.md` and `docs/work/ELZ-031-early-rereview3.md` still contain agent-platform identifiers; the latter two also mention a local temporary directory. The PR body includes an agent-platform attribution and automated-review badge. The claimed public-repository rule requires those references to be removed or otherwise explicitly reconciled. No credentials, hostnames or database names were identified in the inspected added lines; this is not a complete secret scan.

**REQUIRED — the later automated review's two findings remain unresolved at the inspected head.** The author replies precede the automated comments' updates and address earlier versions of the findings, so they do not dispose of the current findings: (1) malformed codec bytes mask an explicit unknown version because parsing precedes option validation; (2) a three-version registry fold can replace a retirement's `:not_recorded` with an old country-level withdrawal on the next snapshot. Both follow from the inspected later code. Add explicit dispositions and, if the stated contracts remain, regressions and fixes. No comment was posted by this reviewer.

**LOW — issue text comparison and planning scope.** The live issue and `tasks/ELZ-031-money-amounts.md` match apart from an extra trailing newline emitted by the issue view. `docs/plans/release-plan.json` also updates the ELZ-031 job's issue-body hash, in addition to the money catalogue entry; this reflects the published task amendment, but it is an additional field change to acknowledge when interpreting the narrowly worded shared-path scope.

## Gates

| Gate | Assessment and evidence |
| --- | --- |
| G1 | Substantially met: A1–A6 appear in the live issue and publication copy; `docs/work/ELZ-031-contract-proposed.md`, early re-reviews and confirmation record deliberation. Extract rights remain separate under G5. |
| G2 | Conditional: named shared paths and task copy only; protected paths unchanged. Roadmap/ledger regeneration at the reviewed tree is not independently established by this checkout. |
| G3 | Met on recorded evidence: `docs/work/ELZ-031-provider-probe.md` and `docs/work/ELZ-031-sql-probe.md` compare both versions, construction, allocation, JPY/BHD and Store round trips; final probe records five passes and Decimal selection. No rerun here. |
| G4 | Not met: version-specific forgery and synthetic update tests are present, including `values not in effect at their stated version are forged_currency` and `old bytes decode to their original identity and version status after the update`, but the codec fails for accepted large amounts. The later registry change also needs the three-version case above. |
| G5 | Not met: dated source header, 449-row derivation record and both-direction tests are present; redistribution terms remain unverified. `mix check` compares the extract, not upstream files. |
| G6 | Conditional: named tests cover JPY/BHD, signed allocations, bounded exhaustive sums, C9 mismatch, invalid inputs, and fixed-hundredth, Float, residual and deletion controls. These are finite tests; the current code has a replay defect, and execution is author-reported. |
| G7 | Substantively met on reported checks: selected Cure laws `add_same_currency`, `add_mismatch_names_both`, `subtract_same_currency`, `subtract_mismatch_names_both`, `compare_mismatch_names_both`, `negate_keeps_currency`, `invalid_ratios_rejected`, `shares_count`, `shares_currency`, `distribute_count`, `distribute_currency`, `allocate_count`, `allocate_currency`; decision-split hypotheses are explicit. Type/audit and mutation tests are separately categorized. Allocation sum and residual bound are finite tests, not Cure proofs. No independent Mix execution. |
| G8 | Conditional: Piece dependencies are empty; providers are Cure, Elixir and Decimal. SQL is a repository test rather than a copied Piece dependency, and the existing helper fails closed. Codec mismatch prevents full packaging/replay acceptance; copied-consumer execution is author-reported. |
| G9 | Conditional: Telemetry and Control are `not_applicable`, Config is `supported` with bounds/defaults and no hot reconfiguration; both referenced bundled tests exist. At the reviewed SHA `version:` is declared generally but several value functions ignore it; the later head changes this and needs review and tests as noted above. |
| G10 | Not met for the live head: PR reports the full green run and pins at the earlier head, but committed records do not corroborate that run and it cannot validate the new production diff. Independent review and exact-head checks are still needed. |

## Shared paths and data

| Area | Inspection |
| --- | --- |
| `mix.exs`, `mix.lock` | Only Decimal direct dependency `== 3.2.0` plus its comment/comma added; lock unchanged. |
| `registry/providers.json` | Decimal 3.2.0 Hex provider, documentation reference and Apache-2.0 entry added in existing format. |
| `registry/catalogue.json`, `docs/plans/release-plan.json` | Money row changed to ready, manifest path matches; at the reviewed commit the manifest SHA-256 is `5a43afa4a84fdce67d9b41695a33c1f8864d1ee1c622d4ddcc422ff6abc6fb84` and matches the committed Piece; planning note matches its Contract. Issue-body hash also changed as noted above. |
| `LEDGER.md`, `docs/plans/views.md` | Money ledger row text matches the Piece Contract. Ledger regeneration requires `mix elzoo.ledger`, which was not run; cannot independently certify generation. The roadmap script passed on the existing checkout only, not on the reviewed tree, so its generated views are not independently verified here. |
| `test/elz031_money_persistence_test.exs` | Uses the existing PostgreSQL harness's required URL and reachability checks; no skip. SQL dependency remains outside the copied source bundle. |
| Data | No SIX XML file in the branch diff; extract header names both sources, dates, download date and hashes. `docs/work/ELZ-031.md` records `--check`, 449 rows and source hashes plus negative runs; exact upstream derivation was not repeated. |
| Protected paths | No `test/export_test.exs`, `lib/mix/tasks/*`, `lib/elzoo/check_selection.ex`, workflow or script changes in the requested diff. |

## Commands and limits

- `git fetch origin --prune`: exit 0; `git diff --check origin/main...02c84a4`: exit 0; live-branch variant also exit 0.
- `gh pr view 118 --json body,files,comments`: exit 0; review comments API exit 0; `gh issue view 48 --json title,body`: exit 0. A subsequent issue comparison had a transient TLS timeout; retry produced exit 1 only for the extra terminal newline described above.
- `gh pr checks 118`: exit 8 while checks were pending; final observed state as above.
- `python3 scripts/check-roadmap.py`: exit 0; `python3 scripts/check-roadmap.py --live`: exit 1, ELZ-027 live task changed; `python3 scripts/check-claims.py`: exit 0. All three ran on existing checkout `019d9b13e364fcf28b23091b644c704b246eefc4`, not the reviewed tree, so do not establish the task-head results. Expected ELZ-029 discrepancy did not appear in that checkout's output.
- `git show`/diff, file and hash inspections were read-only; no Mix command, PR mutation, or repository edit was performed. The recorded implementation-head to reviewed-head delta contains only work documentation. These findings are scoped to inspected material and do not assert complete correctness or a clean security audit.

NOT CLEAR
