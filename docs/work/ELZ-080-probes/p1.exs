# ELZ-080 probe p1 (no network; stub key; in-process function plugs through Req :plug).
# Run from the repository root: MIX_ENV=test mix run <this file>. Transcript: p1.txt.
# Exercises ReqLLM.Providers.OpenAI.prepare_request(:embedding, ...) + Req.request/1 with
# Elzoo-style halting response and error steps, retry settings and the ambient key.
{:ok, agent} = Agent.start_link(fn -> [] end)
mk = fn reply ->
  fn conn ->
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    Agent.update(agent, &(&1 ++ [%{m: conn.method, p: conn.request_path, h: conn.req_headers, b: body}]))
    reply.(conn)
  end
end
ok = fn conn -> Plug.Conn.send_resp(conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.put_resp_header("x-request-id", "req_abc"), 200, Jason.encode!(%{"object" => "list", "data" => [%{"object"=>"embedding","index"=>1,"embedding"=>[0.6,0.8]},%{"object"=>"embedding","index"=>0,"embedding"=>[1.0,0.0]}], "model"=>"text-embedding-3-small", "usage"=>%{"prompt_tokens"=>8,"total_tokens"=>8}})) end
capture = fn {req, resp} -> Req.Request.halt(req, Req.Response.put_private(resp, :elzoo_raw, %{status: resp.status, body: resp.body, rid: Req.Response.get_header(resp, "x-request-id")})) end
halt_err = fn {req, e} -> Req.Request.halt(req, e) end
{:ok, model} = ReqLLM.model("openai:text-embedding-3-small")
IO.inspect({model.id, model.provider_model_id, model.capabilities[:embeddings]}, label: "model")
run = fn plug, extra ->
  Agent.update(agent, fn _ -> [] end)
  {:ok, r} = ReqLLM.Providers.OpenAI.prepare_request(:embedding, model, ["alpha","beta"], [api_key: "sk-INJ", dimensions: 2, encoding_format: "float", req_http_options: [plug: plug, max_retries: 0, receive_timeout: 2000] ++ Keyword.get(extra, :http, [])] ++ Keyword.delete(extra, :http))
  res = r |> Req.Request.prepend_response_steps(elzoo_capture: capture) |> Req.Request.prepend_error_steps(elzoo_halt: halt_err) |> Req.request()
  {res, Agent.get(agent, & &1)}
end
{res, reqs} = run.(mk.(ok), [])
IO.inspect(elem(res,1).private[:elzoo_raw], label: "raw")
for q <- reqs, do: IO.inspect({q.m, q.p, Enum.filter(q.h, fn {k,_} -> k in ["authorization","content-type"] end), q.b}, label: "req")
{res, reqs} = run.(mk.(fn c -> Req.Test.transport_error(c, :timeout) end), [])
IO.inspect({res, length(reqs)}, label: "timeout")
{res, reqs} = run.(mk.(fn c -> Plug.Conn.send_resp(c, 429, ~s({"error":{"message":"x","type":"requests","code":"rate_limit_exceeded"}})) end), [])
IO.inspect({elem(res,1).private[:elzoo_raw], length(reqs)}, label: "429")
{res, reqs} = run.(mk.(fn c -> Plug.Conn.put_resp_header(c, "location", "/v1/x") |> Plug.Conn.send_resp(302, "") end), [])
IO.inspect({elem(res,1).private[:elzoo_raw], length(reqs)}, label: "302")
# without dimensions; base_url override
{_res, reqs} = run.(mk.(ok), [base_url: "https://example.invalid/v1"])
IO.inspect(hd(reqs).p, label: "path with base_url")
# Single string input
Agent.update(agent, fn _ -> [] end)
{:ok, r} = ReqLLM.Providers.OpenAI.prepare_request(:embedding, model, "solo", [api_key: "sk-INJ", req_http_options: [plug: mk.(ok), max_retries: 0]])
r |> Req.Request.prepend_response_steps(elzoo_capture: capture) |> Req.request()
IO.inspect(hd(Agent.get(agent,&(&1))).b, label: "single")
# user option and provider_options
IO.inspect(ReqLLM.Providers.OpenAI.supported_provider_options(), label: "spo")
# retries default (no max_retries) on timeout
Agent.update(agent, fn _ -> [] end)
{:ok, r} = ReqLLM.Providers.OpenAI.prepare_request(:embedding, model, ["a"], [api_key: "sk-INJ", req_http_options: [plug: mk.(fn c -> Req.Test.transport_error(c, :timeout) end)]])
r |> Req.Request.prepend_error_steps(elzoo_halt: halt_err) |> Req.request()
IO.inspect(length(Agent.get(agent,&(&1))), label: "default retries, with halting error step, timeout")
Agent.update(agent, fn _ -> [] end)
{:ok, r} = ReqLLM.Providers.OpenAI.prepare_request(:embedding, model, ["a"], [api_key: "sk-INJ", req_http_options: [plug: mk.(fn c -> Req.Test.transport_error(c, :timeout) end)]])
r |> Req.request()
IO.inspect(length(Agent.get(agent,&(&1))), label: "default retries, no elzoo steps, timeout")
Agent.update(agent, fn _ -> [] end)
{:ok, r} = ReqLLM.Providers.OpenAI.prepare_request(:embedding, model, ["a"], [api_key: "sk-INJ", req_http_options: [plug: mk.(fn c -> Plug.Conn.send_resp(c, 500, "{}") end)]])
r |> Req.Request.prepend_response_steps(elzoo_capture: capture) |> Req.request()
IO.inspect(length(Agent.get(agent,&(&1))), label: "default retries, capture step, 500")
# user option
Agent.update(agent, fn _ -> [] end)
{:ok, r} = ReqLLM.Providers.OpenAI.prepare_request(:embedding, model, ["a"], [api_key: "sk-INJ", user: "u-1", req_http_options: [plug: mk.(ok), max_retries: 0]])
r |> Req.Request.prepend_response_steps(elzoo_capture: capture) |> Req.request()
IO.inspect(hd(Agent.get(agent,&(&1))).b, label: "user")
for m <- ["openai:text-embedding-3-large", "openai:text-embedding-ada-002"] do {:ok, mm} = ReqLLM.model(m); IO.inspect({mm.id, mm.capabilities[:embeddings]}, label: "model") end
# ambient env + no api_key
System.put_env("OPENAI_API_KEY", "sk-AMBIENT")
Agent.update(agent, fn _ -> [] end)
{:ok, r} = ReqLLM.Providers.OpenAI.prepare_request(:embedding, model, ["a"], [api_key: "sk-INJ", req_http_options: [plug: mk.(ok), max_retries: 0]])
r |> Req.Request.prepend_response_steps(elzoo_capture: capture) |> Req.request()
IO.inspect(for({"authorization", v} <- hd(Agent.get(agent,&(&1))).h, do: v), label: "auth with ambient env")
