# ELZ-382 — integration/mcp-client states and tests its bound of 64 distinct tokens per session

- Phase: repair of the ready Piece `integration/mcp-client` before the first release (defect #912)
- Dependencies: ELZ-083
- Release: V1B
- Output: none. A repair in place of the ready Piece `integration/mcp-client` (ELZ-083), with the same Piece ID (`AGENTS.md` section 4): the Contract states a bound that the code already enforces, and a test grounds it. Behaviour does not change.
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: the Piece directory, its index row and generated files)
- Owned paths: `pieces/integration/mcp-client/**`; the `manifest_sha256` and `note` of its `entries` row in `docs/plans/release-plan.json` and the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` (`AGENTS.md` section 3). No other Piece (`integration/mcp-runtime` included), no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Defect and boundary

Reported in #912. This publication does not settle #912; the build pull request does.

The session ledger of `integration/mcp-client` records each distinct token that its auth provider hands to `ex_mcp`, and holds at most 64 (`lib/elzoo/mcp_client/ledger.ex`, `@max 64` and `handle_call({:record, token}, ...)`). A 65th distinct token cannot be recorded, so `get_token/1` (`lib/elzoo/mcp_client/auth_provider.ex`) refuses it and the request is `refused{credentials_unavailable}` before any byte, as the README's rule "a token that cannot be recorded is not sent" requires. Slots are never freed during a session, so that redaction covers every token sent.

The bound is a code comment only. The README and `piece.json` of `integration/mcp-client` do not state it, and no test exercises it. A host whose credential Need rotates (since ELZ-370, an `integration/oauth-client` connection behind `integration/mcp-runtime` can give a new token per request) sees a session fail after 64 distinct tokens with the same refusal as a failing Need. `integration/mcp-runtime`'s README states the bound as "carried and not tested here". So the Contract of the Piece that owns the behaviour is missing a rule that its callers rely on, with no evidence for it.

This task states the bound in this Piece's Contract and grounds it with a test. It does not change the bound, the refusal or the redaction, and it adds no signal and no eviction: a rollover signal, a distinct refusal reason or an eviction that keeps the redaction guarantee stay open ("Kept open").

## Facts on `main` that this task builds on

Checked at `a9b1badb`; confirm each before you start, and comment on the issue if one differs.

- `Ledger.record/2` answers `:ok` for a token it holds, inserts a new token while it holds fewer than 64, and answers `:error` otherwise. The ledger is started per session by `connect/2` and stops with the session's client.
- `AuthProvider.get_token/1` calls the credential Need, applies the credential rule (24..4,096-byte b64token, not a substring of a fixed or configured string) and records the token; any failure is `{:error, :credentials_unavailable}`. The tokens that the bookend resolutions around a call or a listing read are used for redaction only and are not recorded.
- The README's "Credential rule and redaction" paragraph and its Outcomes table (`refused{credentials_unavailable}`, `timed_out` / `not_dispatched` / `unavailable`, attested no-send) describe the refusal; test T19 covers a failing credential Need, and T28, T30 and T31 cover rotation within the bound.

## The change

- The README's "Credential rule and redaction" paragraph states: one session's ledger holds at most 64 distinct tokens; a request whose token would be the 65th distinct one is refused before any byte, as `refused{credentials_unavailable}` at a call and `{:error, :credentials_unavailable}` at a listing (`connect/2` starts the session with an empty ledger, so it never meets the bound); a token the ledger already holds is still sent; a new session (`connect/2`) has an empty ledger; so a host whose credential Need gives a new token for each request reconnects within 64 requests. The "Limits" section repeats it in one sentence, and the "Needs" section names the host duty to reconnect.
- `piece.json` states the bound in `contract` and `limits` and grounds it with the new test; the `note` and `manifest_sha256` of the index row follow `piece.json`.
- No change to `lib/`.

## Acceptance

A new test in `test/elzoo/mcp_client_test.exs`, against the Piece's loopback server, with a credential Need that gives a new valid token (24 bytes or more, b64token) on each call and records which token each HTTP request carried:

1. **The bound.** After `connect/2`, the test makes requests (tool calls or listing pages) until the session has sent 64 distinct tokens; the request that would carry the 65th distinct token is `refused{credentials_unavailable}` (or `{:error, :credentials_unavailable}` for a listing), and the loopback server receives no request for it. The count includes the handshake's tokens, which the test reads from the server's record, not from an assumed number of handshake requests.
2. **A held token still goes.** On the same session, the credential Need then gives one of the 64 tokens already sent: the next request is sent and completes.
3. **A new session.** A second `connect/2` with the same rotating Need connects and completes a call.

Every existing test of the Piece passes unchanged.

Negative control, a temporary edit of `lib/` that is reverted and never committed: raise `@max` to 65, and case 1 fails (the 65th token is sent). Record the failure in the pull request.

## Gate, review and build

Run `mix test pieces/integration/mcp-client/test`, then the small gate `mix check --piece "$(git merge-base origin/main HEAD)"`, which runs the tests of the ready Pieces that depend on `integration/mcp-client` (`integration/mcp-runtime`, `integration/mcp-server` among them), and `git diff --check`. The Piece carries credentials and untrusted server input, so it keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"); the hosted `check-piece` run on the exact head and the merge queue follow.

## Kept open

A host-visible signal before the bound (a reason distinct from a failing Need, or a count of slots left), and eviction of tokens that keeps the redaction guarantee; each is addable in place before the first release.

## Limits to state

- `integration/mcp-runtime`'s README keeps its sentence that the bound is mcp-client's and carried, with a pointer to #912; that sentence stays true and is not changed here (one Piece directory per task).
- Finite listed scenarios, not a proof.
