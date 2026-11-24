# SPDX-License-Identifier: Apache-2.0
# The host's configuration and mount. The Needs are stand-ins: a real host
# verifies with its pinned issuer keys, lists its tenant's bots, and starts and
# reads Runs through its engine (state/recipe-store pin/4, workflow/version-pin,
# the Run owner and the engine's result/3).
alias Elzoo.{McpServer, TokenVerify}

issuer_key = JOSE.JWK.generate_key({:okp, :Ed25519})
{_, public_jwk} = JOSE.JWK.to_public_map(issuer_key)

verifier =
  TokenVerify.jwt_config(
    issuer: "https://issuer.example",
    audience: "elzoo-mcp",
    keys: [%{kid: "2026-11", alg: "EdDSA", jwk: public_jwk}],
    leeway_s: 30,
    subject: fn %{subject: id} ->
      {:ok,
       %{
         principal: %{kind: :human, id: id, tenant: "acme", allowed_scopes: [], allowed_spaces: []},
         current_epoch: 0
       }}
    end
  )

{:ok, server} =
  McpServer.new(
    verifier: {:jwt, verifier},
    clock: fn -> System.os_time(:second) end,
    policy: %{
      id: "mcp",
      version: 1,
      content_hash: :crypto.hash(:sha256, "mcp-1"),
      effect_classes: ["mcp.run"],
      rules: [
        %{
          id: "run-summarize",
          effect_class: "mcp.run",
          target: {:exact, "bot/bot-1"},
          verdict: :allow
        }
      ]
    },
    authority: fn _principal -> {:ok, [%{target: "bot/bot-1", field: "run", value: true}]} end,
    bots: fn "acme" ->
      {:ok,
       [
         %{
           bot_id: "bot-1",
           name: "summarize",
           description: "Summarize a text",
           start_schema: %{"type" => "object", "required" => ["text"]},
           schema_version: 1
         }
       ]}
    end,
    start: fn %{bot_id: "bot-1", call_id: _call_id} -> {:ok, "run-1"} end,
    result: fn %{run_id: "run-1"} -> {:ok, %{run_id: "run-1", payload: %{"summary" => "..."}}} end,
    call_timeout_ms: 30_000
  )

:persistent_term.put({:mcp_server_example, :server}, server)

defmodule ExampleHost.Mcp do
  def server, do: {:ok, :persistent_term.get({:mcp_server_example, :server})}
end

defmodule ExampleHost.Router do
  use Plug.Router
  plug(:match)
  plug(:dispatch)
  forward("/mcp", to: Elzoo.McpServer.Plug, init_opts: {ExampleHost.Mcp, :server, []})
end

# A request without a bearer token is refused before any MCP handling.
conn = Plug.Test.conn(:post, "/mcp", "{}") |> ExampleHost.Router.call(ExampleHost.Router.init([]))
401 = conn.status
["Bearer"] = Plug.Conn.get_resp_header(conn, "www-authenticate")
:ok
