# SPDX-License-Identifier: Apache-2.0
# Stub transport for the integration/ai-embedding-openai tests: a function plug
# (Req's :plug option) that records every request it receives and answers with a
# response built from OpenAI's documented formats (CreateEmbeddingResponse and
# ErrorResponse of the pinned OpenAPI document). No network is used.
defmodule Elzoo.AiEmbedding.OpenAIStub do
  @doc "Starts a recorder; returns {agent, plug}. `respond` maps the decoded request body to a response spec."
  def start(respond) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 8_000_000)

      Agent.update(agent, fn seen ->
        seen ++
          [%{method: conn.method, path: conn.request_path, headers: conn.req_headers, body: body}]
      end)

      reply(conn, respond.(Jason.decode!(body)))
    end

    {agent, plug}
  end

  def requests(agent), do: Agent.get(agent, & &1)

  defp reply(conn, {:transport_error, reason}), do: Req.Test.transport_error(conn, reason)

  defp reply(conn, {status, headers, body}) do
    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  ## Documented formats.

  @doc "A CreateEmbeddingResponse listing `items` (each `%{index, vector}`) in the given order."
  def list(items, model, usage \\ :default) do
    base = %{
      "object" => "list",
      "model" => model,
      "data" =>
        for(i <- items, do: %{"object" => "embedding", "index" => i.index, "embedding" => i.vector})
    }

    case usage do
      :default -> Map.put(base, "usage", %{"prompt_tokens" => 8, "total_tokens" => 8})
      :none -> base
      u -> Map.put(base, "usage", u)
    end
  end

  def error(type, code, message \\ "stub error"),
    do: %{"error" => %{"message" => message, "type" => type, "param" => nil, "code" => code}}

  def ok(body), do: {200, [{"x-request-id", "req_stub_1"}], body}
end
