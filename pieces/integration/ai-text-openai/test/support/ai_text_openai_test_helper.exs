# SPDX-License-Identifier: Apache-2.0
# Stub transport for the integration/ai-text-openai tests: a function plug (Req's
# :plug option) that records every request it receives and answers with a
# response built from the pinned OpenAPI document's Response and ErrorResponse
# schemas. No network is used. Every documented-format builder here is validated
# against the pinned schema by the tests; negative controls are built inline in
# the tests and asserted to be rejected by it.
defmodule Elzoo.AiText.OpenAIStub do
  @doc "Starts a recorder; returns {agent, plug}. `respond` maps a decoded request body to a response spec."
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

  ## Documented formats (pinned OpenAPI: Response, OutputMessage, FunctionToolCall,
  ## ResponseUsage, ErrorResponse).

  def usage(input \\ 36, cached \\ 0, writes \\ 0, output \\ 87, reasoning \\ 0) do
    %{
      "input_tokens" => input,
      "input_tokens_details" => %{"cached_tokens" => cached, "cache_write_tokens" => writes},
      "output_tokens" => output,
      "output_tokens_details" => %{"reasoning_tokens" => reasoning},
      "total_tokens" => input + output
    }
  end

  def response(output, opts \\ []) do
    base = %{
      "id" => "resp_67ccd2bed1ec8190b14f964abc0542670bb6a6b452d3795b",
      "object" => "response",
      "created_at" => 1_741_476_542,
      "status" => Keyword.get(opts, :status, "completed"),
      "error" => Keyword.get(opts, :error),
      "incomplete_details" => Keyword.get(opts, :incomplete),
      "instructions" => nil,
      "model" => "gpt-6.1-terra",
      "output" => output,
      "parallel_tool_calls" => true,
      "metadata" => %{},
      "tool_choice" => "auto",
      "tools" => [],
      "temperature" => 1.0,
      "top_p" => 1.0,
      "access_programs" => nil
    }

    case Keyword.get(opts, :usage, :default) do
      :default -> Map.put(base, "usage", usage())
      :none -> base
      u -> Map.put(base, "usage", u)
    end
  end

  def message(parts),
    do: %{
      "type" => "message",
      "id" => "msg_67ccd2bf17f0819081ff3bb2cf6508e6",
      "status" => "completed",
      "role" => "assistant",
      "content" => parts
    }

  def text(t), do: %{"type" => "output_text", "text" => t, "annotations" => [], "logprobs" => []}
  def refusal(t), do: %{"type" => "refusal", "refusal" => t}

  def function_call(arguments),
    do: %{
      "type" => "function_call",
      "id" => "fc_12345xyz",
      "call_id" => "call_12345xyz",
      "name" => "lookup",
      "arguments" => arguments,
      "status" => "completed"
    }

  def reasoning, do: %{"type" => "reasoning", "id" => "rs_1", "summary" => []}

  def error(type, message \\ "stub error", code \\ nil),
    do: %{"error" => %{"type" => type, "message" => message, "param" => nil, "code" => code}}

  def ok(body), do: {200, [{"x-request-id", "req_stub_1"}], body}
end
