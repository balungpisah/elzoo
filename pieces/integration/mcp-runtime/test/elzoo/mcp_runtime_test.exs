# SPDX-License-Identifier: Apache-2.0
# The loopback server of the ready client: a local copy first, then the path in
# the catalogue. The helper is not edited.
mcp_helper = Path.expand("../support/mcp_client_test_helper.exs", __DIR__)

mcp_helper =
  if File.regular?(mcp_helper),
    do: mcp_helper,
    else: Path.expand("../../../mcp-client/test/support/mcp_client_test_helper.exs", __DIR__)

Code.require_file(mcp_helper)

defmodule Elzoo.McpRuntimeTest do
  # Each scenario names its acceptance group. No public endpoint is contacted:
  # every admitted config is public by design, so its sessions here are values
  # with no client process. Only the "other runtime config" of the pairing group
  # is live, on the ready client's in-process loopback server, configured
  # directly with the ready client (egress-policy refuses loopback by design).
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Elzoo.{EgressPolicy, McpClient, McpRuntime}
  alias Elzoo.McpClient.{RuntimeBinding, Session}
  alias Elzoo.McpClientTest.Server
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @host "mcp-7c1e.example.test"
  @host_b "tools-7c1e.example.test"
  @url "https://" <> @host <> "/mcp"
  @url_b "https://" <> @host_b <> "/v2/mcp"
  @public [{93, 184, 215, 14}, {8, 8, 8, 8}]
  @release "approval:run-17/step-3@v1"

  setup do
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :clients)
    intents = start_supervised!({Task.Supervisor, name: nil}, id: :intents)
    %{sup: sup, intents: intents}
  end

  ## helpers

  defp token(ref), do: "tok-" <> ref <> "-SECRET-9f3a7c0123456789ab"
  defp ref(tenant, server), do: "ref-7c1e-" <> tenant <> "-" <> server

  # The test Secrets resolver: each reference has its own token unless a reply
  # is set for it; it records each call.
  defp vault(opts \\ []) do
    {:ok, v} =
      Agent.start_link(fn ->
        %{now: 100, expiry: Keyword.get(opts, :expiry, %{}), reply: %{}, calls: 0, asked: 0}
      end)

    v
  end

  defp secrets(v) do
    resolver = fn ref, scope ->
      Agent.get_and_update(v, fn st ->
        reply =
          Map.get_lazy(st.reply, ref, fn ->
            {:ok,
             %{
               ref: ref,
               scope: scope,
               value: token(ref),
               version: 1,
               expires_at_unix_ms: Map.get(st.expiry, ref, 1_000_000)
             }}
          end)

        {reply, %{st | calls: st.calls + 1}}
      end)
    end

    clock = fn -> Agent.get(v, & &1.now) end

    fn request ->
      Agent.update(v, &%{&1 | asked: &1.asked + 1})
      %{grant: request, resolver: resolver, clock: clock}
    end
  end

  # {secrets function calls, Secrets resolver calls} since the last read.
  defp counts(v), do: Agent.get_and_update(v, &{{&1.asked, &1.calls}, %{&1 | asked: 0, calls: 0}})
  defp reply(v, ref, reply), do: Agent.update(v, &%{&1 | reply: Map.put(&1.reply, ref, reply)})
  defp now(v, ms), do: Agent.update(v, &%{&1 | now: ms})

  # An egress resolver Need answering `answer` (or running it), counted.
  defp resolver(answer) do
    counter = :counters.new(1, [])

    fun = fn _host ->
      :counters.add(counter, 1, 1)
      if is_function(answer, 0), do: answer.(), else: answer
    end

    {fun, counter}
  end

  defp policy, do: EgressPolicy.policy(hosts: [@host, @host_b], ports: [443])

  defp opts(v, overrides) do
    tenant = Keyword.get(overrides, :tenant, "tenant-a")
    server = Keyword.get(overrides, :server, "alpha")

    Keyword.merge(
      [
        tenant: tenant,
        server: server,
        url: @url,
        policy: policy(),
        resolver: elem(resolver({:ok, @public}), 0),
        credential: %{ref: ref(tenant, server), scope: tenant <> "/" <> server},
        secrets: secrets(v)
      ],
      overrides
    )
  end

  defp configured(v, overrides \\ []) do
    {:ok, config} = McpRuntime.configure(opts(v, overrides))
    config
  end

  defp admitted(v, overrides \\ []) do
    config = configured(v, overrides)
    {:ok, client} = McpRuntime.admit(config)
    {config, client}
  end

  # A session value of an admitted config with no client process: a public
  # connect is not exercised.
  defp offline(client), do: %Session{config: client, client: nil, ledger: nil}

  # Live ExMCP.Client processes and TCP sockets of this node.
  defp mcp_clients do
    Enum.count(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, d} -> match?({ExMCP.Client, _, _}, d[:"$initial_call"])
        nil -> false
      end
    end)
  end

  # Modules of this Piece's BEAM imports that open a socket or a transport.
  defp transport_imports do
    {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(McpRuntime), [:imports])

    for {mod, _, _} <- imports,
        mod in [:gen_tcp, :ssl, :socket, :inet, ExMCP.Client] or
          String.starts_with?(Atom.to_string(mod), ["Elixir.Mint", "Elixir.ExMCP"]),
        uniq: true,
        do: mod
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

  @snapshot %{
    server: "x",
    protocol_version: nil,
    truncated: false,
    tools: [%{"trust" => "untrusted", "name" => "echo", "input_schema" => %{"type" => "object"}}]
  }

  # The Contract's digest, derived here from its text: "rt1:" and the lowercase
  # hex SHA-256 of the length-framed server, endpoint and ref.
  defp rt_digest(server, endpoint, ref) do
    framed =
      <<byte_size(server)::32, server::binary, byte_size(endpoint)::32, endpoint::binary,
        byte_size(ref)::32, ref::binary>>

    "rt1:" <> Base.encode16(:crypto.hash(:sha256, framed), case: :lower)
  end

  # A real EffectIntent owner on the volatile Memory store, as the ready
  # client's tests build it, with the given Adapter context.
  defp owner(client, admission, ctx, adapter_context) do
    memory =
      start_supervised!({Memory, fold: Intent.fold(client.binding), limits: Intent.limits()},
        id: make_ref()
      )

    host_memory =
      start_supervised!({Memory, fold: StoreHost.fold(), limits: StoreHost.limits()},
        id: make_ref()
      )

    {:ok, pid} =
      Intent.start_link(
        binding: client.binding,
        identity: admission.identity,
        arguments: admission.arguments,
        deadline: admission.deadline,
        clock: fn -> 100 end,
        store: Memory.store(memory),
        host: {StoreHost, %{store: Memory.store(host_memory), authorize: fn _, _ -> :fresh end}},
        task_supervisor: ctx.intents,
        adapter_context: adapter_context,
        allow_volatile: true
      )

    pid
  end

  defp settled(pid, tries \\ 300) do
    cond do
      :sys.get_state(pid).tasks == %{} -> Intent.status(pid)
      tries == 0 -> flunk("attempt never settled")
      true -> Process.sleep(20) && settled(pid, tries - 1)
    end
  end

  defp requests(wait \\ 150) do
    receive do
      {:mcp_request, label, _auth?, _body} -> [label | requests(wait)]
    after
      wait -> []
    end
  end

  # A live runtime session of another config on the loopback server.
  defp loopback(ctx, server_text) do
    srv = Server.start()
    on_exit(fn -> Server.stop(srv) end)

    {:ok, c} =
      McpClient.configure(
        binding: RuntimeBinding,
        runtime: %{
          server: server_text,
          endpoint: srv.url,
          network: :loopback,
          addresses: [{127, 0, 0, 1}]
        },
        tenant: "tenant-a",
        credentials: fn -> {:ok, token("loopback")} end
      )

    {:ok, s} = McpClient.connect(c, ctx.sup)
    on_exit(fn -> McpClient.close(s) end)
    {srv, s}
  end

  ## acceptance groups

  test "egress_first: every egress refusal is {:egress, reason} with egress-policy's reason; no secrets call, no Secrets resolver call, no client or socket" do
    v = vault()
    raise_answer = fn -> raise "resolver down" end

    cases = [
      {"http://" <> @host <> "/mcp", {:ok, @public}, :scheme},
      {"https://93.184.215.14/mcp", {:ok, @public}, :host},
      {"https://other-7c1e.example.test/mcp", {:ok, @public}, :not_allowed},
      {"https://" <> @host <> ":8443/mcp", {:ok, @public}, :port},
      {@url, {:error, :nxdomain}, :dns_failed},
      {@url, raise_answer, :unavailable},
      {@url, {:ok, [{10, 0, 0, 1}]}, :non_public_address},
      {@url, {:ok, [{169, 254, 169, 254}]}, :non_public_address},
      {@url, {:ok, [{127, 0, 0, 1}]}, :non_public_address},
      {@url, {:ok, [{8, 8, 8, 8}, {192, 168, 1, 1}]}, :non_public_address}
    ]

    clients = mcp_clients()

    for {url, answer, reason} <- cases do
      {fun, counter} = resolver(answer)
      config = configured(v, url: url, resolver: fun)
      counts(v)
      assert McpRuntime.admit(config) == {:error, {:egress, reason}}, url
      # The reason is egress-policy's own answer for the same input.
      assert EgressPolicy.resolve(url, policy(), fun) == {:error, reason}
      assert counts(v) == {0, 0}, url
      # The resolver ran once per call only when the pure check passed.
      expected = if reason in [:dns_failed, :unavailable, :non_public_address], do: 2, else: 0
      assert :counters.get(counter, 1) == expected, url
    end

    # No socket: no ExMCP.Client exists, and the Piece itself calls no socket
    # or transport module (the ready client opens sockets only in its client).
    assert mcp_clients() == clients
    assert transport_imports() == []
  end

  test "admission: an allowlisted https URL with two public addresses gives a ready runtime config pinned to the egress host, port and sorted set; the Need resolves again on each call; a query is configuration" do
    v = vault()
    url = "https://MCP-7c1e.Example.Test:443/mcp"
    {fun, counter} = resolver({:ok, @public})
    config = configured(v, url: url, resolver: fun, max_tools: 3, call_timeout_ms: 1_234)
    assert counts(v) == {0, 0}
    clients = mcp_clients()

    assert {:ok, %McpClient.Config{} = client} = McpRuntime.admit(config)
    assert :counters.get(counter, 1) == 1
    assert counts(v) == {1, 1}
    assert mcp_clients() == clients

    assert client.binding == RuntimeBinding
    assert client.tenant == "tenant-a"

    assert client.runtime == %{
             server: "alpha",
             endpoint: url,
             network: :public,
             addresses: [{8, 8, 8, 8}, {93, 184, 215, 14}]
           }

    {:ok, target} = EgressPolicy.resolve(url, policy(), fun)
    assert %{host: host, port: port} = client.settings.endpoint
    assert {host, port} == {target.host, target.port}
    assert {host, port} == {@host, 443}
    assert client.settings.addresses == target.addresses
    assert client.settings.server == "alpha"
    # Optional bounds pass to the ready client unchanged.
    assert client.max_tools == 3 and client.call_timeout_ms == 1_234

    # The credential Need resolves the reference again at each call.
    ref = ref("tenant-a", "alpha")
    assert client.credentials.() == {:ok, token(ref)}
    assert client.credentials.() == {:ok, token(ref)}
    assert counts(v) == {2, 2}
    reply(v, ref, {:error, :missing})
    assert client.credentials.() == {:error, :credentials_unavailable}
    assert counts(v) == {1, 1}

    for url <- [@url <> "?tenant=b", @url <> "?"] do
      assert McpRuntime.configure(opts(v, url: url)) == {:error, :configuration}
    end

    # The exact key set and the ready client's own checks, with no Need called.
    for bad <- [
          Keyword.delete(opts(v, []), :policy),
          opts(v, extra: 1),
          opts(v, []) ++ [tenant: "tenant-a"],
          opts(v, max_tools: 0),
          opts(v, protocol_mode: :other),
          opts(v, tenant: ""),
          opts(v, server: ""),
          opts(v, server: String.duplicate("s", 129)),
          opts(v, url: 1),
          opts(v, policy: %{hosts: [@host], ports: [443]}),
          opts(v, resolver: fn -> {:ok, @public} end),
          opts(v, secrets: fn -> :none end),
          opts(v, credential: %{ref: "r"}),
          opts(v, credential: %{ref: "r", scope: "s", extra: 1}),
          opts(v, credential: %{ref: 1, scope: "s"})
        ] do
      assert McpRuntime.configure(bad) == {:error, :configuration}
    end

    assert McpRuntime.configure(%{}) == {:error, :configuration}

    # A policy struct that egress-policy did not build.
    forged = struct(EgressPolicy, hosts: [@host], ports: [443])
    assert McpRuntime.configure(opts(v, policy: forged)) == {:error, :configuration}

    # Invalid UTF-8 is egress-policy's :malformed, before any Need.
    {fun, counter} = resolver({:ok, @public})
    bad_utf8 = configured(v, url: @url <> <<0xFF>>, resolver: fun)
    assert McpRuntime.admit(bad_utf8) == {:error, {:egress, :malformed}}
    assert :counters.get(counter, 1) == 0

    # Step 3 refusal: a 513-byte URL passes egress (up to 2048 bytes) and the
    # check, and the ready client refuses it (endpoints up to 512 bytes).
    long = @url <> "/" <> String.duplicate("p", 512 - byte_size(@url))
    assert byte_size(long) == 513
    {fun, counter} = resolver({:ok, @public})
    assert {:ok, _} = EgressPolicy.resolve(long, policy(), fun)
    counts(v)
    clients = mcp_clients()

    assert McpRuntime.admit(configured(v, server: "gamma", url: long, resolver: fun)) ==
             {:error, :configuration}

    assert :counters.get(counter, 1) == 2
    assert counts(v) == {1, 1}
    assert mcp_clients() == clients
    {:ok, _} = McpRuntime.admit(configured(v, server: "gamma", url: binary_part(long, 0, 512)))
    assert counts(v) == {1, 1}
    assert McpRuntime.admit(:none) == {:error, :configuration}
    assert {:ok, _} = McpRuntime.configure(opts(v, server: String.duplicate("s", 128)))
    assert counts(v) == {0, 0}
  end

  test "credentials: expired is credentials_expired; denied, missing, unavailable and a raise, throw or exit of secrets are credentials_unavailable; each after egress passes and before any client" do
    v = vault(expiry: %{ref("tenant-a", "alpha") => 500})
    ref = ref("tenant-a", "alpha")
    clients = mcp_clients()

    admit = fn overrides ->
      {fun, counter} = resolver({:ok, @public})
      config = configured(v, [resolver: fun] ++ overrides)
      result = McpRuntime.admit(config)
      assert :counters.get(counter, 1) == 1
      result
    end

    assert {:ok, _} = admit.([])
    now(v, 500)
    assert admit.([]) == {:error, :credentials_expired}
    now(v, 100)

    for tag <- [:denied, :missing, :unavailable] do
      reply(v, ref, {:error, tag})
      assert admit.([]) == {:error, :credentials_unavailable}, inspect(tag)
    end

    counts(v)

    for secrets <- [
          fn _ -> raise "no authority" end,
          fn _ -> throw(:no_authority) end,
          fn _ -> exit(:no_authority) end,
          fn _ -> nil end,
          # A grant that is not the request: Secrets answers denied.
          fn request ->
            %{grant: %{request | scope: "tenant-b/alpha"}, resolver: fn _, _ -> :x end}
          end
        ] do
      assert admit.(secrets: secrets) == {:error, :credentials_unavailable}
    end

    assert counts(v) == {0, 0}
    assert mcp_clients() == clients
  end

  test "keying: two servers of one tenant and one server text in two tenants give distinct {tenant, server} keys and distinct rt1 identities for one ref; listings are the unchanged ready result and the check runs first",
       ctx do
    v = vault()
    {ca, a} = admitted(v)
    {cb, b} = admitted(v, server: "beta", url: @url_b)
    {ct, t} = admitted(v, tenant: "tenant-b")
    # Same tenant and server text, another URL.
    {_, u} = admitted(v, url: @url_b)

    decl = declaration(payload("echo", %{}), "call-1")

    identities =
      for {client, tenant, server, url} <- [
            {a, "tenant-a", "alpha", @url},
            {b, "tenant-a", "beta", @url_b},
            {t, "tenant-b", "alpha", @url}
          ] do
        {:ok, adm} = McpClient.admission(client, decl, @snapshot)
        expected = rt_digest(server, url, "call-1")

        assert adm.identity == [tenant, "mcp:runtime", "mcp-client-runtime", "tools/call", expected]
        assert byte_size(expected) == 68
        assert adm.ref == "call-1"
        {adm.identity, adm.key}
      end

    assert length(Enum.uniq(Enum.map(identities, &elem(&1, 0)))) == 3
    assert length(Enum.uniq(Enum.map(identities, &elem(&1, 1)))) == 3

    lists =
      Map.merge(McpRuntime.list_tools(ca, offline(a)), McpRuntime.list_tools(cb, offline(b)))
      |> Map.merge(McpRuntime.list_tools(ct, offline(t)))

    assert Enum.sort(Map.keys(lists)) == [
             {"tenant-a", "alpha"},
             {"tenant-a", "beta"},
             {"tenant-b", "alpha"}
           ]

    # No client process: the ready client's own finite reason passes through.
    assert Enum.all?(Map.values(lists), &(&1 == {:unavailable, :not_connected}))

    # A listing through a session whose Config is the admitted one and whose
    # client is connected to the loopback server (a stand-in: no public connect
    # is exercised) is the ready list_tools/1 result, unchanged.
    {_srv, live} = loopback(ctx, "other")
    stand_in = %{live | config: a}
    requests()
    # The loopback server pages its tools: one listing is several tools/list.
    assert {:ok, ready} = McpClient.list_tools(stand_in)
    pages = requests()
    assert pages != [] and Enum.all?(pages, &(&1 == "tools/list"))
    assert McpRuntime.list_tools(ca, stand_in) == %{{"tenant-a", "alpha"} => {:ok, ready}}
    assert ready.server == "alpha"
    assert requests() == pages

    # The check before the call: expired or missing, and nothing is sent.
    now(v, 1_000_000)

    assert McpRuntime.list_tools(ca, stand_in) == %{
             {"tenant-a", "alpha"} => {:unavailable, :credentials_expired}
           }

    now(v, 100)
    reply(v, ref("tenant-a", "alpha"), {:error, :missing})

    assert McpRuntime.list_tools(ca, stand_in) == %{
             {"tenant-a", "alpha"} => {:unavailable, :credentials_unavailable}
           }

    assert requests() == []

    # A session of another config is not listed under this key: another
    # server, tenant or URL (same tenant and server), or a build-time session.

    {:ok, built} =
      McpClient.configure(
        binding: Server.binding(@url, :public, "alpha"),
        tenant: "tenant-a",
        credentials: fn -> {:ok, token("built")} end
      )

    for session <- [offline(b), offline(t), offline(u), offline(built), live] do
      assert_raise FunctionClauseError, fn -> McpRuntime.list_tools(ca, session) end
    end
  end

  test "pairing: a session of another runtime config cannot execute an intent admitted under this one; the bound context of this config is accepted",
       ctx do
    v = vault()
    {_, a} = admitted(v)
    {_, b} = admitted(v, server: "beta", url: @url_b)
    {_, t} = admitted(v, tenant: "tenant-b")
    decl = declaration(payload("echo", %{"x" => "p"}))
    {:ok, aa} = McpClient.admission(a, decl, @snapshot)

    # context/3 binds only an admission that the session's Config gives.
    assert {:ok, %{key: key}} = McpClient.context(offline(a), aa, self())
    assert key == aa.key

    for other <- [b, t] do
      assert {:error, :context} = McpClient.context(offline(other), aa, self())
    end

    # A live session of another runtime config (loopback, configured directly
    # with the ready client) that sends its own admission once.
    clients = mcp_clients()
    {_srv, live} = loopback(ctx, "alpha")
    # Positive control of the client counter that egress_first and credentials
    # use (the loopback server starts no ExMCP.Client).
    assert mcp_clients() > clients
    snap = %{elem(McpClient.list_tools(live), 1) | server: "alpha"}
    {:ok, al} = McpClient.admission(live.config, decl, snap)
    assert al.key != aa.key
    assert {:error, :context} = McpClient.context(live, aa, self())
    {:ok, bound_live} = McpClient.context(live, al, self())
    requests()

    # This config's intent with the other session's bound or unbound context:
    # the owner dispatches, the Adapter sends nothing.
    for context <- [bound_live, McpClient.context(live, self())] do
      pid = owner(a, aa, ctx, context)
      assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      refute match?({:Confirmed, _}, settled(pid).phase)
      assert requests() == []
    end

    refute_received {:elzoo_mcp_result, _, _, _}

    # Control: the other config's own intent with its bound context sends once.
    pid = owner(live.config, al, ctx, bound_live)

    assert {:completed, %{content: [%{"text" => "echo:p"}]}} =
             McpClient.call_tool(live, al, pid)

    assert requests() == ["tools/call"]
  end

  test "secrecy: the URL, host, token and reference bytes are in no result, raised message, inspected value or captured log; the Piece emits no event or log" do
    v = vault()

    secret = fn tenant, server, url ->
      host = URI.parse(url).host
      [url, host, token(ref(tenant, server)), ref(tenant, server)]
    end

    words = secret.("tenant-a", "alpha", @url) ++ secret.("tenant-a", "beta", @url_b)

    refute_words = fn term ->
      text =
        if is_binary(term),
          do: term,
          else: inspect(term, limit: :infinity, printable_limit: :infinity)

      for w <- words, do: refute(text =~ w, "leaked")
    end

    log =
      capture_log([level: :debug], fn ->
        config = configured(v)
        {cb, b} = admitted(v, server: "beta", url: @url_b)
        refute_words.(config)
        assert inspect(config) == ~s(#Elzoo.McpRuntime.Config<tenant: "tenant-a", server: "alpha">)
        {:ok, a} = McpRuntime.admit(config)
        refute_words.(a)
        refute_words.(McpRuntime.list_tools(config, offline(a)))

        for overrides <- [
              [url: "http://" <> @host <> "/mcp"],
              [url: "https://" <> @host <> ":8443/mcp"],
              [resolver: fn _ -> raise @url end],
              [resolver: fn _ -> {:ok, [{10, 0, 0, 1}]} end],
              [secrets: fn _ -> raise @url <> token(ref("tenant-a", "alpha")) end]
            ] do
          refute_words.(McpRuntime.admit(configured(v, overrides)))
        end

        reply(v, ref("tenant-a", "alpha"), {:error, :missing})
        refute_words.(McpRuntime.admit(config))
        refute_words.(McpRuntime.list_tools(config, offline(a)))
        refute_words.(McpRuntime.configure(opts(v, url: @url <> "?x=1")))

        {e, stack} =
          try do
            McpRuntime.list_tools(config, offline(b))
          rescue
            e -> {e, __STACKTRACE__}
          end

        {blamed, _} = Exception.blame(:error, e, stack)
        refute_words.(Exception.message(blamed))
        refute_words.(Exception.format(:error, blamed, stack))
        refute_words.(cb)
      end)

    refute_words.(log)

    {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(McpRuntime), [:imports])
    refute Enum.any?(imports, fn {mod, _, _} -> mod in [:telemetry, Logger] end)
  end

  test "example: the checked example builds a config and is refused by the egress policy before any Need" do
    Code.require_file("../../examples/mcp_runtime.exs", __DIR__)
  end
end
