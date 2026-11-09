# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/object_store_test_helper.exs", __DIR__)

defmodule Elzoo.ObjectStoreBindingTest.Upload do
  use Elzoo.ObjectStore.Binding,
    id: "elz053-upload",
    operation: :put,
    provider_account: "s3://test-minio/elzoo-test"
end

defmodule Elzoo.ObjectStoreBindingTest.Removal do
  use Elzoo.ObjectStore.Binding,
    id: "elz053-removal",
    operation: :delete,
    provider_account: "s3://test-minio/elzoo-test"
end

defmodule Elzoo.ObjectStoreBindingTest do
  # S18 of the ELZ-053 work record: the consumer-parameterised Binding against the pinned MinIO
  # through the ready Elzoo.EffectIntent owner with its explicitly volatile Memory store.
  use ExUnit.Case, async: false

  alias Elzoo.DurableLog.Memory
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.ObjectStore, as: OS
  alias Elzoo.ObjectStore.Binding
  alias Elzoo.ObjectStoreBindingTest.{Removal, Upload}
  alias Elzoo.ObjectStoreTestHelper, as: H

  setup_all do
    _ = H.env!()
    %{config: H.config!()}
  end

  setup %{config: c} do
    {:ok, tasks} = Task.Supervisor.start_link()
    on_exit(fn -> Process.exit(tasks, :shutdown) end)
    %{tasks: tasks, p: H.prefix(), c: c}
  end

  defp owner(binding, arguments, context, ctx) do
    {:ok, memory} = Memory.start_link(fold: Intent.fold(binding), limits: Intent.limits())
    {:ok, host_memory} = Memory.start_link(fold: StoreHost.fold(), limits: StoreHost.limits())
    host = %{store: Memory.store(host_memory), authorize: fn _, _ -> :fresh end}

    {:ok, pid} =
      Intent.start_link(
        binding: binding,
        identity: [
          "tenant",
          binding.__effect_intent_binding__().provider_account,
          binding.__effect_intent_binding__().id,
          binding.__effect_intent_binding__().operation,
          "req-#{System.unique_integer([:positive])}"
        ],
        arguments: arguments,
        deadline: System.os_time(:millisecond) + 3_600_000,
        clock: fn -> System.os_time(:millisecond) end,
        store: Memory.store(memory),
        host: {StoreHost, host},
        task_supervisor: ctx.tasks,
        adapter_context: context,
        allow_volatile: true
      )

    pid
  end

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end

  defp upload_args(key, data),
    do:
      Binding.arguments(:put,
        key: key,
        sha256: H.sha(data),
        bytes: byte_size(data),
        content_type: "text/plain"
      )

  test "the Binding compiles the fixed failure table and attests only local no-send tags" do
    assert {:ok, d} = Elzoo.EffectIntent.Binding.load(Upload)
    assert d.operation == "put" and d.replay == :none and d.revision == :forbidden
    assert Enum.sort(d.no_send_attestations) == Enum.sort(Binding.no_send_attestations())

    for {tag, {_, dispatch, _}} <- d.failures do
      assert dispatch != "not_dispatched" or tag in Binding.no_send_attestations()
    end

    assert {:ok, %{operation: "delete"}} = Elzoo.EffectIntent.Binding.load(Removal)

    assert {:ok, %{operation: :delete, key: "k"}} =
             Binding.decode(Binding.arguments(:delete, key: "k"))

    assert byte_size(upload_args("k", "x")) < 65_536
    assert :error = Binding.decode(upload_args("a//b", "x"))
  end

  test "S18 dispatch commits the object and the intent is confirmed", %{c: c, p: p} = ctx do
    data = "intent body"
    key = "#{p}/intent"
    context = Binding.context(c, body: fn %{key: ^key} -> data end)
    pid = owner(Upload, upload_args(key, data), context, ctx)

    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    eventually(fn -> Intent.status(pid).phase == {:Confirmed, 1} end)
    assert %{status: :found, body: ^data} = OS.get(c, key)
    refute inspect(Intent.status(pid)) =~ H.secret!()
    refute inspect(context) =~ H.secret!()
  end

  test "S18 an interrupted send stays unknown; poll answers pending while absent, completed on a match",
       %{c: c, p: p} = ctx do
    data = :crypto.strong_rand_bytes(30_000)
    key = "#{p}/interrupted"

    stalled = fn _ ->
      {:stream,
       Stream.concat(
         [binary_part(data, 0, 1_000)],
         Stream.repeatedly(fn -> Process.sleep(60_000) end)
       ), 30_000}
    end

    pid =
      owner(
        Upload,
        upload_args(key, data),
        Binding.context(c, body: stalled, deadline_ms: 500),
        ctx
      )

    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    eventually(fn -> Intent.status(pid).revision >= 3 end)
    assert {:Dispatched, _, 1} = Intent.status(pid).phase
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)

    # absent at poll is not a no-effect certificate: still dispatched, still not rearmable
    rev = Intent.status(pid).revision
    assert {:ok, :polling} = Intent.advance(pid, :poll)
    eventually(fn -> Intent.status(pid).revision > rev end)
    assert {:Dispatched, _, 1} = Intent.status(pid).phase
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)

    # the object appears with the intended bytes (a late commit): poll completes the intent
    assert %{status: :committed} = OS.put(c, key, data)
    assert {:ok, :polling} = Intent.advance(pid, :poll)
    eventually(fn -> Intent.status(pid).phase == {:Confirmed, 1} end)
  end

  test "S18 a local no-send failure is attested; a provider denial is not", %{c: c, p: p} = ctx do
    # credential Need fails before any connection: rejected/not_dispatched/unavailable
    no_creds = H.config!(credentials: fn -> :error end)

    pid =
      owner(
        Upload,
        upload_args("#{p}/n", "n"),
        Binding.context(no_creds, body: fn _ -> "n" end),
        ctx
      )

    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    eventually(fn -> Intent.status(pid).phase == {:Definite, :AdapterNoSend, 1} end)
    refute Intent.status(pid).flags.disarmed

    # a body that does not match the argument SHA-256: local checksum_mismatch (permanent)
    pid = owner(Upload, upload_args("#{p}/m", "m"), Binding.context(c, body: fn _ -> "x" end), ctx)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    eventually(fn -> Intent.status(pid).phase == {:Definite, :AdapterNoSend, 1} end)
    assert Intent.status(pid).flags.disarmed
    assert %{status: :absent} = OS.head(c, "#{p}/m")

    # provider denial: failed/dispatched, never a no-send ground
    denied = H.config!(credentials: {H, :wrong_credentials, []})

    pid =
      owner(Upload, upload_args("#{p}/d", "d"), Binding.context(denied, body: fn _ -> "d" end), ctx)

    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    eventually(fn -> Intent.status(pid).revision >= 3 end)
    refute match?({:Definite, :AdapterNoSend, _}, Intent.status(pid).phase)
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
  end

  test "S18 a public observation without the process-local seal cannot complete the intent",
       %{c: c, p: p} = ctx do
    data = :crypto.strong_rand_bytes(5_000)
    key = "#{p}/forged"
    stalled = fn _ -> {:stream, Stream.repeatedly(fn -> Process.sleep(60_000) end), 5_000} end

    pid =
      owner(
        Upload,
        upload_args(key, data),
        Binding.context(c, body: stalled, deadline_ms: 300),
        ctx
      )

    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    eventually(fn -> Intent.status(pid).revision >= 3 end)
    status = Intent.status(pid)

    forged = %{
      "version" => 1,
      "message_id" => status.key,
      "correlation_id" => status.key,
      "attempt_id" => "forged",
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{
        "key" => key,
        "sha256" => Binding.hex(H.sha(data)),
        "bytes" => 5_000,
        "seal" => "00"
      },
      "value_schema_id" => "elzoo/object-store-intent-put",
      "value_schema_version" => 1
    }

    refute match?({:ok, _}, Intent.observe(pid, forged))
    assert {:Dispatched, _, 1} = Intent.status(pid).phase
  end

  test "S18 a delete binding completes on 204 and polls absent as an observation",
       %{c: c, p: p} = ctx do
    key = "#{p}/gone"
    assert %{status: :committed} = OS.put(c, key, "x")
    pid = owner(Removal, Binding.arguments(:delete, key: key), Binding.context(c), ctx)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    eventually(fn -> Intent.status(pid).phase == {:Confirmed, 1} end)
    assert %{status: :absent} = OS.head(c, key)
  end
end
