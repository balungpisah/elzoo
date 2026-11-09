Application.put_env(:req_llm, :load_dotenv, false)
{:ok, _} = Application.ensure_all_started(:req_llm)
c = :counters.new(1, [])
body = %{"id" => "msg_01", "type" => "message", "role" => "assistant", "model" => "claude-sonnet-4-5-20250929",
  "content" => [%{"type" => "text", "text" => "hi"}], "stop_reason" => "end_turn", "stop_sequence" => nil,
  "usage" => %{"input_tokens" => 11, "output_tokens" => 7, "cache_creation_input_tokens" => 0}}
Req.Test.stub(:a, fn conn ->
  :counters.add(c, 1, 1)
  {:ok, raw, conn} = Plug.Conn.read_body(conn)
  IO.inspect({conn.request_path, Plug.Conn.get_req_header(conn, "anthropic-version"), Jason.decode!(raw) |> Map.keys()}, label: "req")
  conn |> Plug.Conn.put_resp_header("request-id", "req_1") |> Req.Test.json(body) end)
{:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5")
{:ok, req} = ReqLLM.Providers.Anthropic.prepare_request(:chat, model, "hello", api_key: "sk-test", max_retries: 0, anthropic_version: "2023-06-01", req_http_options: [plug: {Req.Test, :a}])
IO.inspect(Enum.map(req.response_steps, &elem(&1,0)), label: "response steps")
req = Req.Request.prepend_response_steps(req, elzoo_raw: fn {rq, rs} -> {rq, Req.Response.put_private(rs, :elzoo_raw, %{status: rs.status, body: rs.body, headers: rs.headers})} end)
{:ok, resp} = Req.request(req)
IO.inspect(resp.private[:elzoo_raw] |> Map.update!(:body, fn b -> if is_binary(b), do: {:binary, Jason.decode!(b)["usage"]}, else: {:map, b["usage"]} end), label: "raw")
IO.inspect(resp.body.__struct__, label: "body struct")
IO.inspect({resp.body.id, resp.body.finish_reason, Map.take(resp.body.usage, [:cache_read_input_tokens, :input_tokens])}, label: "decoded")
IO.inspect(:counters.get(c, 1), label: "count")
# timeout
Req.Test.stub(:t, fn conn -> :counters.add(c, 1, 1); Req.Test.transport_error(conn, :timeout) end)
{:ok, req} = ReqLLM.Providers.Anthropic.prepare_request(:chat, model, "hello", api_key: "sk-test", max_retries: 0, req_http_options: [plug: {Req.Test, :t}])
IO.inspect(Req.request(req), label: "timeout", limit: 5)
IO.inspect(:counters.get(c, 1), label: "count after timeout (expect 2)")
# 429
Req.Test.stub(:r, fn conn -> :counters.add(c, 1, 1); conn |> Plug.Conn.put_resp_header("retry-after", "7") |> Plug.Conn.put_status(429) |> Req.Test.json(%{"type"=>"error","error"=>%{"type"=>"rate_limit_error","message"=>"x"}}) end)
{:ok, req} = ReqLLM.Providers.Anthropic.prepare_request(:chat, model, "hello", api_key: "sk-test", max_retries: 0, req_http_options: [plug: {Req.Test, :r}])
req = Req.Request.prepend_response_steps(req, elzoo_raw: fn {rq, rs} -> {rq, Req.Response.put_private(rs, :elzoo_raw, %{status: rs.status, headers: rs.headers})} end)
r = Req.request(req)
IO.inspect(r, label: "429", limit: 6, printable_limit: 120)
IO.inspect(:counters.get(c, 1), label: "count after 429 (expect 3)")
