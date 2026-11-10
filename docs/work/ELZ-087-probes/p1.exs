# Probe p1 (ELZ-087): req_llm 1.30.0 OpenAI Responses path with a halting
# response step; no network, stub key. Prints the captured wire request.
System.put_env("OPENAI_API_KEY", "sk-AMBIENT-env")
Application.put_env(:req_llm, :openai_api_key, "sk-AMBIENT-config")

{:ok, agent} = Agent.start_link(fn -> [] end)

reply = fn ->
  %{
    "id" => "resp_probe",
    "object" => "response",
    "created_at" => 1,
    "status" => "completed",
    "model" => "gpt-6.1-terra",
    "output" => [
      %{
        "type" => "function_call",
        "id" => "fc_1",
        "call_id" => "call_1",
        "name" => "lookup",
        "arguments" => "{not json",
        "status" => "completed"
      }
    ],
    "usage" => %{
      "input_tokens" => 12000,
      "input_tokens_details" => %{
        "cached_tokens" => 4000,
        "cache_write_tokens" => 7000,
        "cache_write_tokens_details" => %{"ttl_30m_tokens" => 3000, "ttl_12h_tokens" => 4000}
      },
      "output_tokens" => 10,
      "output_tokens_details" => %{"reasoning_tokens" => 3},
      "total_tokens" => 12010
    }
  }
end

plug = fn conn ->
  {:ok, body, conn} = Plug.Conn.read_body(conn)
  Agent.update(agent, &(&1 ++ [%{path: conn.request_path, headers: conn.req_headers, body: body}]))

  conn
  |> Plug.Conn.put_resp_header("x-request-id", "req_probe_1")
  |> Plug.Conn.put_resp_content_type("application/json")
  |> Plug.Conn.send_resp(200, Jason.encode!(reply.()))
end

{:ok, model} = ReqLLM.model("openai:gpt-6.1-terra")
IO.inspect(ReqLLM.RequestPlan.openai_surface(model) |> elem(1), label: "surface")

bp = %{prompt_cache_breakpoint: %{mode: "explicit"}}

context =
  ReqLLM.Context.new([
    ReqLLM.Context.system([ReqLLM.Message.ContentPart.text("Answer briefly.", bp)]),
    ReqLLM.Context.user([ReqLLM.Message.ContentPart.text("Conformance prompt.", bp)])
  ])

tool =
  ReqLLM.Tool.new!(
    name: "lookup",
    description: "Look up a term.",
    parameter_schema: %{
      "type" => "object",
      "properties" => %{"q" => %{"type" => "string"}},
      "required" => ["q"],
      "additionalProperties" => false
    },
    callback: fn _ -> {:error, :no} end
  )

opts = [
  api_key: "sk-INJECTED",
  max_retries: 0,
  max_tokens: 256,
  reasoning_effort: :low,
  tools: [tool],
  receive_timeout: 2000,
  req_http_options: [plug: plug, retry: false],
  provider_options: [
    prompt_cache_key: "ez1.KEY",
    prompt_cache_options: %{mode: "explicit", ttl: "30m"},
    store: false
  ]
]

{:ok, req} = ReqLLM.Providers.OpenAI.prepare_request(:chat, model, context, opts)

capture = fn {request, response} ->
  Req.Request.halt(request, Req.Response.put_private(response, :raw, response.body))
end

result =
  req
  |> Req.Request.prepend_response_steps(cap: capture)
  |> Req.request()

{:ok, resp} = result
IO.inspect(is_binary(resp.private[:raw]), label: "raw body binary")
[seen] = Agent.get(agent, & &1)
IO.puts("path: " <> seen.path)
IO.inspect(for({k, v} <- seen.headers, k in ["authorization", "openai-beta"], do: {k, v}), label: "headers")
IO.puts(Jason.encode!(Jason.decode!(seen.body), pretty: true))
