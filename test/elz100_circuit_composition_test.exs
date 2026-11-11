# SPDX-License-Identifier: Apache-2.0
# Root-only composition: these Adapters are deliberately outside the circuit's
# exported dependency closure. No Adapter mapping or ready Contract is changed.
Code.require_file(
  "../pieces/integration/object-store/test/support/object_store_test_helper.exs",
  __DIR__
)

Code.require_file(
  "../pieces/integration/notification/test/support/notification_test_helper.exs",
  __DIR__
)

defmodule Elzoo.CircuitCompositionTest do
  use ExUnit.Case, async: false
  alias Elzoo.CircuitBreaker, as: C
  alias Elzoo.ObjectStore, as: OS
  alias Elzoo.ObjectStoreTestHelper, as: H
  alias Elzoo.RetryTimeout, as: R
  alias Elzoo.Notification
  alias Elzoo.Notification.{Adapter, Binding}
  alias Elzoo.NotificationTest.SmtpServer

  # Consumer-owned, explicit observation policy. Retryability and dispatch
  # remain separate facts; an unknown Effect is not made safe to replay.
  defp s3_health(%{status: s}) when s in [:found, :absent], do: :healthy

  defp s3_health(%{status: :unknown, reason: r}) when r in [:deadline, :transport, :server_error],
    do: :unhealthy

  defp s3_health(%{status: :refused}), do: :neutral
  defp s3_health(_), do: :unknown
  defp smtp_health({:error, :connect_failed, :smtp}), do: :unhealthy

  defp smtp_health({:error, tag, :smtp})
       when tag in [
              :throttled,
              :session_throttled,
              :authentication_failed,
              :rejected_recipient,
              :credentials_unavailable,
              :invalid_address
            ],
       do: :neutral

  defp smtp_health(_), do: :unknown

  defp attempt(owner, config, operation \\ :get) do
    case C.admit(owner) do
      {:ok, permit} ->
        result = apply(OS, operation, [config, "fixture-key"])
        assert C.finish(owner, permit, s3_health(result)) == {:ok, :applied}
        {:sent, result}

      {:refused, reason} ->
        {:not_sent, reason}
    end
  end

  defp wait(fun, tries \\ 200)
  defp wait(_, 0), do: flunk("cooldown did not complete")

  defp wait(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait(fun, tries - 1)
        )
  end

  defp mode(owner) do
    {:ok, s} = C.status(owner)
    s.mode
  end

  test "C19 actual S3 outcomes, SMTP connect, circuit refusal and unchanged Retry/Runner capacity" do
    owner =
      start_supervised!({C, name: :circuit_composition_s3, cooldown_ms: 50, role: :object_store})

    fuse = {:elzoo_circuit_breaker, :circuit_composition_s3}
    {port, _} = H.stub({:reply, H.response(200, [], "fixture")})
    healthy = H.stub_config(port)
    assert {:sent, %{status: :found, body: "fixture"}} = attempt(owner, healthy)
    assert mode(owner) == :closed
    {head_port, _} = H.stub({:reply, H.response(200, [{"content-length", "0"}])})

    assert {:sent, %{status: :found, operation: :head}} =
             attempt(owner, H.stub_config(head_port), :head)

    {absent_port, _} =
      H.stub({:reply, H.response(404, [], "<Error><Code>NoSuchKey</Code></Error>")})

    assert {:sent, %{status: :absent}} = attempt(owner, H.stub_config(absent_port))

    for {http, code, status, reason, health} <- [
          {403, "AccessDenied", :refused, :denied, :neutral},
          {500, "InternalError", :unknown, :server_error, :unhealthy},
          {429, "Throttling", :unknown, :unexpected, :unknown},
          {503, "SlowDown", :unknown, :server_error, :unhealthy}
        ] do
      {port, ref} = H.stub({:reply, H.response(http, [], "<Error><Code>#{code}</Code></Error>")})
      config = H.stub_config(port)
      assert {:sent, result} = attempt(owner, config)
      assert result.status == status and result.reason == reason
      assert s3_health(result) == health
      assert_receive {:stub_connection, ^ref}
      {:ok, delivery, _} = OS.to_delivery_result(result, %{"message_id" => "s3-read"})
      assert {:ok, class} = R.classify(delivery)
      {:ok, policy} = R.policy([])

      if status == :unknown do
        assert R.decide(policy, 1, class) == {:ok, :unresolved}
        assert mode(owner) == :open
        # Circuit refusal before dispatch never invokes this still-live stub.
        assert attempt(owner, config) == {:not_sent, :open}
        refute_receive {:stub_connection, ^ref}, 10

        refusal = %{
          "version" => 1,
          "message_id" => "circuit-refusal",
          "correlation_id" => "circuit-refusal",
          "outcome" => "rejected",
          "dispatch" => "not_dispatched",
          "error_class" => "unavailable"
        }

        assert {:ok, :retryable} = R.classify(refusal)
        assert {:ok, :retry} = R.decide(policy, 1, :retryable)

        wait(fn ->
          :fuse.ask(fuse, :sync) == :ok and elem(C.status(owner), 1).cooldown_remaining_ms == 0
        end)

        assert {:sent, %{status: :found}} = attempt(owner, healthy)
        assert mode(owner) == :closed
      else
        assert mode(owner) == :closed
      end
    end

    {close_port, ref} = H.stub({:reply, ""})

    assert {:sent, %{status: :unknown, reason: :transport}} =
             attempt(owner, H.stub_config(close_port))

    assert_receive {:stub_connection, ^ref}
    assert mode(owner) == :open

    wait(fn ->
      :fuse.ask(fuse, :sync) == :ok and elem(C.status(owner), 1).cooldown_remaining_ms == 0
    end)

    assert {:sent, %{status: :found}} = attempt(owner, healthy)

    assert {:sent, %{status: :refused, reason: :too_large}} =
             attempt(owner, Map.put(healthy, :max_object_bytes, 1))

    assert mode(owner) == :closed

    # Actual Swoosh/gen_smtp connect refusal, not a synthetic health atom.
    smtp_owner =
      start_supervised!({C, name: :circuit_composition_smtp, role: :notification},
        id: :smtp_circuit
      )

    tasks = start_supervised!({Task.Supervisor, []})
    binding = SmtpServer.binding("127.0.0.1", H.closed_port())

    {:ok, config} =
      Notification.configure(
        binding: binding,
        tenant: "fixture",
        credentials: fn -> {:ok, {"fixture", "fixture"}} end,
        transport_supervisor: tasks,
        tls: :plaintext_loopback
      )

    {:ok, b, _} = Binding.load(binding)

    payload =
      Jason.encode!(%{
        "version" => 1,
        "to" => ["reader@example.test"],
        "subject" => "fixture",
        "text" => "fixture",
        "html" => nil
      })

    {:ok, permit} = C.admit(smtp_owner)

    reply =
      Adapter.send_effect(%{
        context: config,
        key: String.duplicate("a", 64),
        attempt_id: "one",
        binding: b.digest,
        arguments: payload,
        arguments_digest: :crypto.hash(:sha256, payload),
        schema: Adapter.schema()
      })

    assert reply == {:error, :connect_failed, :smtp}
    assert smtp_health(reply) == :unhealthy
    assert C.finish(smtp_owner, permit, smtp_health(reply)) == {:ok, :applied}
    assert mode(smtp_owner) == :open
    # Declared throttling differs from the S3 Adapter's information loss.
    assert smtp_health({:error, :throttled, :smtp}) == :neutral
    assert smtp_health({:error, :connection_lost, :smtp}) == :unknown

    server = {_, busy_port} = SmtpServer.start(:busy)
    on_exit(fn -> SmtpServer.stop(server) end)
    busy_binding = SmtpServer.binding("127.0.0.1", busy_port)

    {:ok, busy_config} =
      Notification.configure(
        binding: busy_binding,
        tenant: "fixture",
        credentials: fn -> {:ok, {"fixture", "fixture"}} end,
        transport_supervisor: tasks,
        tls: :plaintext_loopback
      )

    {:ok, busy_b, _} = Binding.load(busy_binding)
    busy_owner = start_supervised!({C, name: :circuit_composition_busy}, id: :busy_circuit)
    {:ok, initial} = C.admit(busy_owner)
    assert C.finish(busy_owner, initial, :healthy) == {:ok, :applied}
    {:ok, busy_permit} = C.admit(busy_owner)

    busy_reply =
      Adapter.send_effect(%{
        context: busy_config,
        key: String.duplicate("b", 64),
        attempt_id: "busy",
        binding: busy_b.digest,
        arguments: payload,
        arguments_digest: :crypto.hash(:sha256, payload),
        schema: Adapter.schema()
      })

    assert busy_reply == {:error, :session_throttled, :smtp}
    assert smtp_health(busy_reply) == :neutral
    assert C.finish(busy_owner, busy_permit, smtp_health(busy_reply)) == {:ok, :applied}
    assert mode(busy_owner) == :closed

    # Circuit permit retirement neither releases a Runner's slot nor a task
    # supervisor's physical capacity. The blocked Attempt owns both.
    parent = self()
    bounded = start_supervised!({Task.Supervisor, max_children: 1}, id: :bounded_tasks)
    {:ok, policy} = R.policy([])

    runner =
      start_supervised!(
        {R.Runner,
         capacity: 1,
         policy: policy,
         task_supervisor: bounded,
         attempt_timeout_ms: 10_000,
         attempt: fn _ ->
           send(parent, {:attempt, self()})

           receive do
             :done -> :bad
           end
         end,
         dead_letter: fn _ -> :ok end}
      )

    envelope = %{
      "version" => 1,
      "message_id" => "blocked",
      "schema_id" => "fixture",
      "schema_version" => 1,
      "kind" => "command",
      "producer" => %{"unit_id" => "caller", "port_id" => "out"},
      "payload" => "x"
    }

    assert {:ok, _} = R.Runner.submit(runner, envelope)
    assert_receive {:attempt, attempt_pid}
    {:ok, p} = C.admit(owner)
    assert C.abandon(owner, p) == {:ok, :applied}

    assert {:error, {:saturated, _}} =
             R.Runner.submit(runner, Map.put(envelope, "message_id", "second"))

    assert Task.Supervisor.start_child(bounded, fn -> :ok end) == {:error, :max_children}
    assert Process.alive?(attempt_pid)
    send(attempt_pid, :done)
  end
end
