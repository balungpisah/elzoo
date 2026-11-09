# SPDX-License-Identifier: Apache-2.0
# Construction and admission only: no connection is opened and no tool is called.
# A host then connects (`Elzoo.McpClient.connect(config, dynamic_supervisor)`),
# lists tools (`Elzoo.McpClient.list_tools(session)`), admits a call against
# that snapshot, starts Elzoo.EffectIntent with the admission parts and
# `adapter_context: Elzoo.McpClient.context(session, self())`, and dispatches
# with `Elzoo.McpClient.call_tool(session, admission, owner)`. The owner's first
# real MCP server is not named yet; the Piece's tests use an in-process loopback
# server.
defmodule Elzoo.McpClient.ExampleBinding do
  use Elzoo.McpClient.Binding,
    id: "tools-local",
    server: "local-tools",
    endpoint: "http://127.0.0.1:4100/mcp",
    network: :loopback,
    recovery_grace_ms: 60_000
end

{:ok, config} =
  Elzoo.McpClient.configure(
    binding: Elzoo.McpClient.ExampleBinding,
    tenant: "tenant-a",
    # The credential Need: the host's secret source, called before each request.
    credentials: fn -> {:error, :unavailable} end,
    protocol_mode: :modern_only
  )

# A discovery snapshot as list_tools/1 returns it: untrusted data.
snapshot = %{
  server: "local-tools",
  protocol_version: "2026-07-28",
  truncated: false,
  tools: [
    %{
      "trust" => "untrusted",
      "name" => "search_notes",
      "description" => "Search the notes",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      },
      "annotations" => %{"readOnlyHint" => true}
    }
  ]
}

payload =
  Jason.encode!(%{
    "version" => 1,
    "tool" => "search_notes",
    "arguments" => %{"query" => "release plan"},
    # The caller's exact-action release reference from its approval step.
    "release" => "approval:run-17/step-3"
  })

declaration = %{
  "capability_id" => "integration/mcp-client",
  "operation" => "tools/call",
  "classification" => "untrusted",
  "command" => %{
    "version" => 1,
    "message_id" => "message-1",
    "schema_id" => "elzoo/mcp-tool-call",
    "schema_version" => 1,
    "kind" => "command",
    "producer" => %{"unit_id" => "agent-step", "port_id" => "tools"},
    "idempotency_key" => "run-17/step-3/call-1",
    "deadline_unix_ms" => 1_900_000_000_000,
    "payload" => payload
  }
}

{:ok, admission} = Elzoo.McpClient.admission(config, declaration, snapshot)
true = byte_size(admission.key) == 64
true = admission.arguments == payload

missing =
  put_in(declaration, ["command", "payload"], String.replace(payload, "search_notes", "drop_all"))

{:error, {:refused, :unknown_tool}} = Elzoo.McpClient.admission(config, missing, snapshot)

{:ok, {:unknown, {:server_error, :invalid_arguments}}} =
  Elzoo.McpClient.outcome(:server_invalid_arguments)

{:ok, {:refused, :authentication_failed}} = Elzoo.McpClient.outcome(:authentication_failed)
false = inspect(config) =~ "credentials"
