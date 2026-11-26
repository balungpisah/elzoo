# ELZ-414 — integration/mcp-server: isolate the oversized refusal from the valid bearer controls

- Dependencies: ELZ-411

## Outcome and scope

In #984, hosted run 45629478297 attempt 1 failed in `raw/5` while initializing a session for the valid bearer-prefix controls. The same head passed on attempt 2. The preceding request sends a 2,000,000-byte body without a token. The Plug correctly returns HTTP 401 without reading it. Cowboy may then close the connection if more than its 1,000,000-byte skip limit remains unread. Under CPU load the unchanged test reproduced the same `Req.TransportError: socket closed` after 11 passes. No authorization mismatch was observed.

Do not reuse the oversized refusal's connection for the next request. Keep the test on real HTTP, with retries disabled, and make its existing handler and HTTP call counters usable in a focused run without relying on earlier tests to load those modules. Keep every refusal, status, header, body, Need, handler-count and valid-prefix assertion.

This is a coordinator-owned test-only Piece repair on the one-PR path (`AGENTS.md` section 1), release V2, stage `later`. Only the already-listed `test/elzoo/mcp_server_test.exs` of `integration/mcp-server` changes in the Piece. Outside it: this task, the job row in `docs/plans/release-plan.json` and its generated plan views. No output Piece ID or change to the Contract, library, manifest, catalogue or Piece index row.

## Acceptance

- Record the targeted repeat count and transport failure before repair. Repeat the repaired case under the same CPU load with both valid prefixes and all refusal assertions intact.
- Negative control: temporarily restore connection reuse on the oversized POST and reproduce the socket failure in the valid controls; restore the repair before the gate. Never commit the control.
- `mix test pieces/integration/mcp-server/test`, `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` exit 0. Require full independent review for authentication and the exact-head hosted Piece check.
