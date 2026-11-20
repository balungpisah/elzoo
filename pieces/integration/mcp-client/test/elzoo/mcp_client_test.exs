# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/mcp_client_test_helper.exs", __DIR__)

defmodule Elzoo.McpClientTest do
  # Each scenario names the boundary it exercises. No external MCP server: every
  # request goes to the in-process loopback server started here (ex_mcp's own
  # server behind a recording Plug on 127.0.0.1), or is refused before sending
  # (asserted with the server's request record).
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Elzoo.McpClient
  alias Elzoo.McpClient.{Adapter, AuthProvider, Binding, RuntimeBinding, Transport}
  alias Elzoo.McpClientTest.Server
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @token "tok-SECRET-9f3a7c-0123456789ab"
  @release "approval:run-17/step-3@v1"

  setup do
    server = Server.start()
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :clients)
    intents = start_supervised!({Task.Supervisor, name: nil}, id: :intents)
    on_exit(fn -> Server.stop(server) end)
    %{server: server, sup: sup, intents: intents}
  end

  ## helpers

  defp config(ctx, opts) do
    binding = Keyword.get_lazy(opts, :binding, fn -> Server.binding(ctx.server.url) end)

    {:ok, c} =
      McpClient.configure(
        [
          binding: binding,
          tenant: "tenant-a",
          credentials: Keyword.get(opts, :credentials, fn -> {:ok, @token} end)
        ] ++ Keyword.drop(opts, [:binding, :credentials])
      )

    c
  end

  defp session(ctx, opts \\ []) do
    {:ok, s} = McpClient.connect(config(ctx, opts), ctx.sup)
    on_exit(fn -> McpClient.close(s) end)
    s
  end

  defp payload(tool, args, release \\ @release) do
    Jason.encode!(%{"version" => 1, "tool" => tool, "arguments" => args, "release" => release})
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

  defp snapshot(s) do
    {:ok, d} = McpClient.list_tools(s)
    d
  end

  defp owner(s, admission, ctx, recipient \\ self()) do
    c = s.config

    memory =
      start_supervised!({Memory, fold: Intent.fold(c.binding), limits: Intent.limits()},
        id: make_ref()
      )

    host_memory =
      start_supervised!({Memory, fold: StoreHost.fold(), limits: StoreHost.limits()},
        id: make_ref()
      )

    {:ok, pid} =
      Intent.start_link(
        binding: c.binding,
        identity: admission.identity,
        arguments: admission.arguments,
        deadline: admission.deadline,
        clock: fn -> 100 end,
        store: Memory.store(memory),
        host: {StoreHost, %{store: Memory.store(host_memory), authorize: fn _, _ -> :fresh end}},
        task_supervisor: ctx.intents,
        adapter_context: McpClient.context(s, recipient),
        allow_volatile: true
      )

    pid
  end

  # The request EffectIntent hands the Adapter for attempt 1.
  defp request(s, arguments, recipient \\ self()) do
    {:ok, b, _} = Binding.load(s.config.binding, s.config.runtime)

    %{
      key: String.duplicate("a", 64),
      attempt: 1,
      attempt_id: "attempt-1",
      arguments: arguments,
      arguments_digest: :crypto.hash(:sha256, arguments),
      schema: Adapter.schema(),
      binding: b.digest,
      context: McpClient.context(s, recipient)
    }
  end

  defp send_one(s, arguments), do: Adapter.send_effect(request(s, arguments))

  defp settled(pid, tries \\ 300) do
    cond do
      :sys.get_state(pid).tasks == %{} -> Intent.status(pid)
      tries == 0 -> flunk("attempt never settled")
      true -> Process.sleep(20) && settled(pid, tries - 1)
    end
  end

  defp requests(wait \\ 150) do
    receive do
      {:mcp_request, label, auth?, body} -> [{label, auth?, body} | requests(wait)]
    after
      wait -> []
    end
  end

  # A runtime endpoint map for the loopback evidence server.
  defp runtime(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        server: "elzoo-runtime-server",
        endpoint: ctx.server.url,
        network: :loopback,
        addresses: [{127, 0, 0, 1}]
      },
      overrides
    )
  end

  defp count(reqs, label), do: Enum.count(reqs, &(elem(&1, 0) == label))

  defp flush_results do
    receive do
      {:elzoo_mcp_result, _, _, _} -> flush_results()
    after
      0 -> :ok
    end
  end

  defp refute_token(term) do
    text =
      if is_binary(term),
        do: term,
        else: inspect(term, limit: :infinity, printable_limit: :infinity)

    refute text =~ @token, "credential leaked"
  end

  ## connect traffic and discovery

  test "T24 connect sends only the handshake per protocol mode; legacy close ends the session with DELETE (ex_mcp client + loopback server)",
       ctx do
    s = session(ctx, protocol_mode: :modern_only)
    r = requests()
    assert Enum.map(r, &elem(&1, 0)) == ["server/discover"]
    assert Enum.all?(r, &elem(&1, 1))
    McpClient.close(s)
    assert requests() == []

    s = session(ctx, protocol_mode: :legacy_only)
    assert Enum.map(requests(), &elem(&1, 0)) == ["initialize", "notifications/initialized"]
    McpClient.close(s)
    assert Enum.map(requests(), &elem(&1, 0)) == [{:http, "DELETE"}]
  end

  test "T1 discovery pages with page and total bounds and never sends tools/call; descriptors are untrusted data (list_tools + loopback server)",
       ctx do
    s = session(ctx)
    requests()
    assert {:ok, d} = McpClient.list_tools(s)
    assert d.server == "elzoo-test-server" and d.protocol_version == "2026-07-28"
    assert Enum.map(d.tools, & &1["name"]) == ["echo", "fail", "strict", "structured"]
    refute d.truncated
    assert Enum.all?(d.tools, &(&1["trust"] == "untrusted"))
    r = requests()
    assert count(r, "tools/list") == 3 and count(r, "tools/call") == 0

    s2 = session(ctx, max_pages: 2)
    requests()
    assert {:ok, %{tools: tools, truncated: true}} = McpClient.list_tools(s2)
    assert Enum.map(tools, & &1["name"]) == ["echo", "fail", "strict"]
    assert count(requests(), "tools/list") == 2

    s3 = session(ctx, max_tools: 2)
    requests()
    assert {:ok, %{tools: tools, truncated: true}} = McpClient.list_tools(s3)
    assert length(tools) == 2
    assert count(requests(), "tools/call") == 0

    s4 = session(ctx, max_descriptor_bytes: 256)
    assert {:ok, %{tools: tools, truncated: true}} = McpClient.list_tools(s4)
    refute Enum.any?(tools, &(&1["name"] == "echo"))
  end

  ## call outcomes through the EffectIntent owner

  test "T3 a successful call completes once, the result reaches the recipient and the owner settles (EffectIntent owner + Adapter + loopback server)",
       ctx do
    s = session(ctx)
    snap = snapshot(s)
    requests()
    {:ok, a} = McpClient.admission(s.config, declaration(payload("echo", %{"x" => "hi"})), snap)
    pid = owner(s, a, ctx)

    assert {:completed, %{content: [%{"type" => "text", "text" => "echo:hi"}], is_error: false}} =
             McpClient.call_tool(s, a, pid)

    # call_tool/3 returns a completion only after the owner confirmed it.
    assert {:Confirmed, 1} = Intent.status(pid).phase
    status = settled(pid)
    assert {:Confirmed, 1} = status.phase
    r = requests()
    assert count(r, "tools/call") == 1 and count(r, "tools/list") == 0
    refute inspect(status, limit: :infinity) =~ "echo:hi"
  end

  test "T4 a tool-level error is completed with is_error true; structured content is carried (Adapter + loopback server)",
       ctx do
    s = session(ctx)
    snap = snapshot(s)
    {:ok, a} = McpClient.admission(s.config, declaration(payload("fail", %{})), snap)
    pid = owner(s, a, ctx)
    assert {:completed, %{is_error: true}} = McpClient.call_tool(s, a, pid)
    assert {:Confirmed, 1} = settled(pid).phase

    {:ok, a} =
      McpClient.admission(s.config, declaration(payload("structured", %{}), "call-2"), snap)

    pid = owner(s, a, ctx)

    assert {:completed, %{is_error: false, structured: %{"n" => 1}}} =
             McpClient.call_tool(s, a, pid)
  end

  test "T2 a prompt-injection description and readOnlyHint change nothing: the release reference is still required and the call is sent once (Adapter)",
       ctx do
    s = session(ctx)
    snap = snapshot(s)
    echo = Enum.find(snap.tools, &(&1["name"] == "echo"))
    assert echo["annotations"]["readOnlyHint"] == true
    assert echo["description"] =~ "IGNORE ALL PREVIOUS"
    requests()

    assert {:error, {:refused, :invalid_request}} =
             McpClient.admission(s.config, declaration(payload("echo", %{}, "")), snap)

    assert requests() == []
    {:ok, a} = McpClient.admission(s.config, declaration(payload("echo", %{"x" => "1"})), snap)
    pid = owner(s, a, ctx)
    assert {:completed, _} = McpClient.call_tool(s, a, pid)
    r = requests()
    assert count(r, "tools/call") == 1 and length(r) == 1
  end

  test "T8 a missing or malformed release reference is refused at admission: no intent, no request (admission)",
       ctx do
    s = session(ctx)
    snap = snapshot(s)
    requests()

    for bad <- ["", "has space", "new\nline", String.duplicate("r", 257), "semi;colon"] do
      assert {:error, {:refused, :invalid_request}} =
               McpClient.admission(s.config, declaration(payload("echo", %{}, bad)), snap)
    end

    no_release = Jason.encode!(%{"version" => 1, "tool" => "echo", "arguments" => %{}})

    assert {:error, {:refused, :invalid_request}} =
             McpClient.admission(s.config, declaration(no_release), snap)

    with_extra =
      Jason.encode!(%{
        "version" => 1,
        "tool" => "echo",
        "arguments" => %{},
        "release" => @release,
        "retry_safe" => true
      })

    assert {:error, {:refused, :invalid_request}} =
             McpClient.admission(s.config, declaration(with_extra), snap)

    assert requests() == []
  end

  test "T5 a tool absent from the snapshot is refused pre-send; a server -32602 after sending is unknown{server_error} (admission; Adapter)",
       ctx do
    s = session(ctx)
    snap = snapshot(s)
    requests()

    assert {:error, {:refused, :unknown_tool}} =
             McpClient.admission(s.config, declaration(payload("delete_everything", %{})), snap)

    assert requests() == []

    # The server's tool set changed after discovery: the call is sent and the
    # server's JSON-RPC error is unknown, never refused.
    assert {:error, :server_invalid_arguments, :mcp} =
             send_one(s, payload("delete_everything", %{}))

    assert count(requests(), "tools/call") == 1

    assert {:ok, {:unknown, {:server_error, :invalid_arguments}}} =
             McpClient.outcome(:server_invalid_arguments)

    assert {"unknown", "dispatched", "unclassified"} = Binding.failures().server_invalid_arguments
    refute :server_invalid_arguments in Binding.no_send()
  end

  test "T6 arguments that are not an object or fail the snapshot schema are refused pre-send (admission)",
       ctx do
    s = session(ctx)
    snap = snapshot(s)
    requests()

    for args <- [%{}, %{"x" => 1}, %{"x" => "a", "y" => 2}] do
      assert {:error, {:refused, :invalid_arguments}} =
               McpClient.admission(s.config, declaration(payload("strict", args)), snap)
    end

    not_object =
      Jason.encode!(%{"version" => 1, "tool" => "echo", "arguments" => [1], "release" => @release})

    assert {:error, {:refused, :invalid_arguments}} =
             McpClient.admission(s.config, declaration(not_object), snap)

    remote = %{
      tools: [
        %{"name" => "r", "input_schema" => %{"$ref" => "http://127.0.0.1:1/schema.json"}},
        %{"name" => "i", "input_schema" => %{"$id" => "http://x/", "type" => "object"}}
      ]
    }

    for t <- ["r", "i"] do
      assert {:error, {:refused, :invalid_arguments}} =
               McpClient.admission(s.config, declaration(payload(t, %{})), remote)
    end

    assert {:ok, _} =
             McpClient.admission(s.config, declaration(payload("strict", %{"x" => "a"})), snap)

    assert requests() == []
  end

  test "T7 too-large arguments are refused pre-send at admission and at send (admission; Adapter)",
       ctx do
    s = session(ctx, max_request_bytes: 512)
    snap = snapshot(s)
    requests()
    big = payload("echo", %{"x" => String.duplicate("x", 600)})
    assert {:error, {:refused, :too_large}} = McpClient.admission(s.config, declaration(big), snap)
    assert {:error, :too_large, :mcp} = send_one(s, big)
    assert requests() == []
    assert :too_large in Binding.no_send()
  end

  ## pinned settings and drift tests (exactly one tools/call per failure case)

  test "T9 401 with a Bearer challenge and 403 insufficient_scope are refused with exactly one tools/call and no authorization-server request (fail-closed auth provider)",
       ctx do
    s = session(ctx)
    requests()

    for {mode, _} <- [auth401: 401, auth403: 403] do
      Server.mode(ctx.server, mode)
      assert {:error, :authentication_failed, :mcp} = send_one(s, payload("echo", %{}))
      r = requests(400)
      assert count(r, "tools/call") == 1
      refute Enum.any?(r, &match?({{:path, _}, _, _}, &1))
      assert Enum.map(r, &elem(&1, 0)) == ["tools/call"]
    end

    assert {"failed", "dispatched", "permanent"} = Binding.failures().authentication_failed
    refute :authentication_failed in Binding.no_send()

    # Negative control (raw ex_mcp client, not the Adapter): without an auth
    # provider the same challenge starts ex_mcp's inline OAuth discovery.
    Server.mode(ctx.server, :pass)

    {:ok, raw} =
      ExMCP.Client.start_link(
        transport: :http,
        url: ctx.server.url,
        protocol_mode: :modern_only,
        reconnect: false,
        health_check_interval: nil,
        use_sse: false,
        headers: [{"authorization", "Bearer " <> @token}]
      )

    requests()
    Server.mode(ctx.server, :auth401)

    log =
      capture_log([level: :info], fn ->
        ExMCP.Client.make_request(
          raw,
          "tools/call",
          %{"name" => "echo", "arguments" => %{}},
          [timeout: 3_000] ++ Transport.call_options(),
          3_000
        )
      end)

    # ex_mcp starts its inline OAuth flow (it then stops only because this
    # loopback metadata URL is not https). Matches both its [info] start line and
    # its [warning] failure line, so the check holds at any configured log level.
    assert log =~ "Full OAuth flow" or log =~ "full OAuth flow"
    GenServer.stop(raw)
  end

  test "T11 a stalled server is unknown{timeout} with exactly one tools/call (Adapter call bound)",
       ctx do
    s = session(ctx, call_timeout_ms: 300)
    requests()
    Server.mode(ctx.server, {:stall, 1_500})
    assert {:error, :timeout, :mcp} = send_one(s, payload("echo", %{}))
    r = requests(1_600)
    assert count(r, "tools/call") == 1
    assert {"timed_out", "unknown", "retryable"} = Binding.failures().timeout
  end

  test "T12 a connection killed after the request was read is unknown{connection_lost} with exactly one tools/call, in both eras (http_stream_retry pin)",
       ctx do
    for mode <- [:modern_only, :legacy_only] do
      s = session(ctx, protocol_mode: mode)
      requests()
      Server.mode(ctx.server, :kill_connection)
      assert {:error, :connection_lost, :mcp} = send_one(s, payload("echo", %{}))
      r = requests(1_500)
      assert count(r, "tools/call") == 1
      Server.mode(ctx.server, :pass)
      McpClient.close(s)
      requests()
    end
  end

  test "T12b drift: on a broken request-owned response stream :safe_only returns outcome_unknown after one tools/call; the default :at_least_once reissues (raw ex_mcp client control)",
       ctx do
    {:ok, raw} =
      ExMCP.Client.start_link(
        transport: :http,
        url: ctx.server.url,
        protocol_mode: :modern_only,
        reconnect: false,
        health_check_interval: nil,
        use_sse: false
      )

    Server.mode(ctx.server, :kill_connection)
    requests()
    # A progress token opens a request-owned stream; the Adapter never sends one.
    params = %{"name" => "echo", "arguments" => %{}, "_meta" => %{"progressToken" => "p1"}}

    safe =
      ExMCP.Client.make_request(
        raw,
        "tools/call",
        params,
        [timeout: 4_000] ++ Transport.call_options(),
        4_000
      )

    assert count(requests(1_500), "tools/call") == 1
    assert {:CallLost, :ReplyBroken, nil} = Transport.classify(safe)

    ExMCP.Client.make_request(
      raw,
      "tools/call",
      params,
      [timeout: 4_000, http_stream_retry: :at_least_once, retry_policy: false, format: :map],
      4_000
    )

    assert count(requests(2_500), "tools/call") == 2
    GenServer.stop(raw)
  end

  test "T13 retry_policy false on every operation: a 503, a stalled response and a killed connection each see exactly one tools/call; the option lists are fixed (pins)",
       ctx do
    s = session(ctx, call_timeout_ms: 400)
    requests()

    for mode <- [:s503, {:stall, 900}, :kill_connection] do
      Server.mode(ctx.server, mode)
      assert {:error, tag, :mcp} = send_one(s, payload("echo", %{}))
      assert {:ok, {:unknown, _}} = McpClient.outcome(tag)
      assert count(requests(1_200), "tools/call") == 1
    end

    assert Transport.call_options()[:retry_policy] == false
    assert Transport.call_options()[:http_stream_retry] == :safe_only
    assert Transport.call_options()[:max_mrtr_rounds] == 0
    refute Keyword.has_key?(Transport.call_options(), :retry_safe)
    assert Transport.list_options()[:retry_policy] == false
    assert Transport.list_options()[:http_stream_retry] == :safe_only
  end

  test "T13b drift: ex_mcp's generic retry reissues tools/call on a retryable transport error when a retry policy is configured; the Adapter's retry_policy false sends exactly one (raw ex_mcp client control)",
       ctx do
    # The async POST path (legacy era with a standalone GET stream, which the
    # Adapter never opens) reports a killed connection as a retryable transport error.
    Server.get_mode(ctx.server, :idle)

    {:ok, raw} =
      ExMCP.Client.start_link(
        transport: :http,
        url: ctx.server.url,
        protocol_mode: :legacy_only,
        reconnect: false,
        health_check_interval: nil,
        use_sse: true
      )

    Process.sleep(200)
    requests()
    Server.mode(ctx.server, :kill_connection)
    params = %{"name" => "echo", "arguments" => %{}}
    policy = [max_attempts: 2, initial_delay: 10, jitter: false]

    retried =
      ExMCP.Client.make_request(
        raw,
        "tools/call",
        params,
        [timeout: 8_000, retry_policy: policy] ++
          Keyword.delete(Transport.call_options(), :retry_policy),
        8_000
      )

    assert count(requests(2_500), "tools/call") == 2, inspect(retried)

    once =
      ExMCP.Client.make_request(
        raw,
        "tools/call",
        params,
        [timeout: 8_000] ++ Transport.call_options(),
        8_000
      )

    assert count(requests(2_500), "tools/call") == 1, inspect(once)
    GenServer.stop(raw)
  end

  test "T14 a -32020 header mismatch is unknown{server_error} with exactly one tools/call and no refresh tools/list; ExMCP.Client.call_tool/4 would resend (drift test)",
       ctx do
    s = session(ctx)
    requests()

    for {code, tag} <- [
          {-32020, :server_protocol_error},
          {-32601, :server_protocol_error},
          {-32600, :server_invalid_request},
          {-32700, :server_invalid_request},
          {-32602, :server_invalid_arguments},
          {-32603, :server_error},
          {-1, :server_error}
        ] do
      Server.mode(ctx.server, {:rpc, code})
      assert {:error, ^tag, :mcp} = send_one(s, payload("echo", %{}))
      r = requests()
      assert count(r, "tools/call") == 1 and count(r, "tools/list") == 0
      assert {:ok, {:unknown, {:server_error, _}}} = McpClient.outcome(tag)
    end

    Server.mode(ctx.server, {:rpc, -32020})
    ExMCP.Client.call_tool(s.client, "echo", %{}, timeout: 3_000, retry_policy: false)
    r = requests(500)
    assert count(r, "tools/call") == 2 and count(r, "tools/list") >= 1
  end

  test "T15 input_required is unknown{input_required} with exactly one tools/call (max_mrtr_rounds pin)",
       ctx do
    s = session(ctx)
    requests()
    Server.mode(ctx.server, :input_required)
    assert {:error, :input_required, :mcp} = send_one(s, payload("echo", %{}))
    assert count(requests(), "tools/call") == 1
    assert {"unknown", "dispatched", "unclassified"} = Binding.failures().input_required
  end

  test "T16b malformed and oversize responses are unknown{malformed_response} (Adapter; max_response_bytes)",
       ctx do
    s = session(ctx, max_response_bytes: 2_048)
    requests()

    for mode <- [:garbage, {:large, 10_000}, :no_result_type] do
      Server.mode(ctx.server, mode)
      assert {:error, :malformed_response, :mcp} = send_one(s, payload("echo", %{}))
      assert count(requests(), "tools/call") == 1
    end
  end

  test "T10 no reconnect and no health ping after an idle period or a dropped connection; a control client with a ping interval pings (pins)",
       ctx do
    s = session(ctx, protocol_mode: :legacy_only)
    requests()
    Process.sleep(800)
    Server.mode(ctx.server, :kill_connection)
    assert {:error, :connection_lost, :mcp} = send_one(s, payload("echo", %{}))
    Process.sleep(1_000)
    r = requests(300)
    assert Enum.map(r, &elem(&1, 0)) -- ["tools/call", "notifications/cancelled"] == []
    state = :sys.get_state(s.client)
    assert state.reconnect_enabled == false and state.health_check_interval == nil

    assert count(r, {:http, "GET"}) == 0

    # Control (raw client): with a standalone GET stream and a ping interval the
    # client pings; the Adapter pins use_sse: false and health_check_interval: nil.
    Server.mode(ctx.server, :pass)
    Server.get_mode(ctx.server, :idle)

    {:ok, control} =
      ExMCP.Client.start_link(
        transport: :http,
        url: ctx.server.url,
        protocol_mode: :legacy_only,
        reconnect: false,
        health_check_interval: 100,
        use_sse: true
      )

    Process.sleep(800)
    GenServer.stop(control)
    assert count(requests(), "ping") >= 1
  end

  test "T16 the same identity is never sent twice: the second dispatch is refused by the owner and re-admission recovers the same key (EffectIntent)",
       ctx do
    s = session(ctx)
    snap = snapshot(s)
    {:ok, a} = McpClient.admission(s.config, declaration(payload("echo", %{"x" => "1"})), snap)
    pid = owner(s, a, ctx)
    requests()
    assert {:completed, _} = McpClient.call_tool(s, a, pid)
    settled(pid)
    assert {:error, {:intent, :refused}} = McpClient.call_tool(s, a, pid)
    {:ok, a2} = McpClient.admission(s.config, declaration(payload("echo", %{"x" => "1"})), snap)
    assert a2.key == a.key
    assert count(requests(), "tools/call") == 1

    # An unknown outcome is not rearmed either.
    Server.mode(ctx.server, {:rpc, -32603})

    {:ok, b} =
      McpClient.admission(s.config, declaration(payload("echo", %{}), "call-unknown"), snap)

    pid = owner(s, b, ctx)
    assert {:unknown, {:server_error, :other}} = McpClient.call_tool(s, b, pid)
    settled(pid)
    assert {:error, _} = Intent.advance(pid, :rearm)
    assert {:error, {:intent, :refused}} = McpClient.call_tool(s, b, pid)
    assert count(requests(), "tools/call") == 1
  end

  test "T17 server-initiated sampling, elicitation, roots and custom requests are refused or never answered; ping gets an empty result; no path or credential disclosed (no handler; refusing handler)",
       ctx do
    # Adapter path (legacy, use_sse: false): requests inside the tool call's
    # response stream are dropped by ex_mcp without any answer; the call completes.
    s = session(ctx, protocol_mode: :legacy_only)
    requests()
    Server.mode(ctx.server, :server_requests)
    assert %{"outcome" => "completed"} = send_one(s, payload("echo", %{}))
    r = requests(800)
    assert Enum.map(r, &elem(&1, 0)) == ["tools/call"]
    flush_results()

    # Where requests do reach a client (a standalone GET stream, which the
    # Adapter never opens), the Adapter's settings (no handler, no capabilities)
    # answer every data-bearing method with an error and ping with {}; so does a
    # refusing handler. Raw ex_mcp clients with the Adapter's option list plus
    # use_sse: true.
    Server.mode(ctx.server, :pass)
    Server.get_mode(ctx.server, :requests)
    base = Keyword.put(Transport.client_options(s.config), :use_sse, true)

    for opts <- [base, base ++ [handler: Elzoo.McpClientTest.RefusingHandler]] do
      requests()
      {:ok, raw} = ExMCP.Client.start_link(opts)
      r = requests(1_200)
      answers = for {:response, _, body} <- r, into: %{}, do: {body["id"], body}

      for id <- ["s-roots", "s-sampling", "s-elicit", "s-custom"] do
        assert %{"error" => %{"code" => _}} = answers[id], inspect(answers)
        refute Map.has_key?(answers[id], "result")
      end

      assert %{"result" => %{}} = answers["s-ping"]
      assert map_size(answers["s-ping"]["result"]) == 0
      text = inspect(answers, limit: :infinity, printable_limit: :infinity)
      refute text =~ File.cwd!()
      refute text =~ @token
      GenServer.stop(raw)
    end
  end

  ## credentials and redaction

  test "T27 a server that echoes the bearer token gets it redacted from the delivered result, its digest and discovery (Adapter redaction)",
       ctx do
    s = session(ctx)
    snap = snapshot(s)
    {:ok, a} = McpClient.admission(s.config, declaration(payload("echo", %{})), snap)
    pid = owner(s, a, ctx)
    Server.mode(ctx.server, :echo_auth)
    assert {:completed, value} = McpClient.call_tool(s, a, pid)
    refute_token(value)
    assert [%{"text" => "you sent: Bearer [redacted] "}] = value.content

    assert value.structured == %{
             "token" => "[redacted]",
             "[redacted]" => ["x[redacted]y"],
             "old" => ""
           }

    refute_token(Intent.status(pid))
    assert count(requests(), "tools/call") == 1

    result = send_one(s, payload("echo", %{}))
    refute_token(result)
    flush_results()
  end

  test "T28 a credential that rotates between resolutions: neither the earlier nor the sent token reaches delivered data, digest, status or discovery (Adapter redaction)",
       ctx do
    old = "tok-OLD-SECRET-11aa-0123456789"
    sent = "tok-NEW-SECRET-22bb-0123456789"
    {:ok, queue} = Agent.start_link(fn -> [] end)

    need = fn ->
      case Agent.get_and_update(queue, fn
             [h | t] -> {h, t}
             [] -> {nil, []}
           end) do
        nil -> {:ok, sent}
        t -> {:ok, t}
      end
    end

    s = session(ctx, credentials: need)
    snap = snapshot(s)
    {:ok, a} = McpClient.admission(s.config, declaration(payload("echo", %{})), snap)
    pid = owner(s, a, ctx)
    requests()

    # The Adapter's pre-call resolution sees the earlier token; ex_mcp's provider
    # and the post-call resolution see the new one, which the server echoes; the
    # server also echoes the earlier token it saw before.
    Server.mode(ctx.server, {:echo_auth, old})
    Agent.update(queue, fn _ -> [old] end)
    assert {:completed, value} = McpClient.call_tool(s, a, pid)
    status = Intent.status(pid)

    for t <- [old, sent], term <- [value, status] do
      refute inspect(term, limit: :infinity, printable_limit: :infinity) =~ t
    end

    assert value.structured["old"] == "[redacted]" and value.structured["token"] == "[redacted]"

    Server.mode(ctx.server, {:echo_list, old})
    Agent.update(queue, fn _ -> [old] end)
    assert {:ok, d} = McpClient.list_tools(s)
    text = inspect(d, limit: :infinity, printable_limit: :infinity)
    refute text =~ old
    refute text =~ sent
    assert [%{"name" => "echo", "trust" => "untrusted", "input_schema" => schema} | _] = d.tools
    assert Map.keys(schema["properties"]) == ["[redacted]"]
    Server.mode(ctx.server, :pass)
  end

  test "T29 the credential rule: shorter than 24 bytes, or a substring of an Adapter-emitted fixed string or of the binding's configured strings, is refused credentials_unavailable before any send (amendment 3)",
       ctx do
    long_server = "elzoo-test-server-identity-0001"
    binding = Server.binding(ctx.server.url, :loopback, long_server)

    refused = [
      "name",
      String.duplicate("a", 23),
      "Elzoo.McpClient.Credential",
      "server_invalid_arguments",
      long_server,
      "server-identity-0001"
    ]

    configured = Elzoo.McpClient.Credential.configured(config(ctx, binding: binding))

    for t <- [
          "Elzoo.McpClient.Credential",
          "server_invalid_arguments",
          long_server,
          "x" <> String.duplicate("y", 22)
        ] do
      refute Elzoo.McpClient.Credential.acceptable?(t, configured), t
    end

    assert Elzoo.McpClient.Credential.acceptable?(@token, configured)

    for word <- refused do
      requests()

      assert {:error, :credentials_unavailable} =
               McpClient.connect(
                 config(ctx, binding: binding, credentials: fn -> {:ok, word} end),
                 ctx.sup
               )

      assert Enum.all?(requests(), fn {_, auth?, _} -> not auth? end)
    end

    # The same Need turning into a refused value after connect: refused at the call.
    {:ok, flag} = Agent.start_link(fn -> @token end)
    s = session(ctx, credentials: fn -> {:ok, Agent.get(flag, & &1)} end)
    requests()
    Agent.update(flag, fn _ -> "Elixir.Elzoo.McpClient.Adapter" end)
    assert {:error, :credentials_unavailable, :mcp} = send_one(s, payload("echo", %{}))
    assert requests() == []
  end

  test "T32 the fixed-string list covers every literal of at least 24 bytes in the Piece's compiled modules (enumerated from the compiled source)" do
    app = Application.get_application(Elzoo.McpClient)
    {:ok, modules} = :application.get_key(app, :modules)
    mods = Enum.filter(modules, &String.contains?(Atom.to_string(&1), "Elzoo.McpClient"))
    assert Elzoo.McpClient.Credential in mods

    literals =
      Enum.reduce(mods, MapSet.new(), fn m, acc ->
        acc = MapSet.put(acc, Atom.to_string(m))

        with {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} <-
               :beam_lib.chunks(:code.which(m), [:debug_info]),
             {:ok, %{definitions: defs}} <- backend.debug_info(:elixir_v1, m, data, []) do
          collect(defs, acc)
        else
          _ -> acc
        end
      end)

    emitted =
      literals
      |> Enum.filter(&(byte_size(&1) >= 24 and String.printable?(&1)))
      # file paths that macros of upstream modules inline (never emitted)
      |> Enum.reject(&String.starts_with?(&1, "/"))

    missing = emitted -- Elzoo.McpClient.Credential.fixed()
    assert missing == [], "add to Credential.fixed/0: #{inspect(missing)}"
  end

  defp collect(b, acc) when is_binary(b), do: MapSet.put(acc, b)
  defp collect(a, acc) when is_atom(a), do: MapSet.put(acc, Atom.to_string(a))
  defp collect(t, acc) when is_tuple(t), do: collect(Tuple.to_list(t), acc)
  defp collect(l, acc) when is_list(l), do: Enum.reduce(l, acc, &collect/2)
  defp collect(m, acc) when is_map(m), do: collect(Map.to_list(m), acc)
  defp collect(_, acc), do: acc

  test "T33 the ledger never yields a token through a public API, inspect or :sys status, and stops when the client exits normally (ledger)",
       ctx do
    s = session(ctx)
    {:ok, _} = McpClient.list_tools(s)
    exported = Elzoo.McpClient.Ledger.__info__(:functions) |> Keyword.keys()
    refute :tokens in exported
    refute_token(inspect(s))
    refute_token(:sys.get_status(s.ledger))
    refute_token(:sys.get_state(s.ledger))
    refute_token(s)
    %{table: table} = :sys.get_state(s.ledger)
    assert_raise ArgumentError, fn -> :ets.tab2list(table) end

    # Crash reports: the last message (e.g. {:record, token}) and the log are redacted too.
    status = %{state: :x, message: {:record, @token}, log: [{:record, @token}], reason: :boom}
    formatted = Elzoo.McpClient.Ledger.format_status(status)
    assert %{state: :redacted, message: :redacted, log: :redacted} = formatted
    refute_token(formatted)

    assert {:ok, "x [redacted] y"} =
             Elzoo.McpClient.Ledger.redact(s.ledger, "x " <> @token <> " y", [])

    ledger = s.ledger
    ref = Process.monitor(ledger)
    GenServer.stop(s.client, :normal)
    assert_receive {:DOWN, ^ref, :process, ^ledger, _}, 2_000
    assert {:error, :adapter_error, :mcp} = send_one(s, payload("echo", %{})) |> then(&normalize/1)
  end

  # After the client is gone the call is refused before any byte (not_connected);
  # either way no unredacted content can leave.
  defp normalize({:error, :not_connected, :mcp}), do: {:error, :adapter_error, :mcp}
  defp normalize(other), do: other

  test "T30 two rotations within one call and a failing post-call resolution: every token ex_mcp sent is redacted (ledger)",
       ctx do
    {:ok, n} = Agent.start_link(fn -> 0 end)
    {:ok, fail_after} = Agent.start_link(fn -> :infinity end)

    need = fn ->
      i = Agent.get_and_update(n, &{&1, &1 + 1})

      if i >= Agent.get(fail_after, & &1),
        do: raise("gone"),
        else: {:ok, "tok-ROT-#{i}-zz-0123456789abcdef"}
    end

    s = session(ctx, credentials: need)
    snap = snapshot(s)
    {:ok, a} = McpClient.admission(s.config, declaration(payload("echo", %{})), snap)
    pid = owner(s, a, ctx)
    # Pre-call resolution, the provider's token (sent and echoed) and the post-call
    # resolution are three different tokens; the server also echoes an older one.
    Server.mode(ctx.server, {:echo_auth, "tok-ROT-0-zz-0123456789abcdef"})
    assert {:completed, value} = McpClient.call_tool(s, a, pid)
    text = inspect({value, Intent.status(pid)}, limit: :infinity, printable_limit: :infinity)
    refute text =~ "tok-ROT-"
    assert value.structured["token"] == "[redacted]"

    # Post-call resolution fails: the token the provider sent is still redacted.
    {:ok, b} = McpClient.admission(s.config, declaration(payload("echo", %{}), "call-2"), snap)
    pid = owner(s, b, ctx)
    Agent.update(fail_after, fn _ -> Agent.get(n, & &1) + 2 end)
    assert {:completed, value} = McpClient.call_tool(s, b, pid)
    refute inspect(value, limit: :infinity, printable_limit: :infinity) =~ "tok-ROT-"
    Server.mode(ctx.server, :pass)
  end

  test "T31 a multi-page listing whose credential rotates on every page: every sent token is redacted from every descriptor (ledger)",
       ctx do
    {:ok, n} = Agent.start_link(fn -> 0 end)
    need = fn -> {:ok, "tok-PAGE-#{Agent.get_and_update(n, &{&1, &1 + 1})}-qq-0123456789abcd"} end
    s = session(ctx, credentials: need)
    Server.mode(ctx.server, {:echo_list, "tok-PAGE-0-qq-0123456789abcd"})
    assert {:ok, d} = McpClient.list_tools(s)
    assert Enum.map(d.tools, & &1["name"]) == ["echo", "echo2", "echo3"]
    refute inspect(d, limit: :infinity, printable_limit: :infinity) =~ "tok-PAGE-"
    assert count(requests(), "tools/list") == 3
    Server.mode(ctx.server, :pass)
  end

  test "T19 every failing, raising, throwing, exiting or malformed credential Need is credentials_unavailable with no tool request (auth provider)",
       ctx do
    needs = [
      fn -> {:error, @token} end,
      fn -> raise "boom " <> @token end,
      fn -> throw(@token) end,
      fn -> exit(@token) end,
      fn -> {:ok, :atom} end,
      fn -> {:ok, ""} end,
      fn -> {:ok, String.duplicate("a", 4097)} end,
      fn -> {:ok, @token <> "\r\nX: y"} end,
      fn -> {:ok, "=" <> @token} end,
      fn -> {:ok, {@token, @token}} end,
      fn -> @token end
    ]

    for need <- needs do
      assert :error = AuthProvider.token(need)
    end

    # At connect: the handshake carries no token and connect fails closed.
    requests()

    log =
      capture_log([level: :debug], fn ->
        assert {:error, :credentials_unavailable} =
                 McpClient.connect(config(ctx, credentials: hd(needs)), ctx.sup)
      end)

    refute_token(log)
    assert Enum.all?(requests(), fn {_, auth?, _} -> not auth? end)

    # At call time: the Need starts failing after connect.
    {:ok, flag} = Agent.start_link(fn -> true end)
    need = fn -> if Agent.get(flag, & &1), do: {:ok, @token}, else: raise("gone " <> @token) end
    s = session(ctx, credentials: need)
    requests()
    Agent.update(flag, fn _ -> false end)
    result = send_one(s, payload("echo", %{}))
    assert {:error, :credentials_unavailable, :mcp} = result
    assert requests() == []
    assert :credentials_unavailable in Binding.no_send()
    refute_token(result)
  end

  test "T18 the credential never appears in results, errors, inspect values, captured logs at :debug or ex_mcp telemetry seen in these scenarios (redaction)",
       ctx do
    parent = self()
    handler = "elzoo-mcp-client-test-#{System.unique_integer([:positive])}"

    events = [
      [:ex_mcp, :client, :request, :sent],
      [:ex_mcp, :client, :http, :request, :retry],
      [:ex_mcp, :transport, :connection, :opened],
      [:ex_mcp, :client, :mrtr, :failure]
    ]

    :telemetry.attach_many(
      handler,
      events,
      fn e, m, md, _ -> send(parent, {:telemetry, e, m, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      capture_log([level: :debug], fn ->
        s = session(ctx)
        snap = snapshot(s)
        refute_token(snap)
        refute_token(inspect(s))
        refute_token(inspect(s.config))
        refute_token(inspect(McpClient.context(s, self())))
        refute_token(:sys.get_state(s.client))
        {:ok, a} = McpClient.admission(s.config, declaration(payload("echo", %{})), snap)
        pid = owner(s, a, ctx)
        out = McpClient.call_tool(s, a, pid)
        refute_token(out)
        refute_token(settled(pid))

        for mode <- [:auth401, {:rpc, -32603}, :garbage, :input_required] do
          Server.mode(ctx.server, mode)
          refute_token(send_one(s, payload("echo", %{})))
        end

        Server.mode(ctx.server, :pass)
        McpClient.close(s)
      end)

    refute_token(log)

    seen =
      Stream.repeatedly(fn ->
        receive do
          {:telemetry, e, m, md} -> {e, m, md}
        after
          100 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    assert seen != []
    refute_token(seen)
  end

  ## result delivery, configuration, sessions

  test "T25 result delivery is best-effort: a live recipient receives the outcome; after the recipient exits the owner still settles completed and keeps no content (context)",
       ctx do
    s = session(ctx)
    snap = snapshot(s)
    {:ok, a} = McpClient.admission(s.config, declaration(payload("echo", %{"x" => "q"})), snap)
    recipient = spawn(fn -> :ok end)
    ref = Process.monitor(recipient)
    assert_receive {:DOWN, ^ref, _, _, _}
    pid = owner(s, a, ctx, recipient)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    assert {:Confirmed, 1} = status.phase
    refute inspect(status, limit: :infinity) =~ "echo:q"
    refute_received {:elzoo_mcp_result, _, _, _}

    {:ok, b} =
      McpClient.admission(s.config, declaration(payload("echo", %{"x" => "w"}), "call-2"), snap)

    pid = owner(s, b, ctx)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    key = b.key

    assert_receive {:elzoo_mcp_result, ^key, _, {:completed, %{content: [%{"text" => "echo:w"}]}}},
                   5_000

    flush_results()
  end

  test "T22 close during an in-flight call is unknown; a call after close is refused not_connected, attested no-send (session)",
       ctx do
    s = session(ctx)
    requests()
    Server.mode(ctx.server, {:stall, 1_500})
    task = Task.async(fn -> send_one(s, payload("echo", %{})) end)
    Process.sleep(200)
    McpClient.close(s)
    assert {:error, tag, :mcp} = Task.await(task, 5_000)
    assert {:ok, {:unknown, _}} = McpClient.outcome(tag)
    Server.mode(ctx.server, :pass)
    requests(1_600)
    assert {:error, :not_connected, :mcp} = send_one(s, payload("echo", %{}))
    assert requests() == []
    assert :not_connected in Binding.no_send()
  end

  test "T20 configuration: allowlist and network policy at construction; bounds checked; the credential Need is never called by configure (configure; Binding)",
       ctx do
    called = :counters.new(1, [])
    need = fn -> :counters.add(called, 1, 1) && {:ok, @token} end
    b = Server.binding(ctx.server.url)
    base = [binding: b, tenant: "t", credentials: need]
    assert {:ok, _} = McpClient.configure(base)

    for bad <- [
          max_request_bytes: 65_537,
          max_request_bytes: 0,
          max_response_bytes: 8_388_609,
          max_pages: 0,
          max_pages: 65,
          max_tools: 1_025,
          max_descriptor_bytes: 255,
          call_timeout_ms: 0,
          protocol_mode: :legacy_with_fallback,
          handler: Elzoo.McpClientTest.RefusingHandler,
          retry_policy: [max_attempts: 3]
        ] do
      assert {:error, :configuration} = McpClient.configure(base ++ [bad])
    end

    assert {:error, :configuration} = McpClient.configure(Keyword.put(base, :tenant, ""))
    assert {:error, :configuration} = McpClient.configure(Keyword.put(base, :credentials, @token))
    assert :counters.get(called, 1) == 0

    for {url, network} <- [
          {"http://example.test/mcp", :loopback},
          {"http://10.0.0.5/mcp", :private},
          {"http://mcp.example.test/mcp", :public},
          {"https://127.0.0.1/mcp", :public},
          {"https://user:pw@mcp.example.test/mcp", :public},
          {"https://mcp.example.test/mcp?x=1", :public},
          {"https://mcp.example.test/mcp#f", :public},
          {"ftp://127.0.0.1/mcp", :loopback}
        ] do
      assert_raise ArgumentError, fn -> Server.binding(url, network) end
    end

    assert Server.binding("https://mcp.example.test/mcp", :public)
    assert Server.binding("http://localhost:#{ctx.server.port}/mcp", :loopback)

    # The allowlisted endpoint and policy enter the intent key.
    other = Server.binding("http://localhost:#{ctx.server.port}/mcp", :loopback)
    {:ok, b1, _} = Binding.load(b)
    {:ok, b2, _} = Binding.load(other)
    assert b1.provider_account != b2.provider_account

    # Options for non-loopback policies pin the exact origin; no caller resolver.
    {:ok, pc} =
      McpClient.configure(
        binding: Server.binding("https://mcp.internal.test:8443/mcp", :private),
        tenant: "t",
        credentials: need
      )

    opts = Transport.client_options(pc)
    assert opts[:allowed_private_hosts] == ["mcp.internal.test"]
    assert opts[:security] == %{trusted_origins: ["https://mcp.internal.test:8443"]}

    for k <- [:handler, :capabilities, :retry_policy, :auth, :conformance_mode, :dns_resolver],
        do: refute(Keyword.has_key?(opts, k))

    assert opts[:reconnect] == false and opts[:health_check_interval] == nil and
             opts[:use_sse] == false

    # Under the loopback policy a name that does not resolve to loopback is refused
    # before any byte (ex_mcp target policy).
    {:ok, lc} =
      McpClient.configure(
        binding: Server.binding("http://localhost:#{ctx.server.port}/mcp", :loopback),
        tenant: "t",
        credentials: fn -> {:ok, @token} end
      )

    assert {:ok, s} = McpClient.connect(lc, ctx.sup)
    McpClient.close(s)
  end

  test "T21 a forged completion without the process-local seal does not settle; the Cure decision and the binding agree for every row (EffectIntent observe; Cure classify)",
       ctx do
    s = session(ctx)
    {:ok, b, _} = Binding.load(s.config.binding)
    assert Enum.sort(Adapter.failure_tags()) == Enum.sort(Map.keys(Binding.failures()))

    forged = %{
      "attempt_id" => "attempt-1",
      "value" => %{
        "digest" => String.duplicate("0", 64),
        "is_error" => false,
        "seal" => String.duplicate("1", 64)
      }
    }

    assert :error = Adapter.authenticate(forged, request(s, payload("echo", %{})))

    good = send_one(s, payload("echo", %{}))
    assert :ok = Adapter.validate_result(good, request(s, payload("echo", %{})))
    assert :ok = Adapter.authenticate(good, request(s, payload("echo", %{})))
    flush_results()

    rows = [
      {:CallWire, :ReplyResult, :completed},
      {:CallPre, :ReplyUnknownTool, :unknown_tool},
      {:CallPre, :ReplyBadArguments, :invalid_arguments},
      {:CallPre, :ReplyOversize, :too_large},
      {:CallPre, :ReplyNotConnected, :not_connected},
      {:CallUnsent, :ReplyOversize, :too_large},
      {:CallUnsent, :ReplyCredentialFault, :credentials_unavailable},
      {:CallUnsent, :ReplyNotConnected, :not_connected},
      {:CallUnsent, :ReplyTargetRefused, :target_refused},
      {:CallUnsent, :ReplyMalformed, :adapter_error},
      {:CallWire, :ReplyAuthRefused, :authentication_failed},
      {:CallWire, {:ReplyRpcError, 32602}, :server_invalid_arguments},
      {:CallWire, {:ReplyRpcError, 32600}, :server_invalid_request},
      {:CallWire, {:ReplyRpcError, 32700}, :server_invalid_request},
      {:CallWire, {:ReplyRpcError, 32601}, :server_protocol_error},
      {:CallWire, {:ReplyRpcError, 32020}, :server_protocol_error},
      {:CallWire, {:ReplyRpcError, 32603}, :server_error},
      {:CallWire, :ReplyHttpStatus, :server_error},
      {:CallWire, :ReplyInputRequired, :input_required},
      {:CallWire, :ReplyMalformed, :malformed_response},
      {:CallWire, :ReplyTimeout, :malformed_response},
      {:CallLost, :ReplyTimeout, :timeout},
      {:CallLost, :ReplyBroken, :connection_lost},
      {:CallLost, :ReplyResult, :connection_lost},
      {:CallCrashed, :ReplyResult, :adapter_error}
    ]

    for {stage, reply, tag} <- rows do
      assert Elzoo.McpClient.Outcome.classify(stage, reply) == tag, inspect({stage, reply})
    end

    # Every wire or lost stage is never a not-dispatched (attested) tag.
    for {stage, _, tag} <- rows, stage in [:CallWire, :CallLost], tag != :completed do
      refute tag in Binding.no_send()
      {_, dispatch, _} = Binding.failures()[tag]
      assert dispatch in ["dispatched", "unknown"]
    end

    for tag <- Binding.no_send() do
      {_, "not_dispatched", _} = Binding.failures()[tag]
      assert {:ok, {:refused, _}} = McpClient.outcome(tag)
    end

    assert b.replay == :none
  end

  test "T23 interop: discovery and one call against ex_mcp's own server in the legacy era (upstream server)",
       ctx do
    s = session(ctx, protocol_mode: :legacy_only)
    snap = snapshot(s)
    assert length(snap.tools) == 4 and snap.protocol_version == "2025-11-25"
    {:ok, a} = McpClient.admission(s.config, declaration(payload("echo", %{"x" => "l"})), snap)
    pid = owner(s, a, ctx)
    assert {:completed, %{content: [%{"text" => "echo:l"}]}} = McpClient.call_tool(s, a, pid)
  end

  ## runtime endpoint mode (ELZ-282)

  defp runtime_config(_ctx, runtime, opts \\ []) do
    McpClient.configure(
      [
        binding: RuntimeBinding,
        runtime: runtime,
        tenant: "tenant-a",
        credentials: Keyword.get(opts, :credentials, fn -> {:ok, @token} end)
      ] ++ Keyword.drop(opts, [:credentials])
    )
  end

  defp runtime_session(ctx, runtime, opts \\ []) do
    {:ok, c} = runtime_config(ctx, runtime, opts)
    {:ok, s} = McpClient.connect(c, ctx.sup)
    on_exit(fn -> McpClient.close(s) end)
    s
  end

  # The Contract's digest, derived here from its text: "rt1:" and the lowercase
  # hex SHA-256 of the length-framed server, endpoint and ref.
  defp rt_digest(server, endpoint, ref) do
    framed =
      <<byte_size(server)::32, server::binary, byte_size(endpoint)::32, endpoint::binary,
        byte_size(ref)::32, ref::binary>>

    "rt1:" <> Base.encode16(:crypto.hash(:sha256, framed), case: :lower)
  end

  test "R1 runtime mode on the loopback server: connect, list_tools, one tools/call through the owner; outcomes equal the build-time path (RuntimeBinding)",
       ctx do
    {:ok, rb} = Elzoo.EffectIntent.Binding.load(RuntimeBinding)
    {:ok, bb, _} = Binding.load(Server.binding(ctx.server.url))
    assert rb.provider_account == "mcp:runtime" and rb.id != bb.id
    assert rb.failures == bb.failures and rb.no_send_attestations == bb.no_send_attestations
    refute function_exported?(RuntimeBinding, :__mcp_client_binding__, 0)

    s = runtime_session(ctx, runtime(ctx))
    assert Enum.map(requests(), &elem(&1, 0)) == ["server/discover"]
    snap = snapshot(s)
    assert snap.server == "elzoo-runtime-server"
    assert Enum.map(snap.tools, & &1["name"]) == ["echo", "fail", "strict", "structured"]
    requests()

    {:ok, a} = McpClient.admission(s.config, declaration(payload("echo", %{"x" => "rt"})), snap)
    assert [_, "mcp:runtime", id, "tools/call", _] = a.identity
    assert id == rb.id
    pid = owner(s, a, ctx)

    assert {:completed, %{content: [%{"text" => "echo:rt"}], is_error: false}} =
             McpClient.call_tool(s, a, pid)

    assert {:Confirmed, 1} = settled(pid).phase
    assert count(requests(), "tools/call") == 1

    # The same scripted answers give the same tag on both paths.
    b = session(ctx)
    requests()

    for mode <- [
          :auth401,
          :auth403,
          {:rpc, -32602},
          {:rpc, -32603},
          :input_required,
          :garbage,
          :s503
        ] do
      Server.mode(ctx.server, mode)
      build = send_one(b, payload("echo", %{}))
      run = send_one(s, payload("echo", %{}))
      assert build == run, inspect(mode)
      assert {:error, _, :mcp} = run
      assert count(requests(400), "tools/call") == 2
      flush_results()
    end

    Server.mode(ctx.server, :pass)
    assert %{"outcome" => "completed"} = send_one(s, payload("fail", %{}))
    assert send_one(s, "{}") == send_one(b, "{}")
    flush_results()
    McpClient.close(s)
    McpClient.close(b)
    requests()
    assert {:error, :not_connected, :mcp} = send_one(s, payload("echo", %{}))
    assert {:error, :not_connected, :mcp} = send_one(b, payload("echo", %{}))
    assert requests() == []
  end

  test "R2 runtime identity: five texts, a 68-byte rt1 digest of server, endpoint and ref; distinct keys; the owner accepts the longest inputs (admission)",
       ctx do
    snap = %{
      server: "x",
      protocol_version: nil,
      truncated: false,
      tools: [
        %{"trust" => "untrusted", "name" => "echo", "input_schema" => %{"type" => "object"}}
      ]
    }

    admit = fn rt, ref ->
      {:ok, c} = runtime_config(ctx, rt)
      {:ok, a} = McpClient.admission(c, declaration(payload("echo", %{}), ref), snap)
      {c, a}
    end

    base = runtime(ctx)
    {_, a1} = admit.(base, "call-1")
    {_, a2} = admit.(%{base | server: "elzoo-runtime-server-2"}, "call-1")
    {_, a3} = admit.(%{base | endpoint: "http://localhost:#{ctx.server.port}/mcp"}, "call-1")
    assert length(Enum.uniq([a1.key, a2.key, a3.key])) == 3

    assert a1.identity == [
             "tenant-a",
             "mcp:runtime",
             "mcp-client-runtime",
             "tools/call",
             rt_digest("elzoo-runtime-server", ctx.server.url, "call-1")
           ]

    assert Elzoo.EffectIntent.Model.valid_identity?(a1.identity)
    assert byte_size(List.last(a1.identity)) == 68

    # Build-time identity is unchanged: the raw ref.
    s = session(ctx)
    {:ok, ab} = McpClient.admission(s.config, declaration(payload("echo", %{})), snapshot(s))
    assert List.last(ab.identity) == "call-1"

    prefix = "http://127.0.0.1:#{ctx.server.port}/"
    long = prefix <> String.duplicate("p", 512 - byte_size(prefix))
    ref = String.duplicate("r", 256)
    assert byte_size(long) == 512
    {c, a} = admit.(%{base | endpoint: long}, ref)
    assert List.last(a.identity) == rt_digest("elzoo-runtime-server", long, ref)
    assert byte_size(List.last(a.identity)) == 68
    assert Elzoo.EffectIntent.Model.valid_identity?(a.identity)
    pid = owner(%Elzoo.McpClient.Session{config: c, client: nil, ledger: nil}, a, ctx)
    # The owner committed the admission: active, not halted, a recorded phase.
    assert %{active: true, phase: phase, key: key} = Intent.status(pid)
    refute phase == :absent
    assert key == a.key
  end

  test "R3 pinning: only the host-checked addresses are used, never DNS; a :public answer with a non-public address is target_refused (ex_mcp :dns_resolver)",
       ctx do
    # The system resolver would answer 127.0.0.1 for localhost, where the
    # evidence server listens; the pinned 127.0.0.2 has no listener.
    assert {:ok, {127, 0, 0, 1}} = :inet.getaddr(~c"localhost", :inet)
    url = "http://localhost:#{ctx.server.port}/mcp"
    requests()

    {:ok, c} = runtime_config(ctx, runtime(ctx, %{endpoint: url, addresses: [{127, 0, 0, 2}]}))
    assert {:error, :connect_failed} = McpClient.connect(c, ctx.sup)
    assert requests() == []

    s = runtime_session(ctx, runtime(ctx, %{endpoint: url, addresses: [{127, 0, 0, 1}]}))
    assert Enum.map(requests(), &elem(&1, 0)) == ["server/discover"]
    McpClient.close(s)

    resolver = Transport.client_options(s.config)[:dns_resolver]
    assert resolver.("localhost", 1_000) == {:ok, [{127, 0, 0, 1}]}
    assert resolver.("LocalHost", 1_000) == {:ok, [{127, 0, 0, 1}]}
    assert resolver.("127.0.0.1", 1_000) == {:error, :nxdomain}
    assert resolver.("mcp.example.test", 1_000) == {:error, :nxdomain}

    public = %{
      server: "elzoo-runtime-server",
      endpoint: "https://mcp.example.test/mcp",
      network: :public
    }

    for addresses <- [[{10, 0, 0, 1}], [{127, 0, 0, 1}], [{93, 184, 215, 14}, {10, 0, 0, 1}]] do
      {:ok, pc} = runtime_config(ctx, Map.put(public, :addresses, addresses))
      assert {:error, :target_refused} = McpClient.connect(pc, ctx.sup)
    end

    assert requests() == []

    # The :public option list is the build-time :public list plus the resolver.
    {:ok, pc} = runtime_config(ctx, Map.put(public, :addresses, [{93, 184, 215, 14}]))

    {:ok, bc} =
      McpClient.configure(
        binding: Server.binding(public.endpoint, :public),
        tenant: "tenant-a",
        credentials: fn -> {:ok, @token} end
      )

    run = Transport.client_options(pc)
    build = Transport.client_options(bc)
    refute Keyword.has_key?(build, :dns_resolver)
    assert Keyword.keys(run) == Keyword.keys(build) ++ [:dns_resolver]

    assert Keyword.drop(run, [:dns_resolver, :auth_provider]) ==
             Keyword.drop(build, [:auth_provider])
  end

  test "R4 runtime configure: only with RuntimeBinding, exact keys and bounds; a credential inside the runtime strings is refused before any send (configure)",
       ctx do
    good = runtime(ctx)
    called = :counters.new(1, [])
    need = fn -> :counters.add(called, 1, 1) && {:ok, @token} end
    assert {:ok, _} = runtime_config(ctx, good, credentials: need)

    base = [tenant: "tenant-a", credentials: need]
    assert {:error, :configuration} = McpClient.configure([binding: RuntimeBinding] ++ base)

    assert {:error, :configuration} =
             McpClient.configure([binding: RuntimeBinding, runtime: nil] ++ base)

    assert {:error, :configuration} =
             McpClient.configure([binding: Server.binding(ctx.server.url), runtime: good] ++ base)

    assert {:error, :configuration} =
             McpClient.configure([binding: Server.binding(ctx.server.url), runtime: nil] ++ base)

    public_http = %{
      good
      | network: :public,
        endpoint: "http://mcp.example.test/mcp",
        addresses: [{93, 184, 215, 14}]
    }

    for bad <- [
          Map.put(good, :extra, 1),
          Map.delete(good, :addresses),
          Map.delete(good, :server),
          %{good | network: :private},
          %{good | server: ""},
          %{good | server: String.duplicate("s", 129)},
          public_http,
          %{public_http | endpoint: "https://localhost/mcp"},
          %{public_http | endpoint: "https://127.0.0.1/mcp"},
          %{good | addresses: []},
          %{good | addresses: for(d <- 1..33, do: {127, 0, 0, d})},
          %{good | addresses: [{127, 0, 0, 1}, {127, 0, 0, 1}]},
          %{good | addresses: [{127, 0, 0, 1, 5}]},
          %{good | addresses: [{127, 0, 0, 256}]},
          %{good | addresses: {127, 0, 0, 1}},
          %{good | addresses: ["127.0.0.1"]},
          Map.to_list(good)
        ] do
      assert {:error, :configuration} = runtime_config(ctx, bad, credentials: need), inspect(bad)
    end

    assert {:ok, _} =
             runtime_config(ctx, %{good | addresses: for(d <- 1..32, do: {127, 0, 0, d})})

    assert {:ok, _} = runtime_config(ctx, %{good | addresses: [{0, 0, 0, 0, 0, 0, 0, 1}]})
    assert :counters.get(called, 1) == 0

    server = "elzoo-runtime-server-identity-0001"
    path = "/mcp/runtime-endpoint-path-0001"

    loopback =
      runtime(ctx, %{server: server, endpoint: "http://127.0.0.1:#{ctx.server.port}#{path}"})

    requests()

    for word <- [server, "runtime-server-identity-0001", path, "runtime-endpoint-path-0001"] do
      {:ok, c} = runtime_config(ctx, loopback, credentials: fn -> {:ok, word} end)
      assert {:error, :credentials_unavailable} = McpClient.connect(c, ctx.sup), word
      assert requests() == []
    end

    # The endpoint host: a :public host pinned to a refused address, so only the
    # credential rule answers credentials_unavailable, before any resolution.
    host = "mcp-runtime-host-0001.example.test"

    public = %{
      server: "elzoo-runtime-server",
      endpoint: "https://#{host}/mcp",
      network: :public,
      addresses: [{10, 0, 0, 1}]
    }

    for word <- [host, "mcp-runtime-host-0001.example"] do
      {:ok, c} = runtime_config(ctx, public, credentials: fn -> {:ok, word} end)
      assert {:error, :credentials_unavailable} = McpClient.connect(c, ctx.sup), word
    end

    {:ok, c} = runtime_config(ctx, public)
    assert {:error, :target_refused} = McpClient.connect(c, ctx.sup)
    assert requests() == []
  end

  test "R5 drift: TargetPolicy.resolve/2 pins the smallest address, refuses a mixed answer, passes dns_timeout; a 302 is not followed (ex_mcp 1.8.1)",
       ctx do
    alias ExMCP.Transport.HTTP.TargetPolicy
    answer = fn result -> [dns_resolver: fn _host, _timeout -> result end] end

    assert {:ok, %URI{host: "localhost"}, {127, 0, 0, 2}} =
             TargetPolicy.resolve(
               "http://localhost:1/mcp",
               answer.({:ok, [{127, 0, 0, 9}, {127, 0, 0, 2}, {127, 0, 0, 9}, {127, 0, 0, 3}]})
             )

    assert {:error, :non_public_address} =
             TargetPolicy.resolve(
               "https://mcp.example.test/mcp",
               answer.({:ok, [{93, 184, 215, 14}, {10, 0, 0, 1}]})
             )

    assert {:ok, _, {93, 184, 215, 14}} =
             TargetPolicy.resolve(
               "https://mcp.example.test/mcp",
               answer.({:ok, [{93, 184, 215, 14}]})
             )

    assert {:error, :dns_timeout} =
             TargetPolicy.resolve("https://mcp.example.test/mcp", answer.({:error, :dns_timeout}))

    assert {:error, :dns_failed} =
             TargetPolicy.resolve("https://mcp.example.test/mcp", answer.({:error, :nxdomain}))

    {target, counter} = Server.counted()
    on_exit(fn -> Server.stop(target) end)
    s = runtime_session(ctx, runtime(ctx))
    requests()
    Server.mode(ctx.server, {:redirect, target.url})
    assert {:error, tag, :mcp} = send_one(s, payload("echo", %{}))
    assert {:ok, {:unknown, {:server_error, :other}}} = McpClient.outcome(tag)
    assert count(requests(400), "tools/call") == 1
    assert :counters.get(counter, 1) == 0
  end

  test "T26 ex_mcp is the exact pinned version and make_request/5 is exported (upstream drift guard)" do
    assert Application.spec(:ex_mcp, :vsn) == ~c"1.8.1"
    assert function_exported?(ExMCP.Client, :make_request, 5)
  end
end
