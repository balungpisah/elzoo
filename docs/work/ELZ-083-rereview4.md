Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

# ELZ-083 narrow re-review 4

Reviewed range: `87e1dc875df79aa617ea8ce2fc207df6037dd07d..c08d65c9177ff6aec20ab4e0659e571f5b1bfffe`.

Review method: read-only inspection through Git and GitHub. Mix was not run, the repository working tree was not altered, and no GitHub comment was written. PR #163 is open at exactly `c08d65c9177ff6aec20ab4e0659e571f5b1bfffe`. Live #155 retains the specified raw-body SHA-256 `815078e3d19a66d353623746a3c920cb5f79eabac97b7d2daef0b7ad8828014e` and its unconditional invariant: “the credential never appears in a result, error, inspect value, Adapter log or event”.

## Per-item status

1. **P1 preserved-word refusal — request changes.** `AuthProvider.token/1` now rejects a token overlapping words in `Redact.preserved/0`, before `get_token/1` can hand it to ex_mcp; T29 exercises connect-time and call-time refusal/no-send. This resolves the prior vocabulary-key exception for the listed vocabulary and fixed literals, but the preserved set is not complete for every reachable result, error, or inspect value.

   In particular, valid bearer token `mcp` is accepted because it is absent from `Redact.preserved/0`, yet `Adapter.failure/1` returns `{:error, tag, :mcp}`. The other finite error atoms in `Binding` are likewise not structurally closed under the stated byte-substring rule. More directly, discovery returns `server: c.settings.server` and `protocol_version: version(client)` without applying `Redact.value/2`; a credential equal to the configured server identity (the checked-in test helper's default is `elzoo-test-server`) or echoed as the negotiated version reaches the returned discovery value. Config/Session/Context inspection also prints an arbitrary binding module, whose module name is not in the finite set. T29 does not cover any of these paths. The Contract can only remain unconditional if every fixed/dynamic returned or inspected word is considered at token validation, or those outputs are redacted/omitted without destroying the promised shape.

2. **P1 per-send rotation capture — pass for the original finding.** The provider calls `Ledger.record/2` before returning a token; `Agent.get_and_update/3` makes the distinct-token bound atomic, refuses the 65th distinct token before return, and `Redact.secrets/3` combines the ledger snapshot with bookend resolutions. `Adapter.send_effect/1` uses it after every tools/call, and `Discovery.list/1` uses it after the complete paginated listing. T30's two rotations plus failed post-call resolution and T31's three sent pages substantively cover the prior unobserved-token cases. Concurrent calls share the serialized bounded ledger, so a completed operation's redaction includes all tokens recorded through its final snapshot; the structure is bounded at 64.

3. **P1 ledger confidentiality and lifecycle — request changes.** The ledger does retain raw tokens and is publicly recoverable: `connect/2` returns a `%Session{ledger: pid}`, and `Elzoo.McpClient.Ledger.tokens(session.ledger)` returns the raw list via `Agent.get/2`. This directly conflicts with the requested condition that the ledger not return tokens, independently of ordinary `inspect/1`; it also lets caller code turn the token into a result or log. Keep token handling inside a non-exported redaction operation (or return only redacted data), and add a negative test. Separately, `Ledger.link/2` is an asynchronous cast that links the Agent to the client, but an Erlang link does not terminate the Agent when the client exits with reason `:normal`; only `close/1` explicitly stops it. Thus a normal direct client stop can leave a bounded token-bearing Agent behind, so the stated general client-tied lifecycle is not established.

4. **Metadata, limits, and PR body — pass with the findings above.** The head manifest hashes to `9a232a7ba13b5302d759297c72379e2bda0cfd41b438ff9edcc06499f0eae2d6`, matching the ELZ-083 release-plan pin, and `LEDGER.md` agrees on the ready Piece/provider summary. README, `piece.json`, work record, and the PR body at the exact head remove the former two-rotation and multi-page limitation and state the ledger approach. `git diff --check` reports no whitespace errors.

## Findings

### P1 — structural reservation remains incomplete and leaks valid credentials

Severity: P1. `Redact.preserved/0` does not cover fixed error text (`:mcp` is a concrete example), the configured discovery server identity, negotiated protocol version, or arbitrary binding-module text printed by custom inspection. A valid accepted credential can therefore appear unchanged in an error, discovery result, or inspect value, contrary to live #155.

### P1 — session-exposed ledger returns raw credentials

Severity: P1. `Ledger.tokens/1` returns raw token bytes to any holder of the `ledger` PID exposed in the public `%Session{}`. This violates the requested ledger non-exposure property and makes otherwise redacted tokens available for output or logging.

### P2 — normal client exit does not establish ledger cleanup

Severity: P2. The Agent-to-client link survives a normal client exit; outside `close/1`, raw tokens can remain in the bounded Agent. Lifecycle cleanup needs a monitor/owner or another mechanism that also handles normal termination.

## Verdict

**Request changes.** The actual-token ledger fixes the two rotations/multi-page provider-token gap and the former listed structural collisions are refused before sending, but the preserved-output closure is incomplete and the ledger itself exposes raw credentials. No other defect was identified in the requested range.
