# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpServer.Handler do
  @moduledoc """
  The `ExMCP.Server.Handler` that `Elzoo.McpServer.Plug` gives `ExMCP.HttpPlug`.
  ex_mcp starts one handler process per request; its `init/1` receives the
  server and the request's verified principal, so every callback decides on
  the current request's principal only.
  """
  use ExMCP.Server.Handler

  alias Elzoo.McpServer

  @impl true
  def init({%McpServer{} = server, %Elzoo.Principal{} = principal}),
    do: {:ok, %{server: server, principal: principal}}

  @impl true
  def handle_initialize(params, state) do
    {:ok,
     %{
       protocolVersion: params["protocolVersion"],
       serverInfo: %{name: "elzoo-mcp-server", version: "1"},
       capabilities: %{tools: %{}}
     }, state}
  end

  @impl true
  def handle_list_tools(_cursor, state),
    do: {:ok, McpServer.list_tools(state.server, state.principal), nil, state}

  @impl true
  def handle_call_tool(name, arguments, state) do
    case McpServer.call_tool(state.server, state.principal, name, arguments) do
      {:ok, text} -> {:ok, %{content: [%{type: "text", text: text}]}, state}
      {:tool_error, text} -> {:ok, %{content: [%{type: "text", text: text}], isError: true}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end
end
