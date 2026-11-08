# SPDX-License-Identifier: Apache-2.0
# A bounded in-memory demonstration, NOT a deployed durable provider binding.
defmodule Elzoo.EffectIntent.ExampleAdapter do
  def failure_tags, do: [:timeout]
  def schema, do: "v1"
  def validate(bytes, "v1"), do: if(is_binary(bytes), do: :ok, else: :error)

  def send_effect(req) do
    send(req.context, {:example_send, req.attempt_id})
    {:error, :timeout, :unknown}
  end

  def poll(_), do: {:pending, :example_only}
  def authenticate({:pending, :example_only}, _), do: :ok
  def authenticate(_, _), do: :error
  def validate_result(_, _), do: :error
end

defmodule Elzoo.EffectIntent.ExampleBinding do
  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.EffectIntent.ExampleAdapter,
    id: "example",
    provider_account: "demo",
    operation: "publish",
    clock: "unix-ms",
    failures: %{timeout: {"timed_out", "unknown", "retryable"}},
    no_send_attestations: [],
    replay: :none
end

defmodule Elzoo.EffectIntent.Example do
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.{ExampleBinding, StoreHost}
  alias Elzoo.DurableLog.Memory

  def run do
    {:ok, memory} = Memory.start_link(fold: Intent.fold(ExampleBinding), limits: Intent.limits())
    {:ok, host_memory} = Memory.start_link(fold: StoreHost.fold(), limits: StoreHost.limits())
    {:ok, tasks} = Task.Supervisor.start_link()
    host = %{store: Memory.store(host_memory), authorize: fn _, _ -> :fresh end}

    opts = [
      binding: ExampleBinding,
      identity: ["tenant", "demo", "example", "publish", "one"],
      arguments: "hello",
      deadline: 5000,
      clock: fn -> 100 end,
      store: Memory.store(memory),
      host: {StoreHost, host},
      task_supervisor: tasks,
      adapter_context: self(),
      allow_volatile: true
    ]

    {:ok, owner} = Intent.start_link(opts)
    {:ok, :dispatched} = Intent.advance(owner, :dispatch)

    receive do
      {:example_send, _} -> :ok
    after
      1000 -> raise "missing first send"
    end

    {:error, :not_rearmable} = Intent.advance(owner, :rearm)
    {:error, :not_dispatchable} = Intent.advance(owner, :dispatch)
    GenServer.stop(owner)
    {:ok, recovered} = Intent.start_link(opts)
    %{phase: {:Dispatched, :Fresh, 1}, active: false} = Intent.status(recovered)
    {:error, :read_only} = Intent.advance(recovered, :dispatch)
    GenServer.stop(recovered)
    Supervisor.stop(tasks)
    GenServer.stop(memory)
    GenServer.stop(host_memory)
    :ok
  end
end

Elzoo.EffectIntent.Example.run()
