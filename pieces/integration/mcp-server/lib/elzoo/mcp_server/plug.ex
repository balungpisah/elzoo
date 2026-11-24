# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpServer.Plug do
  @moduledoc """
  The Plug that the host forwards to:

      forward "/mcp", to: Elzoo.McpServer.Plug, init_opts: {MyApp.Mcp, :server, []}

  Each request applies the init triple, which must return `{:ok, server}` from
  `Elzoo.McpServer.new/1` (else HTTP 503). The bearer token is verified before
  the body is read and before any MCP handling (else HTTP 401). A request with
  an `mcp-method` header of `subscriptions/listen` is then refused with the
  JSON-RPC error -32601, its body unread; every other request goes to
  `ExMCP.HttpPlug`, with `Elzoo.McpServer.Handler` and each session bound to
  the verified principal's tenant and identity.
  """
  @behaviour Plug
  import Plug.Conn

  alias Elzoo.McpServer

  @unauthorized ~s({"error":"unauthorized"})
  @unavailable ~s({"error":"unavailable"})
  @no_listen ~s({"jsonrpc":"2.0","id":null,"error":{"code":-32601,"message":"Method not found"}})
  @max_token 8_192

  @impl true
  def init({module, function, args} = mfa)
      when is_atom(module) and is_atom(function) and is_list(args),
      do: mfa

  @impl true
  def call(conn, {module, function, args}) do
    case server(module, function, args) do
      {:ok, server} -> authenticate(conn, server)
      :error -> conn |> reply(503, @unavailable) |> halt()
    end
  end

  defp server(module, function, args) do
    case apply(module, function, args) do
      {:ok, %McpServer{} = server} -> {:ok, server}
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  defp authenticate(conn, server) do
    with {:ok, token} <- bearer(get_req_header(conn, "authorization")),
         {:ok, principal} <- McpServer.verify(server, token) do
      conn |> assign(:elzoo_mcp_principal, principal) |> mcp(server)
    else
      _ ->
        conn |> put_resp_header("www-authenticate", "Bearer") |> reply(401, @unauthorized) |> halt()
    end
  end

  # The Piece serves no subscription. ex_mcp opens a listen stream only for a
  # modern-era request, whose one Mcp-Method header must equal the body's
  # method, so the header alone decides; the body is not read (id null).
  defp mcp(conn, server) do
    if "subscriptions/listen" in get_req_header(conn, "mcp-method") do
      conn |> reply(200, @no_listen) |> halt()
    else
      ExMCP.HttpPlug.call(conn, ExMCP.HttpPlug.init(http_opts(server)))
    end
  end

  defp http_opts(server) do
    [
      handler: Elzoo.McpServer.Handler,
      handler_opts: fn conn -> {server, conn.assigns.elzoo_mcp_principal} end,
      # ex_mcp binds a session to these at initialize and refuses a later
      # request or DELETE on it with another value (HTTP 404, -32600).
      tenant_id: fn conn -> conn.assigns.elzoo_mcp_principal.tenant end,
      principal_id: fn %{assigns: %{elzoo_mcp_principal: principal}} ->
        Atom.to_string(principal.kind) <> ":" <> principal.id
      end,
      handler_call_timeout: server.call_timeout_ms + 5_000,
      body_limit: server.body_limit,
      server_info: %{name: "elzoo-mcp-server", version: "1"},
      # Modern server/discover reads the capabilities from here, not from the
      # handler's initialize answer.
      server_capabilities: %{tools: %{}},
      legacy_http_sse: false,
      oauth_enabled: false,
      # Every request carries its own bearer token, which no browser attaches by
      # itself; ex_mcp's client sends its endpoint's Origin, which the default
      # (validate_origin true, no allowed origins) refuses with 403.
      validate_origin: false
    ]
  end

  # Exactly one header `Bearer <b64token>` (RFC 6750 section 2.1): the scheme
  # ASCII case-insensitive, one or more spaces, a token of 1..8,192 bytes.
  defp bearer([header]) do
    with <<scheme::binary-size(6), rest::binary>> <- header,
         "bearer" <- String.downcase(scheme, :ascii),
         <<" ", _::binary>> <- rest,
         token = String.trim_leading(rest, " "),
         true <- byte_size(token) in 1..@max_token and b64token?(token) do
      {:ok, token}
    else
      _ -> :error
    end
  end

  defp bearer(_), do: :error

  defp b64token?(token), do: token =~ ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/

  defp reply(conn, status, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, body)
end
