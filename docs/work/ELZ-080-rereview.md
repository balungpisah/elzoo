Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed range: `b1487c53f4764803311294c83f113c705df44257..d4e1b07bafc322ce6febc746c681092c787a9265` for `pieces/integration/ai-embedding`, `pieces/integration/ai-embedding-openai`, and `docs/work/ELZ-080.md`; ELZ-080 rows only from `origin/main...d4e1b07bafc322ce6febc746c681092c787a9265` for `registry/` and `docs/plans/release-plan.json`. Live Contracts read: issues #159 and #160, including amendment 1. This was a read-only Git/GitHub review: no Mix command and no provider call.

## Per-item results

1. **HTTP 529 — pass.** `OpenAI.classify_failure/1` maps 529 to `:overloaded` at `pieces/integration/ai-embedding-openai/lib/elzoo/ai_embedding/openai.ex:243`. E4 at `pieces/integration/ai-embedding-openai/test/elzoo/ai_embedding_openai_test.exs:330-385` checks the refused overloaded outcome, the `failed/dispatched/retryable` delivery triple, default-policy `:unresolved`, refusal of rearm and dispatch, and exactly one captured request. The README (`:112-121`), manifest contract and test-grounding claim (`piece.json:35,59`), and ELZ-080 release-plan row all say that 529 is overloaded by the family rule; the wording does not claim it is an OpenAI-documented status.

2. **Input texts as intent arguments — pass.** The new interface README statement at `pieces/integration/ai-embedding/README.md:40-44` is accurate and appropriately limited. On main, EffectIntent documents arguments as classified durable data whose access control is a host Need (`pieces/delivery/effect-intent/README.md:33-38`), stores the admitted argument bytes in the model (`lib/elzoo/effect_intent/model.ex:82-108`), and passes matching bytes to the adapter request (`lib/elzoo/effect_intent.ex:281-294`). It does not overstate finite tests as proof or claim durable result retention; the explicit volatile Memory double remains an acknowledged test-only option.

3. **`install_configuration` — pass.** `pieces/integration/ai-embedding-openai/piece.json:29-34` has exactly one declaration: `config :req_llm, load_dotenv: false`, with a one-line reason. Main's Registry accepts a literal one-call config line and requires its application to be a package of one of the Piece's declared providers (`lib/elzoo/registry.ex:253-324`); `req_llm` is declared by this Piece and its registered package is `req_llm`. The README correctly points to the manifest field and exporter (`README.md:41-70`), while retaining the two phrases asserted by E10 at `test/elzoo/ai_embedding_openai_test.exs:632-640`. The provider-neutral `integration/ai-embedding` does not declare or bring `req_llm` (its providers are Cure, Jason, Elixir, OTP at `piece.json:8-19`), so it needs no matching installation declaration.

4. **Scope and protected surfaces — pass.** The stipulated diffs modify only the two ELZ-080 Pieces, their work record, and the two ELZ-080 catalogue/release-plan rows; no other ready Piece or protected source is edited by this scoped review. Both scoped diffs are whitespace-clean. The registry and release-plan hashes point to the changed manifest, and their 529 wording agrees with it.

5. **Exact-head PR body and public writing — fail.** The PR body at head `d4e1b07bafc322ce6febc746c681092c787a9265` says ELZ-091 “will later add the install-configuration field” and lists that adoption as open work, but this head already uses that field in `pieces/integration/ai-embedding-openai/piece.json:29-34`. It also retains the generated Claude Code attribution and external Devin badge/links; these are not Contract or evidence references and violate the public-repository writing rule in `tasks/ELZ-067-coordination-rules.md:48-52`.

## New findings

1. **BLOCKING — stale and noncompliant exact-head PR body** (`PR #168 body: Dependencies, Open work, footer`). Update the dependency/open-work wording to describe the present `install_configuration` declaration and exact-head evidence, and remove the generated attribution plus Devin badge/external links before publishing or approving a public review/comment.

## Verdict

**Request changes.** The three post-final-review Piece changes are sound, but the PR body is not accurate at the exact head and does not meet the public-writing rule.
