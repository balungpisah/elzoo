# ELZ-080 probe p2 (early review finding 5; no network; stub key; in-process function plugs).
# Run from the repository root: MIX_ENV=test mix run <this file>. Transcript: p2.txt.
# Isolates the retry setting: a transport timeout and a 500 with req_http_options
# [max_retries: 0] and NO Elzoo response or error step, against the same request
# without the setting (req_llm's default retries).
{:ok, agent} = Agent.start_link(fn -> [] end)

plug = fn reply ->
  fn conn ->
    {:ok, _body, conn} = Plug.Conn.read_body(conn)
    Agent.update(agent, &(&1 + 1))
    reply.(conn)
  end
end

timeout = fn c -> Req.Test.transport_error(c, :timeout) end
error500 = fn c -> Plug.Conn.send_resp(c, 500, ~s({"error":{"message":"x","type":"server_error","param":null,"code":null}})) end
{:ok, model} = ReqLLM.model("openai:text-embedding-3-small")

for {label, reply} <- [timeout: timeout, status_500: error500],
    {setting, http} <- [
      {"max_retries 0, no Elzoo step", [max_retries: 0, receive_timeout: 2000]},
      {"no max_retries, no Elzoo step", [receive_timeout: 2000]}
    ] do
  Agent.update(agent, fn _ -> 0 end)

  {:ok, request} =
    ReqLLM.Providers.OpenAI.prepare_request(:embedding, model, ["a"],
      api_key: "sk-INJ",
      req_http_options: [plug: plug.(reply)] ++ http
    )

  result =
    case Req.request(request) do
      {:ok, %Req.Response{status: s}} -> {:response, s}
      {:error, %{__struct__: m} = e} -> {:error, m, Map.get(e, :status) || Map.get(e, :reason)}
    end

  IO.puts("#{label} | #{setting} | requests=#{Agent.get(agent, & &1)} | #{inspect(result)}")
end
