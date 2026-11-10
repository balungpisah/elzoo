# ELZ-091 final independent review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `f39a5cc1767f81c74d54b82844335a3a7729a5a5` (PR #166 head; issue #165)

## Inputs

- `git fetch origin --prune`; `git diff --stat origin/main...f39a5cc1767f81c74d54b82844335a3a7729a5a5`; full named-SHA diff; `git diff --check`; and named-SHA reads of the exporter, registry, selection, consumer helper, tests, fixtures, manifests, plans, and work records.
- PR #166 body and current check state; live issue #165 body and owner amendment comment `issuecomment-6750856885`; `tasks/ELZ-091-ai-text-consumer-install-configuration.md`; `docs/work/ELZ-091.md`, `ELZ-091-early-review.md`, and amendment records.
- This was a read-only review. I did not run Mix, modify the repository, alter Git state, or post on GitHub.

## Findings

1. **should-fix — remove non-provider generator/reviewer links from the public PR body.**

   Location: PR #166 body:51, 53-58.

   The public body contains a Claude Code attribution linked to `claude.com` and a Devin review badge with links and image resources on `app.devin.ai` and `static.devin.ai`. These are non-provider public-writing additions, contribute no Contract or evidence, and violate the public-repository writing rule.

   Concrete change: delete the attribution and the entire Devin badge block from the PR body before merge; do not replace them with equivalent external badges or links.

2. **should-fix — the PR body does not yet carry the required completed database-consumer and exact-head evidence.**

   Location: PR #166 body:27-32, 38-39, 47-49.

   At review time, the body records only database-free tests and says the database runs, `mix check --affected origin/main`, hosted run, and `ELZOO TIMING consumer=integration/ai-text total` are pending. The PR's `check-root`, `check-consumers`, and `check-consumers-db` jobs were still in progress; only `check-plan` and `gleam-hosted` had passed. This does not meet the issue's required final evidence, including the measured added `check-consumers-db` time locally and hosted.

   Concrete change: after the database run and all exact-head hosted jobs complete successfully, update the PR body and work record with the commands, exit codes, local and hosted `integration/ai-text` timing, and hosted run/job URLs or identifiers. State the evidence as tests/monitoring, not a proof; retain the stated limits.

## What was checked and found sound

- Scope is confined to the authorized selection/export/registry, ai-text Anthropic metadata and README, consuming documentation, exactly three owner-approved literal edits, tests/fixtures, task/plan records, and generated plan views. No `.github`, `scripts`, `mix.exs`, `mix.lock`, or `config/` path changed. The protected-test diff is exactly `test/export_test.exs:184` (`26` to `27`), `test/export_test.exs:230` (`- 25` to `- 26`), and `test/check_selection_test.exs:20` (`25` to `26`), with no other edits in those files.
- `install_configuration` validates a non-empty exact `{line, reason}` list. `Registry.configuration_settings/1` parses with `Code.string_to_quoted/1` without evaluation and accepts only a single literal-only `config/2` call; malformed expressions, interpolation, repeated keys, and non-direct-provider applications have named refusal coverage. Selection order is deterministic, exact duplicate text retains the first declaration, and conflicting values for one app/key raise before preflight/write while naming both Pieces and values.
- The frozen `runtime/unit` and `integration/cure-json` fixtures are static base-export bytes and are compared directly. For selections with no field the conditional section is empty; receipts retain their prior shape and source hashes are calculated before only the install instruction is added.
- The `integration/ai-text` consumer is in both selection inventories and the PostgreSQL list. The plan assertion rejects `integration/ai-text-*` providers and `req_llm`/`plug`; test, compiler-free runtime, and consumer-ebin checks reject provider modules/behaviour. The configuration probe is a fresh copied-consumer `mix run --no-start --no-compile` VM after the aggregate test VM, checks application non-started state and `load_dotenv == false`, and asserts the marker.
- The task publication copy and amendment body have the approved SHA-256 `0dcc58cd2e2656c024b6bdcd48068ae500a5dd30bf2a5401c6e4419f44c83bc9` (no added trailing newline); the release-plan pin matches. `LEDGER.md` is unchanged because its generated row has no install-configuration column; release-plan, dependency, and roadmap views carry ELZ-091. No trailing whitespace was found.

## Grounding and limits

- **Proof:** none claimed.
- **Type/contract check:** static review of the registry parser/validator and its named finite refusal tests.
- **Test:** static review of the frozen-byte, exporter, selection, provider-exclusion, and fresh-VM test paths. Their database and full exact-head execution remains pending at this review point.
- **Monitored behavior:** no final `consumers-db` measurement is available yet; finding 2 requires recording it.
- **Upstream contract:** relies on Mix configuration load ordering and `Code.string_to_quoted/1` parsing without evaluation; neither is locally proved here.

## Public-writing rule

Not satisfied at the reviewed PR body because of finding 1. This read-only reviewer did not post a PR comment; the coordinator must ensure the corrected public body/comment contains no credentials, session identifiers, private filesystem paths, or unnecessary non-provider external links/badges.

Severity counts: blocker 0; should-fix 2; note 0.

## Verdict

**approve after fixes** — the reviewed code and records are sound, contingent on removal of the public-writing material and completion/recording of exact-head database and hosted evidence.
