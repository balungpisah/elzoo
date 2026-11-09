Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

# ELZ-083 narrow re-review 2

Reviewed range: `0263ee32da20dee499b83579f896e784c61ed573..e2163c6b68ae09c7d329bbcaaa939365446864f2`.

Review method: read-only inspection through Git and GitHub. I did not run Mix, alter the repository working tree, or write a GitHub comment. Live issue #155 was fetched; its reported raw-body SHA-256 matches `815078e3d19a66d353623746a3c920cb5f79eabac97b7d2daef0b7ad8828014e`. PR #163's `headRefOid` was `e2163c6b68ae09c7d329bbcaaa939365446864f2`, matching the reviewed head.

## Per-item results

1. **Settlement confirmation — pass.** `call_tool/3` returns `{:completed, _}` only after `Elzoo.EffectIntent.status/1` reports `{:Confirmed, _}`; otherwise its finite 250 x 20 ms polling path returns `{:unknown, :settlement_unconfirmed}`. The status probe has no cyclic dependency on the caller and its GenServer default timeout is finite, so this adds no deadlock or unbounded wait. `unknown{reason}` in the live Contract admits `settlement_unconfirmed` without changing the Contract. Adapter and README/piece metadata explicitly say the recipient message precedes, and is not, settlement; T3 asserts confirmed status after `call_tool/3` completes.

2. **Exact credential redaction — request changes.** The Adapter resolves candidate credential bytes before and after the call, redacts completed result content/structured content before both delivery and digest, redacts discovery output, has no logging or error-return path in `Redact`, and states the base64/split/escaped-encoding limit. However, the generic map-key rewrite introduces the P1 defect below, and T27 uses only the fixed `@token`; it does not prove rotation between the before and after resolutions as required.

3. **T13b GET stream — pass.** The loopback server now holds a GET SSE stream with `Process.sleep(:infinity)`, ending only when the client connection/process or server stops. This removes the three-second lifetime race and does not alter the POST fault paths used by the other tests.

4. **Invalid result mapping (T16b) — pass.** `Transport.classify/1` maps ex_mcp's invalid-MCP-result protocol error to `{:CallWire, :ReplyMalformed, nil}`; the existing Cure outcome table maps that sent-but-uncompleted state to `unknown{malformed_response}`. T16b includes `:no_result_type`, an ex_mcp-rejected invalid result, in addition to garbage and oversized replies. This is honest because delivery occurred but no valid completed result was observed.

5. **Metadata and scope hygiene — pass.** The release-plan manifest SHA is the SHA-256 of the reviewed `piece.json` (`58437ac3faae90b9fafa35b7f8cd114f06722bb3a6b97f20326d9c927bdafd4f`); `LEDGER.md` records the ready Piece and pin consistently. The added content has no `docs/` or `tasks/` literal (apart from diff file headers), and `git diff --check` reported no whitespace errors. The PR body identifies the exact reviewed head and describes the added behavior, subject to the findings below being fixed and its evidence wording updated.

## Findings

### P1 — redacting structural descriptor keys makes valid discoveries unusable

`Redact.walk/2` rewrites every map key. `Discovery.list/1` applies it to the already-canonical descriptor, whose adapter-owned keys include `"name"` and `"input_schema"`. `AuthProvider.token/1` accepts a legal bearer token such as `"name"`; with that token, discovery rewrites the descriptor's required `"name"` key to `"[redacted]"`. `Snapshot.check/3` then cannot find `tool["name"]`, so every otherwise valid admitted call is refused as `unknown_tool`. Keys can also collide after replacement and change result shape.

Affected reviewed lines: `redact.ex:25-26`, `discovery.ex:16`, `discovery.ex:82-88`, and `snapshot.ex:12-16`. Redact only server-controlled map keys/values before the adapter constructs its fixed descriptor shape, or otherwise preserve required adapter-owned structural keys while retaining the exact-byte non-leak guarantee. Add cases for credentials equal to `name`, `input_schema`, and `text`.

### P2 — T27 does not demonstrate credential rotation

T27 constructs its session with the default static `fn -> {:ok, @token} end` credential Need. It verifies an echo of that one token in result and structured-content keys, but cannot exercise the new before/after resolution behavior. Add an echo-server test whose Need returns the prior token for the pre-call redaction resolution and the sent/after token thereafter, then assert neither token reaches delivered data, digest/status, or discovery descriptors.

## Verdict

**Request changes.** Resolve P1 and add the rotation evidence in P2, then re-review the resulting narrow range. No other new defect was found in the requested range.
