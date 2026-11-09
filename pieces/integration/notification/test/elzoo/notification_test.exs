# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/notification_test_helper.exs", __DIR__)

defmodule Elzoo.NotificationTest do
  # Each scenario names the boundary it exercises. No real mail: every SMTP
  # session goes to gen_smtp_server on 127.0.0.1 inside this VM, or is refused
  # before any connection (asserted with the server's connection counter).
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Elzoo.Notification
  alias Elzoo.Notification.{Adapter, Binding}
  alias Elzoo.NotificationTest.SmtpServer
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @user "user-SECRET-u9"
  @password "pw-SECRET-p-7731"
  @recipient "rcpt-secret-r42@example.test"
  @subject "subj-SECRET-s5"
  @body "body-SECRET-b8"
  @secrets [@user, @password, @recipient, @subject, @body, "rcpt-secret-r42"]

  setup do
    tasks = start_supervised!({Task.Supervisor, name: nil}, id: :transport)
    intents = start_supervised!({Task.Supervisor, name: nil}, id: :intent)
    %{tasks: tasks, intents: intents}
  end

  ## helpers

  defp payload(overrides \\ %{}) do
    %{"version" => 1, "to" => [@recipient], "subject" => @subject, "text" => @body, "html" => nil}
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp declaration(payload, ref \\ "invite-1") do
    %{
      "capability_id" => "integration/notification",
      "operation" => "email",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => "message-1",
        "schema_id" => "elzoo/notification-email",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "caller", "port_id" => "notify"},
        "idempotency_key" => ref,
        "deadline_unix_ms" => 10_000,
        "payload" => payload
      }
    }
  end

  defp loopback(mode, ctx, opts \\ []) do
    server = SmtpServer.start(mode)
    {_, port} = server
    binding = SmtpServer.binding("127.0.0.1", port)

    {:ok, config} =
      Notification.configure(
        [
          binding: binding,
          tenant: "tenant-a",
          credentials: Keyword.get(opts, :credentials, fn -> {:ok, {@user, @password}} end),
          transport_supervisor: ctx.tasks,
          tls: :plaintext_loopback
        ] ++ Keyword.take(opts, [:max_request_bytes, :send_timeout_ms])
      )

    on_exit(fn -> SmtpServer.stop(server) end)
    config
  end

  # The request EffectIntent hands the Adapter for attempt 1.
  defp request(config, arguments) do
    {:ok, b, _} = Binding.load(config.binding)
    {:ok, a} = Notification.admission(config, declaration(payload()))

    %{
      key: a.key,
      attempt: 1,
      attempt_id: "attempt-1",
      arguments: arguments,
      arguments_digest: :crypto.hash(:sha256, arguments),
      schema: Adapter.schema(),
      binding: b.digest,
      context: config
    }
  end

  defp send_one(config, arguments \\ payload()), do: Adapter.send_effect(request(config, arguments))

  defp events do
    receive do
      {:smtp, e} -> [e | events()]
    after
      100 -> []
    end
  end

  defp count(evs, tag), do: Enum.count(evs, &(&1 == tag or (is_tuple(&1) and elem(&1, 0) == tag)))

  defp refute_secrets(term) do
    text =
      if is_binary(term),
        do: term,
        else: inspect(term, limit: :infinity, printable_limit: :infinity)

    for s <- @secrets, do: refute(text =~ s, "secret #{s} leaked")
  end

  defp owner(config, admission, ctx, memory \\ nil) do
    memory =
      memory ||
        start_supervised!({Memory, fold: Intent.fold(config.binding), limits: Intent.limits()},
          id: make_ref()
        )

    host_memory =
      start_supervised!({Memory, fold: StoreHost.fold(), limits: StoreHost.limits()},
        id: make_ref()
      )

    opts = [
      binding: config.binding,
      identity: admission.identity,
      arguments: admission.arguments,
      deadline: admission.deadline,
      clock: fn -> 100 end,
      store: Memory.store(memory),
      host: {StoreHost, %{store: Memory.store(host_memory), authorize: fn _, _ -> :fresh end}},
      task_supervisor: ctx.intents,
      adapter_context: config,
      allow_volatile: true
    ]

    {:ok, pid} = Intent.start_link(opts)
    {pid, memory}
  end

  # The owner has observed the Adapter's result once no Adapter task is running
  # (test-only introspection of the owner's state).
  defp settled(pid, tries \\ 250) do
    cond do
      :sys.get_state(pid).tasks == %{} ->
        Intent.status(pid)

      tries == 0 ->
        flunk("attempt never settled: #{inspect(Intent.status(pid).phase)}")

      true ->
        Process.sleep(20)
        settled(pid, tries - 1)
    end
  end

  ## T1 accepted

  test "T1 accepted: provider ID recorded as acceptance; one message with stable Message-ID from the binding sender (real Swoosh SMTP client to in-process server, through EffectIntent)",
       ctx do
    config = loopback(:accept, ctx)
    {:ok, a} = Notification.admission(config, declaration(payload()))
    {pid, _} = owner(config, a, ctx)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    assert {:Confirmed, 1} = status.phase
    evs = events()
    assert [{:data, data}] = Enum.filter(evs, &match?({:data, _}, &1))
    assert data =~ "Message-ID: <#{a.key}@example.test>"
    assert data =~ "From: app@example.test"

    assert {:mail, "<app@example.test>"} in evs or {:mail, "app@example.test"} in evs or
             count(evs, :mail) == 1

    # Directly: the completion carries the provider's queue text, not delivery.
    result = send_one(config)
    assert %{"outcome" => "completed", "dispatch" => "dispatched", "value" => v} = result
    assert v["provider_id"] == "2.0.0 Ok: queued as ELZOO-TEST-1"
    assert v["message_id"] == "<#{a.key}@example.test>"
    assert :ok = Adapter.validate_result(result, request(config, payload()))
    assert :ok = Adapter.authenticate(result, request(config, payload()))
  end

  ## T2 invalid address

  test "T2 invalid address refused at admission and at send, with no TCP connection (Adapter pre-checks; server counter)",
       ctx do
    config = loopback(:accept, ctx)

    for bad <- [
          "no-at-sign.example.test",
          "a@b@example.test",
          "bob@example.test\r\nBcc: x@example.test",
          "<bob@example.test>",
          "bob@example.test,eve@example.test",
          "bob smith@example.test",
          "bob@localhost",
          String.duplicate("a", 65) <> "@example.test",
          "bob@" <> String.duplicate("a", 250) <> ".test",
          "bób@example.test",
          "bob\0@example.test"
        ] do
      assert {:error, {:refused, :invalid_address}} =
               Notification.admission(config, declaration(payload(%{"to" => [@recipient, bad]})))

      assert {:error, :invalid_address, :smtp} = send_one(config, payload(%{"to" => [bad]}))
    end

    assert count(events(), :connect) == 0
    assert {:ok, {:refused, :invalid_address}} = Notification.outcome(:invalid_address)
  end

  ## T3 rejected recipient

  test "T3 rejected recipient (550 at RCPT) is refused, dispatched, permanent; the echoed address is not returned (real client/server)",
       ctx do
    config = loopback(:reject_rcpt, ctx)
    result = send_one(config)
    assert {:error, :rejected_recipient, :smtp} = result
    assert {"failed", "dispatched", "permanent"} = Binding.failures().rejected_recipient
    evs = events()
    assert count(evs, :data) == 0
    refute_secrets(result)
  end

  ## T4 too large

  test "T4 too large: over the configured bound refused before dispatch with zero connections; 552 after DATA refused too_large (Adapter pre-check; real client/server)",
       ctx do
    config = loopback(:accept, ctx, max_request_bytes: 512)
    big = payload(%{"text" => String.duplicate("x", 600)})

    assert {:error, {:refused, :too_large}} = Notification.admission(config, declaration(big))
    assert {:error, :too_large, :smtp} = send_one(config, big)

    assert {:error, {:refused, :too_large}} =
             Notification.admission(config, declaration(String.duplicate(" ", 70_000)))

    assert count(events(), :connect) == 0

    config = loopback(:too_big, ctx)
    assert {:error, :provider_too_large, :smtp} = send_one(config)
    assert {:ok, {:refused, :too_large}} = Notification.outcome(:provider_too_large)
  end

  ## T5 authentication failure

  test "T5 authentication failure: refused before any MAIL, RCPT or DATA, attested no-send (real client/server)",
       ctx do
    config = loopback(:auth_fail, ctx)
    assert {:error, :authentication_failed, :smtp} = send_one(config)
    evs = events()
    # gen_smtp may try a second SASL mechanism within the same single session.
    assert count(evs, :connect) == 1 and count(evs, :auth) >= 1
    assert count(evs, :mail) + count(evs, :rcpt) + count(evs, :data) == 0
    assert :authentication_failed in Binding.no_send()

    config = loopback(:no_auth, ctx)
    assert {:error, :authentication_failed, :smtp} = send_one(config)
    assert count(events(), :mail) == 0
  end

  ## T6 throttling

  test "T6 throttling: 451 at RCPT refused throttled once, no retry, no rearm; 421 banner is attested no-send (real client/server; EffectIntent owner)",
       ctx do
    config = loopback(:throttle_rcpt, ctx)
    assert {:error, :throttled, :smtp} = send_one(config)
    assert count(events(), :connect) == 1
    assert {"failed", "dispatched", "retryable"} = Binding.failures().throttled

    {:ok, a} = Notification.admission(config, declaration(payload(), "throttled-1"))
    {pid, _} = owner(config, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    settled(pid)
    assert {:error, _} = Intent.advance(pid, :rearm)
    assert {:error, _} = Intent.advance(pid, :dispatch)
    assert count(events(), :connect) == 1

    config = loopback(:busy, ctx)
    assert {:error, :session_throttled, :smtp} = send_one(config)
    assert {:ok, {:refused, :throttled}} = Notification.outcome(:session_throttled)
    assert count(events(), :mail) == 0

    # Attested no-send: EffectIntent permits an explicit host rearm, never by itself.
    {:ok, a} = Notification.admission(config, declaration(payload(), "busy-1"))
    {pid, _} = owner(config, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert {:Definite, _, 1} = settled(pid).phase
    assert count(events(), :connect) == 1
    assert {:ok, _} = Intent.advance(pid, :rearm)
  end

  ## T7 dropped connection after handover

  test "T7 connection dropped after the message was handed over is unknown and never resent (real client/server; EffectIntent owner)",
       ctx do
    config = loopback(:drop_after_data, ctx)
    {:ok, a} = Notification.admission(config, declaration(payload(), "drop-1"))
    {pid, _} = owner(config, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    assert {:Dispatched, _, 1} = status.phase
    assert {:error, _} = Intent.advance(pid, :rearm)
    assert {:error, _} = Intent.advance(pid, :dispatch)
    assert count(events(), :data) == 1

    assert {:error, :connection_lost, :smtp} = send_one(config)
    assert {:ok, {:unknown, :connection_lost}} = Notification.outcome(:connection_lost)
    assert {"unknown", "unknown", _} = Binding.failures().connection_lost
    refute :connection_lost in Binding.no_send()
  end

  ## T8 deadline

  test "T8 deadline: server stalls after DATA; the transport is killed and the outcome is unknown (Adapter process bound; real server)",
       ctx do
    config = loopback(:stall_after_data, ctx, send_timeout_ms: 300)
    started = System.monotonic_time(:millisecond)
    assert {:error, :deadline, :smtp} = send_one(config)
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert {:ok, {:unknown, :deadline}} = Notification.outcome(:deadline)
    refute :deadline in Binding.no_send()
  end

  ## T9 same identity twice

  test "T9 the same identity is never sent twice without reconciliation: second dispatch refused, restart read-only, re-admission same key (EffectIntent owner)",
       ctx do
    config = loopback(:drop_after_data, ctx)
    {:ok, a} = Notification.admission(config, declaration(payload(), "same-1"))
    {:ok, again} = Notification.admission(config, declaration(payload(), "same-1"))
    assert a.key == again.key
    {pid, memory} = owner(config, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    settled(pid)
    assert {:error, _} = Intent.advance(pid, :dispatch)
    GenServer.stop(pid)

    {recovered, _} = owner(config, again, ctx, memory)
    assert %{active: false} = Intent.status(recovered)
    assert {:error, :read_only} = Intent.advance(recovered, :dispatch)
    assert count(events(), :data) == 1
  end

  ## T10 redaction in logs

  test "T10 no credential, recipient, subject or body in any log line at :debug across the scenarios (Logger; gen_smtp client debug path)",
       ctx do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log([level: :debug], fn ->
        for mode <- [
              :accept,
              :reject_rcpt,
              :throttle_rcpt,
              :auth_fail,
              :drop_after_data,
              :too_big,
              :data_554
            ] do
          config = loopback(mode, ctx)
          send_one(config)
        end

        config = loopback(:accept, ctx, credentials: fn -> raise "boom #{@password}" end)
        send_one(config)
        Logger.flush()
      end)

    refute_secrets(log)
  end

  ## T11 redaction in errors, inspect, status and telemetry

  test "T11 no secret in Adapter returns, inspect(config), EffectIntent status or retained evidence; no Swoosh telemetry event (Adapter terms; Inspect; :telemetry)",
       ctx do
    parent = self()

    :telemetry.attach_many(
      "notification-test",
      for(e <- [:deliver, :deliver_many], p <- [:start, :stop, :exception], do: [:swoosh, e, p]),
      fn event, _, meta, _ -> send(parent, {:telemetry, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("notification-test") end)

    results =
      for mode <- [
            :accept,
            :reject_rcpt,
            :throttle_rcpt,
            :auth_fail,
            :drop_after_data,
            :too_big,
            :data_554
          ] do
        config = loopback(mode, ctx)
        refute_secrets(inspect(config))
        send_one(config)
      end

    assert Enum.any?(results, &is_map/1)
    for r <- results, not is_map(r), do: refute_secrets(r)
    assert {:error, :unclassified_reply, :smtp} = List.last(results)

    config = loopback(:reject_rcpt, ctx)
    {:ok, a} = Notification.admission(config, declaration(payload(), "evidence-1"))
    {pid, _} = owner(config, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    refute_secrets(settled(pid))
    refute_received {:telemetry, _, _}
  end

  ## T12 credential Need shapes

  test "T12 every malformed, oversize, raising, throwing or exiting credential Need is credentials_unavailable with no connection and no leak (Adapter boundary; server counter)",
       ctx do
    cases = [
      fn -> {:error, :unavailable} end,
      fn -> raise "credential store says #{@password}" end,
      fn -> throw({:secret, @password}) end,
      fn -> exit({:secret, @password}) end,
      fn -> {:ok, {String.to_atom(@user), @password}} end,
      fn -> {:ok, {@user, 12_345}} end,
      fn -> {:ok, {String.to_charlist(@user), @password}} end,
      fn -> {:ok, %{user: @user, password: @password}} end,
      fn -> {:ok, {String.duplicate("u", 257), @password}} end,
      fn -> {:ok, {@user, String.duplicate("p", 1025)}} end,
      fn -> {:ok, {@user <> "\r\n", @password}} end,
      fn -> {:ok, {@user, @password <> <<0>>}} end,
      fn -> {:ok, {"", @password}} end,
      fn -> {@user, @password} end
    ]

    log =
      capture_log(fn ->
        for fun <- cases do
          config = loopback(:accept, ctx, credentials: fun)
          result = send_one(config)
          assert {:error, :credentials_unavailable, :smtp} = result
          refute_secrets(result)
          refute_secrets(inspect(config))
        end
      end)

    refute_secrets(log)
    assert count(events(), :connect) == 0

    assert {"timed_out", "not_dispatched", "unavailable"} =
             Binding.failures().credentials_unavailable

    assert :credentials_unavailable in Binding.no_send()
  end

  ## T13 connection refused

  test "T13 nothing listening: connect_failed, attested no-send (real client, closed port)", ctx do
    {name, port} = SmtpServer.start(:accept)
    SmtpServer.stop({name, port})
    binding = SmtpServer.binding("127.0.0.1", port)

    {:ok, config} =
      Notification.configure(
        binding: binding,
        tenant: "tenant-a",
        credentials: fn -> {:ok, {@user, @password}} end,
        transport_supervisor: ctx.tasks,
        tls: :plaintext_loopback
      )

    assert {:error, :connect_failed, :smtp} = send_one(config)
    assert {:ok, {:refused, :connect_failed}} = Notification.outcome(:connect_failed)
  end

  ## T14 forged completion

  test "T14 a forged public completion without the process-local seal does not settle the attempt (EffectIntent observe + authenticate)",
       ctx do
    config = loopback(:drop_after_data, ctx)
    {:ok, a} = Notification.admission(config, declaration(payload(), "forged-1"))
    {pid, _} = owner(config, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    settled(pid)

    forged = %{
      "version" => 1,
      "message_id" => a.key,
      "correlation_id" => a.key,
      "attempt_id" => "attempt-1",
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{
        "provider_id" => "ok",
        "message_id" => "<#{a.key}@example.test>",
        "seal" => String.duplicate("0", 64)
      },
      "value_schema_id" => "elzoo/notification-acceptance",
      "value_schema_version" => 1
    }

    Intent.observe(pid, forged)
    assert {:Dispatched, _, 1} = Intent.status(pid).phase
    assert :error = Adapter.authenticate(forged, request(config, payload()))
  end

  ## T15 classification table

  test "T15 classification: the Cure decision and the binding table agree for every row (Cure classify; binding compile)" do
    alias Elzoo.Notification.Outcome

    rows = [
      {:MailTransaction, :MailAccepted, :accepted},
      {:MailPre, :MailBadAddress, :invalid_address},
      {:MailPre, :MailOversize, :too_large},
      {:MailTransaction, {:MailCode, 552}, :provider_too_large},
      {:MailTransaction, {:MailCode, 550}, :rejected_recipient},
      {:MailTransaction, {:MailCode, 551}, :rejected_recipient},
      {:MailTransaction, {:MailCode, 553}, :rejected_recipient},
      {:MailTransaction, {:MailCode, 421}, :throttled},
      {:MailTransaction, {:MailCode, 450}, :throttled},
      {:MailTransaction, {:MailCode, 451}, :throttled},
      {:MailTransaction, {:MailCode, 452}, :throttled},
      {:MailSession, {:MailCode, 421}, :session_throttled},
      {:MailSession, {:MailCode, 554}, :connect_failed},
      {:MailSession, :MailAuthRefused, :authentication_failed},
      {:MailSession, :MailAuthMissing, :authentication_failed},
      {:MailTransaction, :MailLost, :connection_lost},
      {:MailExpired, :MailLost, :deadline},
      {:MailTransaction, {:MailCode, 554}, :unclassified_reply},
      {:MailTransaction, {:MailCode, 500}, :unclassified_reply},
      {:MailTransaction, :MailMalformed, :unclassified_reply},
      {:MailCrashed, :MailMalformed, :adapter_error},
      {:MailPre, :MailCredentialFault, :credentials_unavailable},
      {:MailSession, :MailLost, :connect_failed},
      {:MailSession, :MailTlsFailed, :connect_failed},
      {:MailSession, :MailMalformed, :connect_failed}
    ]

    for {stage, reply, tag} <- rows,
        do: assert(Outcome.classify(stage, reply) == tag, inspect({stage, reply}))

    # A lost connection or expiry never classifies as a refusal or no-send.
    for stage <- [:MailTransaction, :MailExpired, :MailCrashed],
        reply <- [:MailLost, :MailMalformed] do
      tag = Outcome.classify(stage, reply)
      refute tag in Binding.no_send()
      assert {:ok, {:unknown, _}} = Notification.outcome(tag)
    end

    # connect_failed only when attested before MAIL (session stage); after MAIL,
    # or when the stage cannot be attested, the outcome is unknown.
    for reply <- [:MailLost, :MailMalformed, :MailTlsFailed, {:MailCode, 554}, {:MailCode, 500}],
        stage <- [:MailTransaction, :MailExpired, :MailCrashed] do
      refute Outcome.classify(stage, reply) == :connect_failed
    end

    assert {:MailSession, :MailLost, nil} =
             Elzoo.Notification.Transport.stage(
               {:error, {:retries_exceeded, {:network_failure, ~c"h", {:error, :econnrefused}}}}
             )

    assert {:MailTransaction, :MailLost, nil} =
             Elzoo.Notification.Transport.stage(
               {:error, {:send, {:network_failure, ~c"h", {:error, :closed}}}}
             )

    assert {:MailCrashed, _, nil} = Elzoo.Notification.Transport.stage(:unexpected)

    assert Enum.sort(Map.keys(Binding.failures())) == Enum.sort(Adapter.failure_tags())

    for {tag, {_, dispatch, _}} <- Binding.failures(),
        do: assert(dispatch == "not_dispatched" == tag in Binding.no_send())
  end

  ## T16 configuration

  test "T16 configuration: plaintext only for loopback; non-loopback needs verified TLS and the credential Need is never called otherwise; bounds checked (configure; Binding)",
       ctx do
    remote = SmtpServer.binding("smtp.example.test", 587)
    parent = self()

    creds = fn ->
      send(parent, :credential_called)
      {:ok, {@user, @password}}
    end

    base = [binding: remote, tenant: "t", credentials: creds, transport_supervisor: ctx.tasks]

    assert {:error, :configuration} = Notification.configure(base ++ [tls: :plaintext_loopback])
    assert {:error, :configuration} = Notification.configure(base)

    assert {:error, :configuration} =
             Notification.configure(base ++ [tls: {:verified, {:cacerts, ["not a cert"]}}])

    assert {:error, :configuration} =
             Notification.configure(base ++ [tls: {:verified, {:cacerts, []}}])

    assert {:error, :configuration} =
             Notification.configure(base ++ [tls: :plaintext_loopback, max_request_bytes: 65_537])

    ip_remote = SmtpServer.binding("192.0.2.10", 25)

    assert {:error, :configuration} =
             Notification.configure(
               Keyword.put(base, :binding, ip_remote) ++ [tls: {:verified, :system}]
             )

    refute_received :credential_called

    other = SmtpServer.binding("smtp.example.test", 587, "other@example.test")
    {:ok, c1} = Notification.configure(base ++ [tls: {:verified, :system}])

    {:ok, c2} =
      Notification.configure(Keyword.put(base, :binding, other) ++ [tls: {:verified, :system}])

    {:ok, a1} = Notification.admission(c1, declaration(payload()))
    {:ok, a2} = Notification.admission(c2, declaration(payload()))
    refute a1.key == a2.key
    refute_secrets(inspect(c1))

    assert_raise ArgumentError, fn ->
      SmtpServer.binding("smtp.example.test", 587, "not-an-address")
    end

    assert_raise ArgumentError, fn -> SmtpServer.binding("Bad Host", 587) end
  end

  ## T17 verified TLS

  describe "T17 verified TLS (gen_smtp STARTTLS with fixed verification options to in-process gen_smtp_server)" do
    setup do
      %{
        good: SmtpServer.pki("localhost"),
        other: SmtpServer.pki("localhost"),
        wrong: SmtpServer.pki("elsewhere.test")
      }
    end

    defp tls_case(ctx, server_pki, trust, mode \\ :accept) do
      server =
        if mode == :no_starttls,
          do: SmtpServer.start(:accept),
          else: SmtpServer.start(mode, tls: server_pki.server)

      {_, port} = server
      on_exit(fn -> SmtpServer.stop(server) end)

      {:ok, config} =
        Notification.configure(
          binding: SmtpServer.binding("localhost", port),
          tenant: "tenant-a",
          credentials: fn -> {:ok, {@user, @password}} end,
          transport_supervisor: ctx.tasks,
          tls: {:verified, {:cacerts, trust}}
        )

      send_one(config)
    end

    test "trusted CA and matching hostname: accepted over TLS", ctx do
      assert %{"outcome" => "completed"} = tls_case(ctx, ctx.good, ctx.good.cacerts)
      evs = events()
      assert :starttls in evs and count(evs, :auth) == 1 and count(evs, :data) == 1
    end

    test "untrusted CA: connect_failed before AUTH, MAIL, RCPT or DATA", ctx do
      assert {:error, :connect_failed, :smtp} = tls_case(ctx, ctx.good, ctx.other.cacerts)
      evs = events()
      assert count(evs, :auth) + count(evs, :mail) + count(evs, :rcpt) + count(evs, :data) == 0
    end

    test "certificate for another hostname: connect_failed before AUTH", ctx do
      assert {:error, :connect_failed, :smtp} = tls_case(ctx, ctx.wrong, ctx.wrong.cacerts)
      evs = events()
      assert count(evs, :auth) + count(evs, :mail) + count(evs, :rcpt) + count(evs, :data) == 0
    end

    test "server without STARTTLS: connect_failed, no plaintext fallback", ctx do
      assert {:error, :connect_failed, :smtp} = tls_case(ctx, nil, ctx.good.cacerts, :no_starttls)
      evs = events()
      assert count(evs, :auth) + count(evs, :mail) + count(evs, :rcpt) + count(evs, :data) == 0
    end
  end

  ## T18 runtime: false smoke

  test "T18 the swoosh application is not started and direct SMTP delivery works (dependency/runtime configuration)",
       ctx do
    refute Enum.any?(Application.started_applications(), &(elem(&1, 0) == :swoosh))
    config = loopback(:accept, ctx)
    assert %{"outcome" => "completed"} = send_one(config)
    refute Enum.any?(Application.started_applications(), &(elem(&1, 0) == :swoosh))
  end
end
