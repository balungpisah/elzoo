Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

# ELZ-083 narrow re-review 5

Reviewed range: `c08d65c9177ff6aec20ab4e0659e571f5b1bfffe..6d53b672526095ce0e3a781ca2bf6b4dddb3c1d9`.

Review method: read-only inspection through Git and GitHub. Mix was not run, the repository working tree was not read or altered, and no GitHub comment was written.

## Per-item status

1. **P1a — credential admission and discovery: pass.** `Credential.acceptable?/2` enforces the 24-byte minimum and rejects a token contained in `fixed/0` or the configured binding strings before `AuthProvider.get_token/1` can return it to ex_mcp. T29 covers refusal during both connection and a later call with no authenticated request; `Discovery.list/1` now submits both raw descriptors and the negotiated protocol version to in-ledger redaction. T32 uses the application's exported module list and BEAM `:debug_info` definitions rather than a source-path layout, and rejects a literal present in that enumeration but absent from `fixed/0`.

2. **P1b — ledger API and normal-exit lifecycle: request changes.** Replacing the Agent read API with `record/2` and `redact/3`, and monitoring the client, fixes the two defects identified in re-review 4: there is no exported `tokens/1`, and a client `:normal` exit sends the monitor DOWN that stops the ledger. `format_status/1` redacts `:sys.get_status/1`, so the checked T33 observations pass by construction. However, the public session still exposes the ledger PID and standard `:sys.get_state(session.ledger)` on this GenServer returns `%{tokens: [raw_token, ...], client: ...}`; `format_status/1` does not affect `:sys.get_state/1`. Thus `inspect(:sys.get_state(session.ledger))` contains a credential after a request, directly contradicting the live invariant's “inspect value” wording and the README's claim that the private ledger never returns a token. T33 tests only `:sys.get_status/1`, so it does not prove the stated non-exposure property.

   Required correction: keep raw tokens out of the GenServer state retrievable by `:sys.get_state/1` (or otherwise make the supplied ledger handle incapable of that disclosure), and extend T33 with the concrete post-listing `:sys.get_state/1` non-disclosure check. This is an approved-rule implementation defect, so it is the sole request-changes finding rather than another review-loop request.

3. **P2 — compiled-literal evidence: record as limit.** T32 silently treats a module with unavailable or non-Elixir `:debug_info` as contributing no literals (`else _ -> acc`). It therefore establishes coverage for the debug-info-bearing BEAMs in the named test run, not a failure on missing debug information itself. Exact wording to add to README and the work record: “Evidence limit: T32 enumerates literals only from Piece BEAM modules that expose Elixir debug_info; a module whose debug_info is unavailable contributes no literals, so this is finite test evidence for the compiled test layout, not a guarantee for stripped artifacts.” This does not create a new code-change request under the coordinator's last-round rule.

4. **Main extra point — pass.** No ex_mcp, Req, or Finch diagnostic text is returned in an Adapter result, error, or event. `Transport` only inspects external terms to select finite stages/reasons; `Discovery.reason/1`, connection classification, and Adapter failures return fixed atoms/tags; and the changed `call_tool/3` collapses every owner refusal to `{:error, {:intent, :refused}}`. Req and Finch are not directly called by this Piece. The remaining intentional data pass-through is server-supplied MCP tool `content`, `structuredContent`, descriptors, and negotiated protocol version; those are result data by Contract and pass through the ledger's exact-byte redaction, not library diagnostic text. The Adapter emits no events or logs; upstream ex_mcp telemetry/logs remain a documented upstream/consumer limit.

5. **Contract, metadata, and PR head: pass.** GitHub's raw JSON `.body` for live #155 hashes to `fe924c0669a0625cebdce443a16b435251371a1f35aa004f971088976631dc7f` and is byte-equal to `tasks/ELZ-083-mcp-client.md` at the reviewed head. `docs/plans/release-plan.json` pins that same SHA and records the third amendment. PR #163 is open at exactly `6d53b672526095ce0e3a781ca2bf6b4dddb3c1d9`; its body describes that exact head and its bounded library-error claim. `git diff --check` is clean.

## Findings

### P1 — raw credentials remain readable through standard GenServer state introspection

Classification: request changes — defect in the approved credential-invariant implementation.

`Ledger` stores raw tokens in its GenServer state and exposes the PID in `%Session{ledger: pid}`. Any same-node holder can call `:sys.get_state(pid)` and then inspect or return the token; redacting only `format_status/1` does not close this path. This violates the approved “credential never appears in an inspect value” rule and the claimed private-ledger boundary.

### P2 — T32 depends on debug-info availability

Classification: record as limit.

Use the exact README/work-record wording in per-item status 3. This is a finite-evidence boundary, not a newly requested review round.

## Verdict

**Request changes.** The credential admission rule, in-ledger redaction including protocol version, normal-exit monitor cleanup, and bounded library-error reduction implement the approved changes; the raw-token `:sys.get_state/1` exposure must be corrected before the unconditional credential invariant can be accepted.
