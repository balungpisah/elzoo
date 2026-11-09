# SPDX-License-Identifier: Apache-2.0
# Stub transport for the integration/ai-text-anthropic tests: a function plug
# (Req's :plug option) that records every request it receives and answers with a
# response built from Anthropic's documented formats. No network is used.
defmodule Elzoo.AiText.AnthropicStub do
  @doc "Starts a recorder; returns {agent, plug}. `respond` maps a scenario to a response spec."
  def start(respond) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 8_000_000)

      Agent.update(agent, fn seen ->
        seen ++
          [
            %{
              method: conn.method,
              path: conn.request_path,
              headers: conn.req_headers,
              body: body
            }
          ]
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

  ## Documented formats (Messages API reference "Returns"; "Errors"; "Prompt caching").

  def message(content, stop_reason, usage \\ :default, extra \\ %{}) do
    base = %{
      "id" => "msg_013Zva2CMHLNnXjNJJKqJ2EF",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-5-20250929",
      "content" => content,
      "stop_reason" => stop_reason,
      "stop_sequence" => nil
    }

    base =
      case usage do
        :default -> Map.put(base, "usage", %{"input_tokens" => 2095, "output_tokens" => 503})
        :none -> base
        u -> Map.put(base, "usage", u)
      end

    Map.merge(base, extra)
  end

  def text(t), do: %{"type" => "text", "text" => t}

  def tool_use(input),
    do: %{"type" => "tool_use", "id" => "toolu_01A", "name" => "lookup", "input" => input}

  def error(type, message \\ "stub error"),
    do: %{
      "type" => "error",
      "error" => %{"type" => type, "message" => message},
      "request_id" => "req_011CSHoEeqs5C35K2UUqR7Fy"
    }

  def ok(body), do: {200, [{"request-id", "req_stub_1"}], body}
end
