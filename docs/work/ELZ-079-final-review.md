# ELZ-079 final independent review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `2ce0684833acc68234cebd7a3ca3b48bbde2292f`

Inputs: `git fetch origin`; `git diff --stat origin/main...2ce0684833acc68234cebd7a3ca3b48bbde2292f`; full named-SHA diff and named-SHA source reads; PR #164 body; live issue #153 body; the amendment-1 and proposed amendment-2 records; and the checked-in `req_llm` 1.30.0, Req, and related dependency sources. I did not run Mix, make a provider call, modify repository files, or post on GitHub.

The review applies amendment 1 as approved and amendment 2 as proposed, as requested. The live API observed during review has subsequently moved beyond that frozen contract, so PR-body statements about amendment 2 are treated as an inconsistency to correct rather than as acceptance evidence for this SHA.

## Findings

1. **blocking — the PR depends on approval of amendment 2; without it, the published acceptance remains unmet.**

   Locations: `tasks/ELZ-079-ai-model-text-anthropic.md:301-302`; `docs/work/ELZ-079-amendment-2.md:1-32`; `test/support/cure_consumer_case_test_helper.exs:75-85`.

   Problem: the task copy still requires a consumer that copies only the core and interface. This SHA deliberately has no such per-ID consumer and changes neither the consumer helper nor selection module. Amendment 2 is therefore not merely editorial: it is required to replace an otherwise unsatisfied acceptance item. The aggregate consumer and the provider-free scripted interface tests are consistent with the proposed replacement, but cannot satisfy the original text.

   Concrete change: obtain the main decision on amendment 2 before acceptance. If approved, apply it once to the issue, synchronize the task copy and release-plan hash to the amended body, and state in the PR that the aggregate consumer plus provider-free interface tests are the evidence. If it is not approved, add the required core-plus-interface consumer in the separately authorized scope before merging.

2. **blocking — exported consumers do not actually receive or verify the required `load_dotenv: false` configuration.**

   Locations: `pieces/integration/ai-text-anthropic/README.md:39-42`; `test/support/cure_consumer_case_test_helper.exs:122-133`; `pieces/integration/ai-text-anthropic/test/elzoo/ai_text_anthropic_test.exs:508-513`.

   Problem: the Anthropic Piece says every consumer must configure `req_llm` with dotenv loading disabled, but the copied-consumer harness writes only `mix.exs` and `test/test_helper.exs`; it does not create or merge a configuration file. A8 explicitly compensates by setting the application value at runtime before restarting `req_llm`. That demonstrates the setting works after a test supplies it, not that an exported consumer has it. A consumer with a working-directory dotenv file can therefore start the dependency without the required protection.

   Concrete change: make the export/install path carry an explicit, test-exercised configuration instruction that the copied-consumer test merges before the dependency starts, or make the generated consumer configuration include the setting when the selected provider closure includes `req_llm`. Add a copied-consumer scenario with a dotenv sentinel that proves the configuration is active at application startup. Coordinate this shared-harness change because the task explicitly reserves that ownership area.

3. **should-fix — PR evidence is not for the reviewed head and contradicts the frozen amendment state.**

   Locations: PR #164 body:5, :10-11, :20-24; `docs/work/ELZ-079-amendment-2.md:1-32`.

   Problem: the PR body names a different head, says amendment 2 has already been approved, and reports the required affected and class-X full checks as not run. The requested review contract treats amendment 2 as proposed and names `2ce0684` as the review target. The body therefore cannot be used as exact-head grounding, and the acceptance command remains unrecorded for this SHA.

   Concrete change: after the amendment decision and required gates, update the PR body to the exact final head, exact commands and exit codes, hosted run, actual amendment state and matching issue-body hash. Do not call the Cure decision a proof unless selected laws were actually checked.

4. **should-fix — remove the non-provider hostname from the public PR body.**

   Location: PR #164 body:44.

   Problem: the generator attribution is a public hyperlink to a non-provider host. It violates the task's public-writing rule and contributes no Contract or evidence.

   Concrete change: delete the generator attribution and any equivalent non-provider badge or link before posting the final PR body/comment.

## What was checked and found sound

- The named-SHA diff is scoped to the three Pieces, their task/evidence/registry/ledger artifacts, and the admitted dependency/configuration change. It does not change `test/support/cure_consumer_case_test_helper.exs` or `lib/elzoo/check_selection.ex`.
- `mix.lock` adds the intended closure only; no existing lock line changes. Req remains 0.7.5 and Finch remains 0.24.0. `req_llm` is not runtime-disabled, Plug is test-only at the root and recorded as a provider, and the repository configuration change is the expected dotenv setting.
- The core is pure by source inspection. The interface uses its scripted test provider, the conformance kit is under interface `lib/`, support stays in each Piece test tree, and the source lists in the manifests cover the added sources.
- The adapter obtains and shape-checks the injected credential before the provider call; Anthropic declares no sampling feature, fixes the stated version, sets `max_retries: 0` and Req retry false, and prepends capture/halting steps. Its raw usage translation preserves absent values as `:unknown`; the cache-hint tenant check, inert tool callback/source audit, malformed tool marking, structured-output validation, failure table, Cure table comparison and volatile sink are all present with named finite tests.
- The provider tests use function-plug stubs and record the hand-derived request-schema provenance and R5 limit. Static source searches found no `docs/` or `tasks/` literal in Piece sources, and no own-source tool-execution or ambient-key-read path.
- The three catalogue rows, provider records/licenses, release-plan output move/RC-16 supersession, views and generated ledger are present. At the reviewed SHA the task-copy SHA equals amendment 1's recorded hash, as expected before proposed amendment 2 is adopted.

## Verdict

**request changes** — resolve both blocking acceptance/configuration issues, then refresh exact-head PR evidence and public writing before approval.
