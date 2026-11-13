# SPDX-License-Identifier: Apache-2.0
# Construction only: no connection is opened and no host function is called.
# A host then connects the set (`Elzoo.McpMulti.connect(config, dynamic_supervisor)`),
# lists the tools of every server (`Elzoo.McpMulti.list_tools(set)`), takes the
# ready client values of one server (`Elzoo.McpMulti.session(set, "notes")`) for
# `Elzoo.McpClient.admission/3`, `context/2` and `call_tool/3`, and closes the
# set (`Elzoo.McpMulti.close(set)`).
defmodule Elzoo.McpMulti.ExampleNotes do
  use Elzoo.McpClient.Binding,
    id: "tools-notes",
    server: "notes",
    endpoint: "http://127.0.0.1:4101/mcp",
    network: :loopback,
    recovery_grace_ms: 60_000
end

defmodule Elzoo.McpMulti.ExampleTickets do
  use Elzoo.McpClient.Binding,
    id: "tools-tickets",
    server: "tickets",
    endpoint: "http://127.0.0.1:4102/mcp",
    network: :loopback,
    recovery_grace_ms: 60_000
end

{:ok, config} =
  Elzoo.McpMulti.configure(
    tenant: "tenant-a",
    # The host's trusted Elzoo.Secrets context for one server's request, with
    # fresh authority; called before each request, never here.
    secrets: fn request ->
      %{grant: request, resolver: fn _ref, _scope -> {:error, :missing} end}
    end,
    servers: [
      [
        binding: Elzoo.McpMulti.ExampleNotes,
        credential: %{ref: "notes-token", scope: "tenant-a/notes"}
      ],
      [
        binding: Elzoo.McpMulti.ExampleTickets,
        credential: %{ref: "tickets-token", scope: "tenant-a/tickets"},
        max_tools: 32
      ]
    ]
  )

"#Elzoo.McpMulti.Config<tenant: \"tenant-a\", bindings: " <>
  "[Elzoo.McpMulti.ExampleNotes, Elzoo.McpMulti.ExampleTickets]>" = inspect(config)

# The same server text twice is refused for the whole set.
{:error, :configuration} =
  Elzoo.McpMulti.configure(
    tenant: "tenant-a",
    secrets: fn _ -> raise "not called" end,
    servers: [
      [binding: Elzoo.McpMulti.ExampleNotes, credential: %{ref: "a", scope: "tenant-a/notes"}],
      [binding: Elzoo.McpMulti.ExampleNotes, credential: %{ref: "b", scope: "tenant-a/notes"}]
    ]
  )
