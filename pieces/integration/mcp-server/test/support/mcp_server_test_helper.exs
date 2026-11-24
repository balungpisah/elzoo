# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpServerTest.Host do
  @moduledoc """
  The test host: its `server/0` is the init triple of the router's forward. It
  returns the server that the running test stored, or a scripted refusal.
  """
  def put(value), do: :persistent_term.put(__MODULE__, value)
  def server, do: :persistent_term.get(__MODULE__)
end

defmodule Elzoo.McpServerTest.Parsed do
  @moduledoc "A host that parses the JSON body upstream, as a default Phoenix endpoint does."
  use Plug.Builder

  plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason)
  plug(Elzoo.McpServer.Plug, {Elzoo.McpServerTest.Host, :server, []})
end

defmodule Elzoo.McpServerTest.Router do
  @moduledoc """
  The host router: the Piece's Plug under `forward`, behind a recorder that
  reports every response's status, headers and body (the wire bytes of a
  non-streamed response) to the test process.
  """
  use Plug.Router

  plug(:record)
  plug(:match)
  plug(:dispatch)

  forward("/mcp", to: Elzoo.McpServer.Plug, init_opts: {Elzoo.McpServerTest.Host, :server, []})
  forward("/parsed", to: Elzoo.McpServerTest.Parsed)

  match _ do
    send_resp(conn, 404, "")
  end

  defp record(conn, _opts) do
    case :persistent_term.get({__MODULE__, :parent}, nil) do
      nil ->
        conn

      parent ->
        register_before_send(conn, fn conn ->
          send(
            parent,
            {:wire, conn.status, conn.resp_headers, IO.iodata_to_binary(conn.resp_body || "")}
          )

          conn
        end)
    end
  end
end

defmodule Elzoo.McpServerTest.Web do
  @moduledoc "Plug.Cowboy on 127.0.0.1 with an ephemeral port, as integration/mcp-client's tests serve theirs."
  def start(parent) do
    :persistent_term.put({Elzoo.McpServerTest.Router, :parent}, parent)
    ref = {__MODULE__, make_ref()}

    {:ok, _} =
      Plug.Cowboy.http(Elzoo.McpServerTest.Router, [],
        port: 0,
        ip: {127, 0, 0, 1},
        ref: ref,
        # Cowboy's default header value bound is 4,096 bytes; raised so that the
        # Plug's own 8,192-byte token bound is what a long header meets.
        protocol_options: [max_header_value_length: 16_384]
      )

    port = :ranch.get_port(ref)
    %{ref: ref, port: port, url: "http://127.0.0.1:#{port}/mcp"}
  end

  def stop(%{ref: ref}) do
    :persistent_term.erase({Elzoo.McpServerTest.Router, :parent})
    Plug.Cowboy.shutdown(ref)
  catch
    _, _ -> :ok
  end
end
