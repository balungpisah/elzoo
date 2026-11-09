Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

# ELZ-083 narrow re-review 3

Reviewed range: `e2163c6b68ae09c7d329bbcaaa939365446864f2..87e1dc875df79aa617ea8ce2fc207df6037dd07d`.

Review method: read-only inspection through Git and GitHub; Mix was not run, the repository working tree was not altered, and no GitHub comment was written. PR #163 currently names head `87e1dc875df79aa617ea8ce2fc207df6037dd07d`, exactly the reviewed head. The live #155 raw body has SHA-256 `815078e3d19a66d353623746a3c920cb5f79eabac97b7d2daef0b7ad8828014e` and retains the unconditional invariant: “the credential never appears in a result, error, inspect value, Adapter log or event”.

## Per-item results

1. **P1 structural-key regression — request changes.** The implementation fixes the prior usability defect: discovery now bounds raw server tools, resolves candidate secrets before and after listing, redacts raw server data, then constructs the fixed descriptor. Thus `trust`, `name`, `input_schema`, and the other Adapter-owned descriptor keys are not rewritten; T29 covers `name`, `input_schema`, and `text` and establishes usable discovery and calls for those values. However, the recorded vocabulary-key exception is an exception to the live Contract, not merely a harmless representational detail: with credential `text`, the delivered content item still has key `"text"`; with `name` or `input_schema`, the descriptor has those exact keys. Each is an occurrence of the credential in a result/inspect value. The stated rationale that the word was already protocol vocabulary does not satisfy an invariant framed as “never appears”.

   Minimal honest fix: keep construction after raw-data redaction, but reject a credential at binding/use time whenever its exact bytes occur in a preserved output-shape key. The reserved set must include both MCP/JSON-Schema vocabulary and Adapter/result/inspect structural literals (at least `trust`, `name`, `description`, `input_schema`, `annotations`, `content`, `is_error`, and `structured`), not only the raw-server vocabulary; T29 should then assert the defined refusal/no-send behavior rather than usability. A broader alternative is a deliberate live-Contract amendment explicitly making this exception, but that changes the security acceptance and is not recommended where the stated invariant is retained.

   The collision statement is otherwise accurate in its stated domain: when two non-exempt server keys both redact to `[redacted]`, `Map.new/1` retains one already-redacted value, so this is data loss rather than a credential disclosure. It does not cure the exempt-key Contract breach.

2. **P2 rotation evidence — evidence passes, Contract limit requires changes.** T28 genuinely exercises one rotation: the Adapter's pre-call resolution receives `old`, ex_mcp's provider and the post-call resolution receive `sent`, and the loopback server echoes both. The test checks both tokens are absent from delivered value and owner status, and repeats the check for a discovery descriptor including a schema key, description, and annotation. This resolves the prior missing one-rotation evidence.

   The newly recorded “token rotated twice within one call” limit is nevertheless inconsistent with the same unconditional live Contract. If the provider uses a token different from both bookend resolutions, an echoed result can contain a token not included in `Redact.value/2`'s secret list. The analogous gap also applies to a multi-page `tools/list`: every page invokes the provider, while discovery redacts only values resolved before and after the whole listing. A post-call/list resolution failure produces the same unobserved provider-token class. To retain the Contract, capture the exact token actually issued by the auth provider for every request and use that set for redaction (including every listing page), or restrict/validate the Need so that its token cannot rotate during an operation; otherwise amend the live Contract and acceptance deliberately. T28 is finite evidence for the named one-rotation case, not proof for the omitted schedules.

3. **Metadata, ledger, and PR body — pass.** The reviewed `piece.json` SHA-256 is `2fa2e272636bb99ac8742caee7849bc4d2b709f456cdf014b307073165dff3e7`, matching the ELZ-083 `manifest_sha256` in `docs/plans/release-plan.json`. `LEDGER.md` records the same ready `integration/mcp-client` provider set and Contract summary. The PR body identifies the exact reviewed head and candidly records both exceptions, but its claim that T29 is credential-redaction grounding conflicts with the live invariant for the reasons above.

4. **Scope hygiene — pass.** Only the requested fix range was reviewed; `git diff --check` reports no whitespace error. No additional unrelated defect was identified within that range beyond the Contract-incompatible exceptions above.

## Findings

### P1 — preserved vocabulary and Adapter keys disclose legal credential values

Severity: P1. `Redact.key/2` preserves vocabulary keys, and descriptor/result shapes necessarily preserve Adapter keys. Legal bearer tokens such as `text`, `name`, and `input_schema` therefore appear verbatim in returned/inspectable terms, despite the live unconditional credential invariant. Reject structural collisions or amend the Contract; documenting the exception alone is not sufficient.

### P1 — unobserved provider token can leak on two rotations and multi-page listing

Severity: P1. The before/after sampling does not necessarily include the token actually supplied by `AuthProvider.get_token/1`; an echoed in-between token is left unredacted. T28 covers exactly one favorable rotation and one-page discovery, but neither two rotations within a call nor per-page rotations/failure after request completion. Capture every issued token for redaction, enforce operation stability, or amend the Contract.

## Verdict

**Request changes.** P1 usability is repaired and P2's requested finite rotation evidence is now present, but the new stated limits make the PR contradict live #155's unconditional credential-nonappearance Contract. No other new defect was found in the reviewed range.
