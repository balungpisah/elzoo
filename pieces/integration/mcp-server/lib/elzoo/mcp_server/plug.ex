# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpServer.Plug do
  @moduledoc """
  The Plug that the host forwards to:

      forward "/mcp", to: Elzoo.McpServer.Plug, init_opts: {MyApp.Mcp, :server, []}

  Each request applies the init triple, which must return `{:ok, server}` from
  `Elzoo.McpServer.new/1` (else HTTP 503). The bearer token is verified before
  the body is read and before any MCP handling (else HTTP 401); only then does
  `ExMCP.HttpPlug` run, with `Elzoo.McpServer.Handler`.
  """
  @behaviour Plug
  import Plug.Conn

  alias Elzoo.McpServer

  @unauthorized ~s({"error":"unauthorized"})
  @unavailable ~s({"error":"unavailable"})
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
      conn
      |> assign(:elzoo_mcp_principal, principal)
      |> ExMCP.HttpPlug.call(ExMCP.HttpPlug.init(http_opts(server)))
    else
      _ ->
        conn |> put_resp_header("www-authenticate", "Bearer") |> reply(401, @unauthorized) |> halt()
    end
  end

  defp http_opts(server) do
    [
      handler: Elzoo.McpServer.Handler,
      handler_opts: fn conn -> {server, conn.assigns.elzoo_mcp_principal} end,
      handler_call_timeout: server.call_timeout_ms + 5_000,
      body_limit: server.body_limit,
      server_info: %{name: "elzoo-mcp-server", version: "1"},
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
