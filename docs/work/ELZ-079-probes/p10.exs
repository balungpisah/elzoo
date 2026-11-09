# ELZ-079 probe p10 (revision 2): req_llm 1.30.0 Advanced Req Plugin API with an
# Elzoo response step that copies bounded status, selected headers and raw usage and
# halts every non-2xx response, plus an error step that halts transport errors.
# Req.Test stubs only, no network, stub keys only.
Application.put_env(:req_llm, :load_dotenv, false)
# Conflicting ambient sources: the wire must carry only the injected value.
System.put_env("ANTHROPIC_API_KEY", "sk-ambient-env")
Application.put_env(:req_llm, :anthropic_api_key, "sk-ambient-app")
{:ok, _} = Application.ensure_all_started(:req_llm)
need = "sk-injected-need"
pin = "2026-10-21"
count = :counters.new(1, [])
body = %{"id" => "msg_01", "type" => "message", "role" => "assistant", "model" => "claude-sonnet-4-5-20250929",
  "content" => [%{"type" => "text", "text" => "hi"}], "stop_reason" => "end_turn", "stop_sequence" => nil,
  "usage" => %{"input_tokens" => 11, "output_tokens" => 7, "cache_creation_input_tokens" => 0}}

check_request = fn conn ->
  {:ok, raw, conn} = Plug.Conn.read_body(conn)
  json = Jason.decode!(raw)
  IO.inspect(%{path: conn.request_path, method: conn.method,
    anthropic_version: Plug.Conn.get_req_header(conn, "anthropic-version"),
    key_is_injected_need: Plug.Conn.get_req_header(conn, "x-api-key") == [need],
    body_keys: Map.keys(json) |> Enum.sort(),
    sampling_fields: Map.take(json, ["temperature", "top_p", "top_k"]) |> Map.keys()}, label: "request")
  conn
end

elzoo_step = fn {rq, rs} ->
  usage = case rs.body do
    b when is_binary(b) -> with {:ok, %{"usage" => u}} when is_map(u) <- Jason.decode(b), do: u, else: (_ -> :absent)
    %{"usage" => u} when is_map(u) -> u
    _ -> :absent
  end
  raw = %{status: rs.status, request_id: Req.Response.get_header(rs, "request-id") |> List.first(),
          retry_after: Req.Response.get_header(rs, "retry-after") |> List.first(), usage: usage}
  rs = Req.Response.put_private(rs, :elzoo_raw, raw)
  if rs.status in 200..299, do: {rq, rs}, else: Req.Request.halt(rq, rs)
end
elzoo_error = fn {rq, ex} -> Req.Request.halt(rq, ex) end

{:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5")
run = fn stub ->
  {:ok, req} = ReqLLM.Providers.Anthropic.prepare_request(:chat, model, "PROMPT-SECRET hello",
    api_key: need, max_retries: 0, anthropic_version: pin, req_http_options: [plug: {Req.Test, stub}, retry: false])
  req |> Req.Request.prepend_response_steps(elzoo_raw: elzoo_step) |> Req.Request.prepend_error_steps(elzoo_error: elzoo_error) |> Req.request()
end
show = fn label, result ->
  summary = case result do
    {:ok, %Req.Response{body: %ReqLLM.Response{} = r} = rs} -> {:ok_decoded, rs.private[:elzoo_raw], r.id, r.finish_reason, Map.take(r.usage, [:cache_read_input_tokens])}
    {:ok, %Req.Response{} = rs} -> {:ok_raw_halted, rs.private[:elzoo_raw], body_type: (if is_binary(rs.body), do: :binary, else: :map)}
    {:error, %ReqLLM.Error.API.Request{}} -> :reqllm_error_built
    {:error, %{__exception__: true} = e} -> {:error_raw, e.__struct__, Map.get(e, :reason)}
    other -> {:other, other}
  end
  text = inspect(summary, limit: :infinity)
  IO.inspect(summary, label: label)
  IO.inspect(%{prompt_in_summary: text =~ "PROMPT-SECRET", key_in_summary: text =~ "sk-"}, label: label <> " redaction")
  before = :counters.get(count, 1)
  IO.inspect(before, label: label <> " cumulative requests")
end
stub = fn name, fun -> Req.Test.stub(name, fn conn -> :counters.add(count, 1, 1); fun.(check_request.(conn)) end) end

stub.(:ok, fn conn -> conn |> Plug.Conn.put_resp_header("request-id", "req_ok") |> Req.Test.json(body) end)
show.("200", run.(:ok))
stub.(:r429, fn conn -> conn |> Plug.Conn.put_resp_header("request-id", "req_429") |> Plug.Conn.put_resp_header("retry-after", "7") |> Plug.Conn.put_status(429) |> Req.Test.json(%{"type" => "error", "error" => %{"type" => "rate_limit_error", "message" => "PROMPT-SECRET echoed"}}) end)
show.("429", run.(:r429))
stub.(:r529, fn conn -> conn |> Plug.Conn.put_resp_header("request-id", "req_529") |> Plug.Conn.put_status(529) |> Req.Test.json(%{"type" => "error", "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}}) end)
show.("529", run.(:r529))
stub.(:r302, fn conn -> conn |> Plug.Conn.put_resp_header("location", "/v1/other") |> Plug.Conn.put_status(302) |> Req.Test.text("") end)
show.("302 redirect", run.(:r302))
stub.(:timeout, fn conn -> Req.Test.transport_error(conn, :timeout) end)
show.("transport timeout", run.(:timeout))
IO.inspect(:counters.get(count, 1), label: "total requests for five calls (expect 5)")
