# SPDX-License-Identifier: Apache-2.0
# Construction and one refused admission: no Need of the host is called and no
# connection is opened. After `{:ok, client_config} = Elzoo.McpRuntime.admit(config)`,
# a host connects (`Elzoo.McpClient.connect(client_config, dynamic_supervisor)`),
# lists tools (`Elzoo.McpRuntime.list_tools(config, session)`), admits a call
# (`Elzoo.McpClient.admission(client_config, declaration, listing)`), starts
# Elzoo.EffectIntent with `adapter_context` from
# `Elzoo.McpClient.context(session, admission, self())` (the context bound to
# that admission; `context/2` is refused for a runtime session) and dispatches
# with `Elzoo.McpClient.call_tool(session, admission, owner)`.
policy = Elzoo.EgressPolicy.policy(hosts: ["mcp.example.test"], ports: [443])

{:ok, config} =
  Elzoo.McpRuntime.configure(
    tenant: "tenant-a",
    server: "notes",
    url: "http://mcp.example.test/mcp",
    policy: policy,
    # The host's resolver Need (see the integration/egress-policy recipe).
    resolver: fn _host -> raise "not called: the scheme is refused first" end,
    credential: %{ref: "notes-token", scope: "tenant-a/notes"},
    # The host's trusted Elzoo.Secrets context for the request, with fresh
    # authority; called at admit/1, list_tools/2 and each request.
    secrets: fn _request -> raise "not called: egress refuses first" end
  )

"#Elzoo.McpRuntime.Config<tenant: \"tenant-a\", server: \"notes\">" = inspect(config)

# Egress first: an http URL is refused with egress-policy's own reason.
{:error, {:egress, :scheme}} = Elzoo.McpRuntime.admit(config)

# A query is refused at construction.
{:error, :configuration} =
  Elzoo.McpRuntime.configure(
    tenant: "tenant-a",
    server: "notes",
    url: "https://mcp.example.test/mcp?tenant=b",
    policy: policy,
    resolver: fn _ -> {:error, :nxdomain} end,
    credential: %{ref: "notes-token", scope: "tenant-a/notes"},
    secrets: fn _ -> :none end
  )
