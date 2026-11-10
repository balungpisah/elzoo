# ELZ-085 final independent review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `e8e7eba542a1bcc9874ea652096e02755acd9627` (PR [#169](https://github.com/balungpisah/elzoo/pull/169), issue [#158](https://github.com/balungpisah/elzoo/issues/158)).

## Inputs

- `git fetch origin --prune`; `git diff --stat origin/main...e8e7eba542a1bcc9874ea652096e02755acd9627`; full named-SHA diff and source reads.
- PR #169 body; the live, unamended #158 body; `docs/work/ELZ-085.md` revision 2; and `docs/work/ELZ-085-early-review.md`.
- The named SHA's manifests, tests, metadata/ledger/roadmap artifacts, and local pinned Req 0.7.5 and req_llm 1.30.0 source. The task copy and live body are byte-equal and both SHA-256 to `793f988041cc46f487283244350e9c65aac7260a11f78d6aa1134c53328311ba`.
- I did not run Mix, call a provider, modify the reviewed repository, push, or comment on GitHub. At inspection, the PR's hosted `check-root`, `check-consumers`, and `check-consumers-db` jobs were pending; the PR body also accurately records that the local affected check was not completed.

## Findings

1. **High — the Q4 manifest verifies canonical submission input, not the exact provider create bytes that dispatch sends.**
   - Locations: `pieces/integration/ai-batch/lib/elzoo/ai_batch.ex:204-217,244-255`; `pieces/integration/ai-batch/lib/elzoo/ai_batch/adapter.ex:156-170`; `pieces/integration/ai-batch-anthropic/lib/elzoo/ai_batch/anthropic.ex:65-75,171-175`.
   - `admit_submit/2` calls `prepare/2` only to decide admission, discards its returned `wire`, and makes the manifest hash/length describe `canonical`, the internal submission JSON. At dispatch, `SubmitAdapter` obtains that JSON, decodes it, invokes `prepare/2` again, and `Anthropic.prepare/2` re-encodes a new outer body before `submit/2` sends it. Therefore the checked bytes are not the bytes sent, and neither the manifest nor the staging lookup binds the final outer body or its beta metadata; B6 checks the admission-time body-size calculation but does not establish identity with the dispatched body. This conflicts with the Q4 decision's exact immutable checked bytes/no re-encoding requirement.
   - Concrete change: during admission prepare one immutable provider submission, stage the exact outer body plus the necessary non-secret request metadata under the binding/intent key, and make the manifest length and digest name that staged wire. At dispatch verify those exact bytes and pass them directly to the provider transport without rerunning item translation or JSON encoding. Add a test that records the admission-time digest and asserts that the captured outbound body is byte-identical, including an attempted staged-wire substitution.

2. **High — the public lookup-Need API still permits raw submission bytes to reside in EffectIntent owner state through a closure.**
   - Locations: `pieces/integration/ai-batch/lib/elzoo/ai_batch.ex:100-138`; `pieces/integration/ai-batch/lib/elzoo/ai_batch/config.ex:4-31`; `pieces/integration/ai-batch/lib/elzoo/ai_batch/staging.ex:41-48`; `pieces/integration/ai-batch/test/elzoo/ai_batch_test.exs:153-159`.
   - `configure/1` accepts any two-arity `submissions` function and keeps it in `%Config{}`; that Config is passed as `adapter_context` to the EffectIntent owner. A caller can validly supply `fn _, _ -> {:ok, prompt_bytes} end`, whose environment retains the prompt in owner state. `Staging.lookup_fun/1` happens to capture only a PID, but the interface neither requires that form nor checks it; `Config`'s custom Inspect and the test's string search merely hide the unsafe function environment. The stated Contract says the owner state contains neither raw submission bytes nor a closure exposing them, so the generalized interface does not uphold its own redaction guarantee.
   - Concrete change: replace the arbitrary closure with a narrowly shaped opaque lookup capability (for example, a registered host process/reference and a module callback whose state is outside the EffectIntent context), or otherwise make safe non-capturing storage a constructor-enforced requirement. Inspect the actual owner context/closure environment in a negative test and prove a raw-capturing lookup is rejected; retain the safe `Staging` reference implementation as the normal host store.

3. **Medium — the public PR body links a non-provider hostname in a generator attribution.**
   - Location: PR #169 body, final line (`Generated with Claude Code` linking to `claude.com`).
   - The public-writing rule forbids domains in PR bodies unless they are needed as Contract/evidence references. This attribution supplies neither and matches the violation already identified in the ELZ-079 final review.
   - Concrete change: remove the attribution and any equivalent non-evidence external badge/link before requesting merge.

## What was checked and found sound

- The live task Contract is unchanged; its local publication copy and the release-plan body hash agree. The two catalogue rows, release-plan outputs, dependency/view updates, and generated ledger entries are present and internally consistent.
- The diff adds only the two admitted Pieces plus their task/evidence/catalogue artifacts; it does not change ready `integration/ai-text`, `integration/ai-model`, `integration/ai-text-anthropic`, or `delivery/effect-intent` sources. Completion checking is owned by `integration/ai-batch`, and its finite equality corpus includes the named response cases.
- The provider applies the selected item-body callback path, explicitly describes the undocumented `:json` observation and its fixed-corpus drift guard, constrains beta headers, uses the second cancel Binding, maps lost writes to unknown, and implements bounded scan/page/line behavior. The finite tests are placed in each Piece's own test tree and their source-audit layout supports both repository and exported-consumer paths.
- The documented bound checks, item-id joins, whole-page unknown/duplicate refusal, ended-only missing reporting, absent usage handling, fixture provenance, operational declarations, and R5 evidence wording are appropriately scoped by source inspection. Those are test/contract observations, not independently executed evidence in this review.

## Verdict

**request changes** — resolve the two Q4 staging/owner-state violations and remove the public attribution, then rerun the required worker/hosted checks and refresh the exact-head evidence before approval.

Counts: High 2, Medium 1, Low 0. Verdict: request changes.
