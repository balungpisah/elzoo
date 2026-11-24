# SPDX-License-Identifier: Apache-2.0
# Stub transport for the integration/ai-text-google tests: a function plug (Req's
# :plug option) that records every request it receives and answers with a
# response in the documented GenerateContentResponse or google.rpc.Status error
# format of the Gemini API reference (fetched 2026-11-24). No network is used.
defmodule Elzoo.AiText.GoogleStub do
  @doc "Starts a recorder; returns {agent, plug}. `respond` maps a decoded request body to a response spec."
  def start(respond) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 80_000_000)

      Agent.update(agent, fn seen ->
        seen ++
          [
            %{
              method: conn.method,
              path: conn.request_path,
              query: conn.query_string,
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

  ## Documented formats: GenerateContentResponse, Candidate, Content, Part,
  ## UsageMetadata; the error body of "API errors (generateContent)".

  def usage(prompt \\ 36, cached \\ 0, candidates \\ 80, thoughts \\ 7) do
    %{
      "promptTokenCount" => prompt,
      "cachedContentTokenCount" => cached,
      "candidatesTokenCount" => candidates,
      "thoughtsTokenCount" => thoughts,
      "totalTokenCount" => prompt + candidates + thoughts
    }
  end

  def response(parts, reason, opts \\ []) do
    candidate =
      %{"index" => 0, "finishReason" => reason}
      |> then(fn c ->
        if parts == :none,
          do: c,
          else: Map.put(c, "content", %{"role" => "model", "parts" => parts})
      end)

    base = %{
      "candidates" => [candidate],
      "modelVersion" => "gemini-3.8-flash",
      "responseId" => "mAitaJbRBrqo1dkPnKfR6Qo"
    }

    case Keyword.get(opts, :usage, :default) do
      :default -> Map.put(base, "usageMetadata", usage())
      :none -> base
      u -> Map.put(base, "usageMetadata", u)
    end
  end

  def text(t), do: %{"text" => t}
  def thought(t), do: %{"text" => t, "thought" => true}

  def function_call(args, id \\ "fc_7d1q"),
    do: %{
      "functionCall" => %{"id" => id, "name" => "lookup", "args" => args},
      "thoughtSignature" => "CiQBVKhc7mQ="
    }

  def error(code, status, message \\ "stub error", details \\ []),
    do: %{
      "error" => %{"code" => code, "message" => message, "status" => status, "details" => details}
    }

  def retry_info(delay),
    do: %{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => delay}

  def error_info(reason),
    do: %{
      "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
      "reason" => reason,
      "domain" => "googleapis.com",
      "metadata" => %{"service" => "generativelanguage.googleapis.com"}
    }

  def ok(body), do: {200, [], body}
end
