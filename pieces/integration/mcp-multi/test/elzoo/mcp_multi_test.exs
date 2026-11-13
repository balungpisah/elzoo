# SPDX-License-Identifier: Apache-2.0
# The loopback server of the ready client: a local copy first, then the path in
# the catalogue. The helper is not edited.
mcp_helper = Path.expand("../support/mcp_client_test_helper.exs", __DIR__)

mcp_helper =
  if File.regular?(mcp_helper),
    do: mcp_helper,
    else: Path.expand("../../../mcp-client/test/support/mcp_client_test_helper.exs", __DIR__)

Code.require_file(mcp_helper)

defmodule Elzoo.McpMultiTest do
  # Each scenario names its acceptance group. No real MCP server and no provider
  # credential: every server is an instance of the ready client's in-process
  # loopback server, each with its own recording parent process.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Elzoo.{McpClient, McpMulti}
  alias Elzoo.McpClientTest.Server
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @release "approval:run-17/step-3@v1"
  @reasons [
    :credentials_expired,
    :credentials_unavailable,
    :authentication_failed,
    :target_refused,
    :connect_failed,
    :not_connected,
    :server_error,
    :malformed_response,
    :timeout,
    :connection_lost,
    :adapter_error
  ]

  setup do
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :clients)
    intents = start_supervised!({Task.Supervisor, name: nil}, id: :intents)
    %{sup: sup, intents: intents}
  end

  ## helpers

  # One loopback server instance with its own recording parent process, and a
  # test Binding whose server text is `name`.
  defp server(name) do
    rec = spawn(fn -> record([]) end)
    s = Server.start(rec)
    on_exit(fn -> Server.stop(s) end)
    Map.merge(s, %{rec: rec, name: name, binding: Server.binding(s.url, :loopback, name)})
  end

  defp record(acc) do
    receive do
      {:mcp_request, label, _auth?, _body} ->
        record([label | acc])

      {:take, from} ->
        send(from, {:taken, Enum.reverse(acc)})
        record([])
    end
  end

  # The request labels the server saw since the last call.
  defp seen(%{rec: rec}) do
    Process.sleep(150)
    send(rec, {:take, self()})

    receive do
      {:taken, labels} -> labels
    after
      1_000 -> flunk("recorder gone")
    end
  end

  defp token(ref), do: "tok-" <> ref <> "-SECRET-9f3a7c0123456789ab"

  # The test resolver: every reference has its own token; it records each call.
  defp vault(opts \\ []) do
    {:ok, v} =
      Agent.start_link(fn ->
        %{
          now: Keyword.get(opts, :now, 100),
          expiry: Keyword.get(opts, :expiry, %{}),
          missing: MapSet.new(),
          calls: []
        }
      end)

    v
  end

  defp secrets(v) do
    resolver = fn ref, scope ->
      Agent.get_and_update(v, fn st ->
        reply =
          if ref in st.missing,
            do: {:error, :missing},
            else:
              {:ok,
               %{
                 ref: ref,
                 scope: scope,
                 value: token(ref),
                 version: 1,
                 expires_at_unix_ms: Map.get(st.expiry, ref, 1_000_000)
               }}

        {reply, %{st | calls: st.calls ++ [{ref, scope}]}}
      end)
    end

    clock = fn -> Agent.get(v, & &1.now) end
    fn request -> %{grant: request, resolver: resolver, clock: clock} end
  end

  defp calls(v), do: Agent.get_and_update(v, &{&1.calls, %{&1 | calls: []}})
  defp missing(v, ref), do: Agent.update(v, &%{&1 | missing: MapSet.put(&1.missing, ref)})
  defp now(v, ms), do: Agent.update(v, &%{&1 | now: ms})

  defp entry(srv, tenant, extra \\ []) do
    [
      binding: srv.binding,
      credential: %{ref: ref(srv, tenant), scope: tenant <> "/" <> srv.name}
    ] ++ extra
  end

  defp ref(srv, tenant), do: tenant <> "-" <> srv.name

  defp multi(ctx, v, tenant, entries) do
    {:ok, c} = McpMulti.configure(tenant: tenant, secrets: secrets(v), servers: entries)
    {:ok, m} = McpMulti.connect(c, ctx.sup)
    on_exit(fn -> McpMulti.close(m) end)
    {c, m}
  end

  defp payload(tool, args) do
    Jason.encode!(%{"version" => 1, "tool" => tool, "arguments" => args, "release" => @release})
  end

  defp declaration(payload, ref \\ "call-1") do
    %{
      "capability_id" => "integration/mcp-client",
      "operation" => "tools/call",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => "message-1",
        "schema_id" => "elzoo/mcp-tool-call",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "caller", "port_id" => "tools"},
        "idempotency_key" => ref,
        "deadline_unix_ms" => 10_000,
        "payload" => payload
      }
    }
  end

  # A real EffectIntent owner on the volatile Memory store, as the ready
  # client's T3 builds it.
  defp owner(client_config, session, admission, ctx) do
    memory =
      start_supervised!({Memory, fold: Intent.fold(client_config.binding), limits: Intent.limits()},
        id: make_ref()
      )

    host_memory =
      start_supervised!({Memory, fold: StoreHost.fold(), limits: StoreHost.limits()},
        id: make_ref()
      )

    {:ok, pid} =
      Intent.start_link(
        binding: client_config.binding,
        identity: admission.identity,
        arguments: admission.arguments,
        deadline: admission.deadline,
        clock: fn -> 100 end,
        store: Memory.store(memory),
        host: {StoreHost, %{store: Memory.store(host_memory), authorize: fn _, _ -> :fresh end}},
        task_supervisor: ctx.intents,
        adapter_context: McpClient.context(session, self()),
        allow_volatile: true
      )

    pid
  end

  # Admits and dispatches one tool call through `session/2` of one server.
  defp call(ctx, m, server, listing, tool, args, ref \\ "call-1") do
    {:ok, client_config, session} = McpMulti.session(m, server)

    {:ok, a} =
      McpClient.admission(client_config, declaration(payload(tool, args), ref), listing)

    McpClient.call_tool(session, a, owner(client_config, session, a, ctx))
  end

  defp names({:ok, listing}), do: Enum.map(listing.tools, & &1["name"])

  # The whole term, past any custom Inspect implementation.
  defp full(term), do: inspect(term, structs: false, limit: :infinity, printable_limit: :infinity)

  defp refute_tokens(term, refs) do
    text =
      if is_binary(term),
        do: term,
        else: inspect(term, limit: :infinity, printable_limit: :infinity)

    for ref <- refs, do: refute(text =~ token(ref), "credential leaked")
  end

  ## acceptance groups

  test "same_tool_name_two_servers: both servers list echo under two keys; a call through session/2 of one server reaches only that server",
       ctx do
    a = server("alpha")
    b = server("beta")
    v = vault()
    {_c, m} = multi(ctx, v, "tenant-a", [entry(a, "tenant-a"), entry(b, "tenant-a")])

    lists = McpMulti.list_tools(m)
    assert Enum.sort(Map.keys(lists)) == [{"tenant-a", "alpha"}, {"tenant-a", "beta"}]
    assert "echo" in names(lists[{"tenant-a", "alpha"}])
    assert "echo" in names(lists[{"tenant-a", "beta"}])
    {:ok, la} = lists[{"tenant-a", "alpha"}]
    {:ok, lb} = lists[{"tenant-a", "beta"}]
    assert la.server == "alpha" and lb.server == "beta"
    seen(a) && seen(b)

    {:ok, ca, _} = McpMulti.session(m, "alpha")
    {:ok, cb, _} = McpMulti.session(m, "beta")
    decl = declaration(payload("echo", %{"x" => "hi"}))
    {:ok, adm_a} = McpClient.admission(ca, decl, la)
    {:ok, adm_b} = McpClient.admission(cb, decl, lb)
    assert adm_a.key != adm_b.key

    assert {:completed, %{content: [%{"text" => "echo:hi"}], is_error: false}} =
             call(ctx, m, "alpha", la, "echo", %{"x" => "hi"})

    assert seen(a) == ["tools/call"]
    assert seen(b) == []
    assert McpMulti.session(m, "gamma") == {:error, :unknown_server}
    assert :ok = McpMulti.close(m)
  end

  test "lists_keyed_by_tenant_and_server: two tenants share one server; each listing holds only its own tenant's keys and references, and no session or process",
       ctx do
    shared = server("shared")
    alpha = server("alpha")
    v = vault()
    {_, ma} = multi(ctx, v, "tenant-a", [entry(shared, "tenant-a"), entry(alpha, "tenant-a")])
    {_, mb} = multi(ctx, v, "tenant-b", [entry(shared, "tenant-b")])
    calls(v)

    la = McpMulti.list_tools(ma)
    assert Enum.sort(Map.keys(la)) == [{"tenant-a", "alpha"}, {"tenant-a", "shared"}]
    assert Enum.all?(Map.values(la), &match?({:ok, _}, &1))

    assert Enum.all?(calls(v), fn {ref, scope} ->
             ref =~ ~r/^tenant-a-/ and scope =~ ~r/^tenant-a\//
           end)

    lb = McpMulti.list_tools(mb)
    assert Map.keys(lb) == [{"tenant-b", "shared"}]
    assert {:ok, _} = lb[{"tenant-b", "shared"}]
    cb = calls(v)
    assert cb != []
    assert Enum.all?(cb, fn {ref, scope} -> ref =~ ~r/^tenant-b-/ and scope =~ ~r/^tenant-b\// end)

    {:ok, _, sa} = McpMulti.session(ma, "shared")
    {:ok, _, sb} = McpMulti.session(mb, "shared")
    assert sa.client != sb.client and sa.ledger != sb.ledger
    refute sa == sb
  end

  test "one_server_down: a server stopped before connect/2, then one stopped after it, is unavailable with a reason of the closed set; the other lists and completes a call",
       ctx do
    # Stopped before connect/2; it is declared first.
    down = server("down")
    up = server("up")
    Server.stop(down)
    v = vault()
    {_, m} = multi(ctx, v, "tenant-a", [entry(down, "tenant-a"), entry(up, "tenant-a")])
    assert {:unavailable, reason} = McpMulti.session(m, "down")
    assert reason in @reasons

    lists = McpMulti.list_tools(m)
    assert lists[{"tenant-a", "down"}] == {:unavailable, reason}
    assert {:ok, listing} = lists[{"tenant-a", "up"}]

    assert {:completed, %{content: [%{"text" => "echo:1"}]}} =
             call(ctx, m, "up", listing, "echo", %{"x" => "1"})

    # Stopped after connect/2; it is declared first.
    late = server("late")
    live = server("live")
    {_, m} = multi(ctx, v, "tenant-a", [entry(late, "tenant-a"), entry(live, "tenant-a")])
    Server.stop(late)

    lists = McpMulti.list_tools(m)
    assert {:unavailable, reason} = lists[{"tenant-a", "late"}]
    assert reason in @reasons
    assert {:ok, listing} = lists[{"tenant-a", "live"}]

    assert {:completed, %{content: [%{"text" => "echo:2"}]}} =
             call(ctx, m, "live", listing, "echo", %{"x" => "2"})
  end

  test "missing_credential_sends_nothing: a missing reference is credentials_unavailable at connect/2, list_tools/1 and a tool call with no request to that server; the other server works",
       ctx do
    a = server("alpha")
    b = server("beta")
    v = vault()
    missing(v, ref(b, "tenant-a"))
    {_, m} = multi(ctx, v, "tenant-a", [entry(a, "tenant-a"), entry(b, "tenant-a")])
    assert McpMulti.session(m, "beta") == {:unavailable, :credentials_unavailable}
    lists = McpMulti.list_tools(m)
    assert lists[{"tenant-a", "beta"}] == {:unavailable, :credentials_unavailable}
    assert {:ok, _} = lists[{"tenant-a", "alpha"}]
    assert seen(b) == []

    # Missing after connect/2.
    c = server("gamma")
    d = server("delta")
    {_, m} = multi(ctx, v, "tenant-a", [entry(c, "tenant-a"), entry(d, "tenant-a")])
    {:ok, snapshot} = McpMulti.list_tools(m)[{"tenant-a", "gamma"}]
    seen(c) && seen(d)
    missing(v, ref(c, "tenant-a"))

    lists = McpMulti.list_tools(m)
    assert lists[{"tenant-a", "gamma"}] == {:unavailable, :credentials_unavailable}
    assert {:ok, _} = lists[{"tenant-a", "delta"}]
    assert seen(c) == []

    assert {:refused, :credentials_unavailable} =
             call(ctx, m, "gamma", snapshot, "echo", %{"x" => "1"})

    refute "tools/call" in seen(c)

    # A secrets function that raises, or returns no context.
    for secrets <- [fn _ -> raise "no authority" end, fn _ -> nil end] do
      e = server("epsilon")

      {:ok, cfg} =
        McpMulti.configure(tenant: "tenant-a", secrets: secrets, servers: [entry(e, "tenant-a")])

      {:ok, m} = McpMulti.connect(cfg, ctx.sup)
      assert McpMulti.session(m, "epsilon") == {:unavailable, :credentials_unavailable}

      assert McpMulti.list_tools(m) == %{
               {"tenant-a", "epsilon"} => {:unavailable, :credentials_unavailable}
             }

      assert seen(e) == []
    end
  end

  test "rejected_credential_after_dispatch: 401 and 403 are refused authentication_failed after one tools/call; an expired reference is credentials_expired with nothing sent",
       ctx do
    a = server("alpha")
    b = server("beta")
    v = vault(expiry: %{"tenant-a-alpha" => 500})
    {_, m} = multi(ctx, v, "tenant-a", [entry(a, "tenant-a"), entry(b, "tenant-a")])
    {:ok, listing} = McpMulti.list_tools(m)[{"tenant-a", "alpha"}]
    seen(a)

    for {mode, ref} <- [auth401: "call-401", auth403: "call-403"] do
      Server.mode(a, mode)
      out = call(ctx, m, "alpha", listing, "echo", %{}, ref)
      assert out == {:refused, :authentication_failed}
      refute inspect(out) =~ "expire"
      assert Enum.count(seen(a), &(&1 == "tools/call")) == 1
    end

    # Expired after connect/2: the check before the call names it; a tool call
    # resolving it is credentials_unavailable with nothing sent.
    Server.mode(a, :pass)
    now(v, 500)
    lists = McpMulti.list_tools(m)
    assert lists[{"tenant-a", "alpha"}] == {:unavailable, :credentials_expired}
    assert {:ok, _} = lists[{"tenant-a", "beta"}]

    assert {:refused, :credentials_unavailable} =
             call(ctx, m, "alpha", listing, "echo", %{}, "call-expired")

    assert seen(a) == []

    # Expired at connect/2.
    c = server("alpha")
    {_, m} = multi(ctx, v, "tenant-a", [entry(c, "tenant-a"), entry(b, "tenant-a")])
    assert McpMulti.session(m, "alpha") == {:unavailable, :credentials_expired}
    lists = McpMulti.list_tools(m)
    assert lists[{"tenant-a", "alpha"}] == {:unavailable, :credentials_expired}
    assert {:ok, _} = lists[{"tenant-a", "beta"}]
    assert seen(c) == []
  end

  test "list_change_seen_by_listing_again: a changed list of one server is seen by the next list_tools/1; only tools/list requests are sent",
       ctx do
    a = server("alpha")
    b = server("beta")
    v = vault()
    {_, m} = multi(ctx, v, "tenant-a", [entry(a, "tenant-a"), entry(b, "tenant-a")])
    seen(a) && seen(b)

    first = McpMulti.list_tools(m)
    Server.mode(a, {:echo_list, ""})
    second = McpMulti.list_tools(m)

    assert names(first[{"tenant-a", "alpha"}]) == ["echo", "fail", "strict", "structured"]
    assert names(second[{"tenant-a", "alpha"}]) == ["echo", "echo2", "echo3"]
    assert first[{"tenant-a", "beta"}] == second[{"tenant-a", "beta"}]
    assert Map.keys(first) == Map.keys(second)

    for srv <- [a, b] do
      labels = seen(srv)
      assert labels != [] and Enum.all?(labels, &(&1 == "tools/list"))
    end
  end

  test "per_server_bounds: max_tools 2 truncates one server only; 17 entries, a repeated server text and a bound out of range are configuration errors with no host call",
       ctx do
    a = server("alpha")
    b = server("beta")
    v = vault()

    {_, m} =
      multi(ctx, v, "tenant-a", [entry(a, "tenant-a", max_tools: 2), entry(b, "tenant-a")])

    lists = McpMulti.list_tools(m)
    assert {:ok, %{tools: [_, _], truncated: true}} = lists[{"tenant-a", "alpha"}]
    assert {:ok, %{tools: [_, _, _, _], truncated: false}} = lists[{"tenant-a", "beta"}]

    test = self()
    host = fn request -> send(test, {:host_called, request}) end
    url = "http://127.0.0.1:1/mcp"

    many =
      for i <- 1..17 do
        [
          binding: Server.binding(url, :loopback, "s#{i}"),
          credential: %{ref: "r#{i}", scope: "tenant-a/s#{i}"}
        ]
      end

    assert {:ok, %McpMulti.Config{}} =
             McpMulti.configure(tenant: "tenant-a", secrets: host, servers: Enum.take(many, 16))

    other = Server.binding("http://127.0.0.1:2/mcp", :loopback, "alpha")
    dup = [binding: other, credential: %{ref: "x", scope: "tenant-a/alpha"}]

    for servers <- [
          many,
          [entry(a, "tenant-a"), dup],
          [entry(a, "tenant-a", max_tools: 0)],
          [entry(a, "tenant-a", max_tools: 1_025)],
          [entry(a, "tenant-a", call_timeout_ms: 0)],
          [entry(a, "tenant-a", protocol_mode: :other)],
          [entry(a, "tenant-a", endpoint: url)],
          [entry(a, "tenant-a") ++ [max_tools: 3, max_tools: 4]],
          [[binding: a.binding, credential: %{ref: "x"}]],
          [[binding: a.binding]],
          [[binding: Elzoo.McpMulti, credential: %{ref: "x", scope: "y"}]],
          []
        ] do
      assert {:error, :configuration} =
               McpMulti.configure(tenant: "tenant-a", secrets: host, servers: servers)
    end

    for opts <- [
          [tenant: "tenant-a", secrets: host],
          [tenant: "tenant-a", secrets: host, servers: [entry(a, "tenant-a")], extra: 1],
          [tenant: "tenant-a", secrets: fn -> :ok end, servers: [entry(a, "tenant-a")]],
          [tenant: "", secrets: host, servers: [entry(a, "tenant-a")]]
        ] do
      assert {:error, :configuration} = McpMulti.configure(opts)
    end

    refute_received {:host_called, _}
  end

  test "no_credential_in_outputs: no token is in a returned value, inspect/1 of the two values or a log captured at :debug; the Piece emits no event",
       ctx do
    a = server("alpha")
    b = server("beta")
    v = vault()
    refs = [ref(a, "tenant-a"), ref(b, "tenant-a")]
    assert Enum.all?(refs, &(byte_size(token(&1)) >= 24))

    log =
      capture_log([level: :debug], fn ->
        {c, m} = multi(ctx, v, "tenant-a", [entry(a, "tenant-a"), entry(b, "tenant-a")])
        refute_tokens(inspect(c), refs)
        refute_tokens(inspect(m), refs)
        refute_tokens(full(c), refs)
        refute_tokens(full(m), refs)
        assert inspect(c) =~ "tenant-a" and inspect(m) =~ inspect(a.binding)

        Server.mode(a, {:echo_list, ""})
        lists = McpMulti.list_tools(m)
        refute_tokens(lists, refs)
        assert names(lists[{"tenant-a", "alpha"}]) == ["echo", "echo2", "echo3"]

        Server.mode(b, :echo_auth)
        {:ok, listing} = lists[{"tenant-a", "beta"}]
        refute_tokens(McpMulti.session(m, "beta"), refs)
        out = call(ctx, m, "beta", listing, "echo", %{})
        assert {:completed, %{content: [%{"text" => text}]}} = out
        assert text =~ "[redacted]"
        refute_tokens(out, refs)

        Server.mode(b, :auth401)
        refute_tokens(call(ctx, m, "beta", listing, "echo", %{}, "call-2"), refs)

        missing(v, ref(a, "tenant-a"))
        refute_tokens(McpMulti.list_tools(m), refs)
        refute_tokens(full(c), refs)
        refute_tokens(full(m), refs)
        refute_tokens(McpMulti.close(m), refs)
      end)

    refute_tokens(log, refs)

    # No event and no log of its own: the module imports neither.
    {:ok, {_, [imports: imports]}} =
      :beam_lib.chunks(:code.which(Elzoo.McpMulti), [:imports])

    refute Enum.any?(imports, fn {mod, _, _} -> mod in [:telemetry, Logger] end)
  end

  test "example: the checked example builds a config for two Bindings and opens no connection" do
    Code.require_file("../../examples/mcp_multi.exs", __DIR__)
  end
end
