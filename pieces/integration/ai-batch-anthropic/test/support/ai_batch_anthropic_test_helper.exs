# SPDX-License-Identifier: Apache-2.0
# Stub transport for the integration/ai-batch-anthropic tests: a function plug
# (Req's :plug option) that records every request and answers with a response
# built from Anthropic's documented Message Batches formats. No network is used.
defmodule Elzoo.AiBatch.AnthropicStub do
  @doc "Starts a recorder; returns {agent, plug}. `respond` maps {method, path, body} to a reply."
  def start(respond) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 300_000_000)

      Agent.update(agent, fn seen ->
        seen ++
          [%{method: conn.method, path: conn.request_path, headers: conn.req_headers, body: body}]
      end)

      reply(conn, respond.({conn.method, conn.request_path, body}))
    end

    {agent, plug}
  end

  def requests(agent), do: Agent.get(agent, & &1)

  defp reply(conn, {:transport_error, reason}), do: Req.Test.transport_error(conn, reason)

  # A results body sent in chunks of `size` bytes, as a streamed .jsonl file.
  defp reply(conn, {:chunked, status, chunks}) do
    conn = Plug.Conn.put_resp_content_type(conn, "application/x-jsonl")
    conn = Plug.Conn.send_chunked(conn, status)

    Enum.reduce(chunks, conn, fn c, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, c)
      conn
    end)
  end

  defp reply(conn, {status, headers, body}) do
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  ## Documented formats ("Create a Message Batch" Returns; "Batch processing").

  def batch(status, counts \\ %{}, id \\ "msgbatch_013Zva2CMHLNnXjNJJKqJ2EF") do
    %{
      "id" => id,
      "type" => "message_batch",
      "processing_status" => status,
      "request_counts" =>
        Map.merge(
          %{"processing" => 0, "succeeded" => 0, "errored" => 0, "canceled" => 0, "expired" => 0},
          counts
        ),
      "created_at" => "2024-09-24T18:37:24.100435Z",
      "expires_at" => "2024-09-25T18:37:24.100435Z",
      "ended_at" => nil,
      "cancel_initiated_at" => nil,
      "archived_at" => nil,
      "results_url" => nil
    }
  end

  def message(text, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "msg_014VwiXbi91y3JMjcpyGBHX5",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
        "content" => [%{"type" => "text", "text" => text}],
        "stop_reason" => "end_turn",
        "stop_sequence" => nil,
        "usage" => %{"input_tokens" => 11, "output_tokens" => 36}
      },
      extra
    )
  end

  def succeeded(id, message),
    do: %{"custom_id" => id, "result" => %{"type" => "succeeded", "message" => message}}

  def errored(id, type),
    do: %{
      "custom_id" => id,
      "result" => %{
        "type" => "errored",
        "error" => %{
          "type" => "error",
          "error" => %{"type" => type, "message" => "stub error"},
          "request_id" => "req_011CSHoEeqs5C35K2UUqR7Fy"
        }
      }
    }

  def canceled(id), do: %{"custom_id" => id, "result" => %{"type" => "canceled"}}
  def expired(id), do: %{"custom_id" => id, "result" => %{"type" => "expired"}}

  def jsonl(lines), do: Enum.map_join(lines, "", &(Jason.encode!(&1) <> "\n"))

  def error(type),
    do: %{
      "type" => "error",
      "error" => %{"type" => type, "message" => "stub error"},
      "request_id" => "req_011CSHoEeqs5C35K2UUqR7Fy"
    }

  def ok(body), do: {200, [{"request-id", "req_stub_1"}], body}

  @doc "Splits a binary into chunks of `size` bytes (the last one shorter)."
  def split(bin, size) do
    if byte_size(bin) <= size,
      do: [bin],
      else: [binary_part(bin, 0, size) | split(binary_part(bin, size, byte_size(bin) - size), size)]
  end

  ## The fixed corpus of the drift and body-equivalence tests.

  @lookup %{
    "name" => "lookup",
    "description" => "Look up a term.",
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"q" => %{"type" => "string"}},
      "required" => ["q"],
      "additionalProperties" => false
    }
  }

  def corpus(model) do
    base = %{
      "version" => 1,
      "model" => model,
      "messages" => [
        %{"role" => "system", "text" => "Answer briefly."},
        %{"role" => "user", "text" => "Corpus prompt."}
      ],
      "max_output_tokens" => 256
    }

    user_only = %{base | "messages" => [%{"role" => "user", "text" => "Corpus prompt."}]}
    tools = Map.put(base, "tools", [@lookup])

    tool_turns = %{
      tools
      | "messages" => [
          %{"role" => "user", "text" => "Look it up."},
          %{
            "role" => "assistant",
            "text" => "",
            "tool_calls" => [
              %{"id" => "toolu_01A", "name" => "lookup", "arguments" => %{"q" => "x"}}
            ]
          },
          %{
            "role" => "tool_result",
            "tool_use_id" => "toolu_01A",
            "text" => "failed",
            "is_error" => true
          }
        ]
    }

    hint = fn ttl ->
      %{
        "tenant" => "tenant-a",
        "local_key" => "k",
        "ttl" => ttl,
        "breakpoints" => ["system", %{"message" => 0}]
      }
    end

    [
      {"plain", user_only},
      {"system", base},
      {"tools_auto", tools},
      {"tools_any", Map.put(tools, "tool_choice", %{"type" => "any"})},
      {"tools_none", Map.put(tools, "tool_choice", %{"type" => "none"})},
      {"tools_named", Map.put(tools, "tool_choice", %{"type" => "tool", "name" => "lookup"})},
      {"tool_result_error", tool_turns},
      {"stop_sequences", Map.put(base, "stop_sequences", ["END"])},
      {"cache_5m", Map.put(base, "cache_hint", hint.("5m"))},
      {"cache_1h", Map.put(base, "cache_hint", hint.("1h"))},
      {"reasoning_low", Map.put(base, "reasoning", "low")},
      {"reasoning_medium", Map.put(base, "reasoning", "medium")},
      {"reasoning_high", Map.put(base, "reasoning", "high")},
      {"structured",
       Map.put(base, "output_schema", %{
         "type" => "object",
         "properties" => %{"answer" => %{"type" => "integer"}},
         "required" => ["answer"],
         "additionalProperties" => false
       })}
    ]
  end
end
