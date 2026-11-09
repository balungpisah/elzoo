# ELZ-079 narrow re-review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed range: first-parent commits after `2ce0684833acc68234cebd7a3ca3b48bbde2292f` through `d8d790eb0a0e7a3721fa43d3320ccdb1858190d2`: `40b65729`, `694950c9`, merge `0b607f95` (shared-file resolution only), and `d8d790eb`.

Method: Git-object inspection only (`git show` and named-SHA diffs), plus read-only GitHub issue/PR metadata. I did not read repository working-tree files, run Mix, call a provider, or write to GitHub.

## Findings from the final review

### F1 — not resolved (blocking)

The amendment-2 publication is correctly applied: the live issue body and `tasks/ELZ-079-ai-model-text-anthropic.md` are byte-identical and both SHA-256 to `46baa04113ffd8a7aa6b7fd5a4a967953b618f37c1fc066e482a6bc281ed19e4`; the recorded comment is the stipulated amendment decision. The interface audit derives its full file list from exactly one own `piece.json` in repository or exported layout and fails for neither/both layouts: `pieces/integration/ai-text/test/elzoo/ai_text_test.exs:586-603`.

However, the required no-provider-dependency audit is incomplete for `Plug`: its forbidden value is `"Pl" <> "ug."`, not `"Pl" <> "ug"`, at `pieces/integration/ai-text/test/elzoo/ai_text_test.exs:612`. It therefore detects qualified `Plug.` uses but can pass with a bare `Plug` reference such as `alias Plug` or `use Plug`; the explicit condition is no `Plug` reference. The audit does cover `ReqLLM`, `req_llm`, `llm_db`, `Req.Test`, and `AiText.Anthropic` at `:610-616`, but it must be strengthened before this finding can be called resolved.

### F2 — resolved

The Anthropic README has the required Install configuration section and exact line at `pieces/integration/ai-text-anthropic/README.md:47-63`. It expressly states that the copier merges no configuration, the copied-consumer harness does not prove consumer configuration, and the credential invariant still holds. The Piece test uses the two repository/exported paths, requires exactly one readable README, delimits the named section, and checks the exact line and limit statements at `pieces/integration/ai-text-anthropic/test/elzoo/ai_text_anthropic_test.exs:592-609`; it cannot pass when neither or both paths exist or when the section/line is absent. The manifest records the same bounded claim at `pieces/integration/ai-text-anthropic/piece.json:30-36`; no exporter, consumer helper, or selection-check change appears in the reviewed range.

### F3 — resolved

PR #164 currently names the exact reviewed head at body line 5, and its final-review disposition says the body is at that head at line 41. It accurately records that the class-X local full check was not yet run and that the named hosted run was in progress (body lines 20-24); this re-review makes no claim that either check passed.

### F4 — resolved

The attribution line remains in the public PR body at line 53, consistent with decision record #119; the final disposition records that decision at body line 42.

## Merge and generated-artifact checks

`git show 0b607f95 --cc` and `git diff 480a9bf2 d8d790eb --` over the stipulated shared files show a union resolution: the final catalogue retains all three ELZ-079 ready rows and ELZ-081 `integration/text-chunking`; providers retain `text_chunker` plus all ELZ-079 providers; and release-plan retains both ELZ-079 and ELZ-081 jobs and their outputs. `mix.exs` retains both dependency additions. Relative to `480a9bf2`, `mix.lock` has exactly 12 added ELZ-079 entries and no removed/changed existing entry; the `Req 0.7.5` and `Finch 0.24.0` entries are byte-identical.

`LEDGER.md` identifies `mix elzoo.ledger` as its generator, while the roadmap views identify `python3 scripts/check-roadmap.py --write`; the merge commit and final hashes are consistent with regenerated artifacts, not a hand-selected conflict side. Final release-plan manifest hashes match the Git-object SHA-256 for ai-text, ai-text-anthropic, and text-chunking.

No new `docs/` or `tasks/` literal was introduced in executable Piece source in the reviewed range. `git diff --check` over the range is clean.

## New finding

1. **blocking — the F1 source audit does not cover a bare `Plug` reference.**

   Location: `pieces/integration/ai-text/test/elzoo/ai_text_test.exs:612`.

   Replace the `Plug.` search with a search for `Plug` (while retaining the self-audit-safe string construction), then refresh the exact-head PR body/check evidence as appropriate. This is evidence incompleteness, not a claim that the present listed interface files contain `Plug`.

## Verdict

**request changes** — strengthen the interface audit to forbid all `Plug` references, then re-review the exact resulting head. All other re-review conditions checked here are resolved or preserved as stated above.
