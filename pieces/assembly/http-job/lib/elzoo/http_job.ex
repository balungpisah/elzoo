# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.HttpJob do
  @moduledoc "Bounded immutable HTTP publication over existing EffectIntent and Jobs; consumers own persistence, recovery and queue lifecycle."
  alias Elzoo.HttpJob.{Config, Binding, Wire, Call, Policy}
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.Telemetry

  @required [
    :binding,
    :origin,
    :transport_supervisor,
    :caller_supervisor,
    :credentials,
    :authenticate,
    :resolve_intent,
    :tenant,
    :queue
  ]
  @optional [
    :observer,
    :maximum,
    :total_ms,
    :connect_ms,
    :receive_ms,
    :call_ms,
    :observer_ms,
    :poll_seconds
  ]

  def configure(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         map = Map.new(opts),
         true <- map_size(map) == length(opts) and Enum.all?(@required, &Map.has_key?(map, &1)),
         true <- Enum.all?(Map.keys(map), &(&1 in (@required ++ @optional))),
         {:ok, b} <- Elzoo.EffectIntent.Binding.load(map.binding),
         true <-
           b.adapter == Elzoo.HttpJob.Adapter and b.replay == :none and b.revision == :forbidden,
         true <- b.failures == Binding.failures() and b.operation == "publication",
         true <- Binding.origin?(map.origin) and map.origin == b.provider_account,
         true <- Wire.text?(map.tenant, 128) and Wire.text?(map.queue, 128),
         true <-
           is_function(map.credentials, 0) and is_function(map.authenticate, 2) and
             is_function(map.resolve_intent, 1),
         c =
           struct(
             Config,
             Map.merge(
               %{
                 maximum: 3,
                 total_ms: 3000,
                 connect_ms: 1000,
                 receive_ms: 1000,
                 call_ms: 35_000,
                 observer_ms: 100,
                 poll_seconds: 4,
                 observer: fn _ -> :ok end
               },
               map
             )
           ),
         true <- valid_limits?(c),
         true <- is_integer(b.recovery_grace_ms),
         true <- div(b.recovery_grace_ms + c.poll_seconds * 1000 - 1, c.poll_seconds * 1000) <= 512,
         {:ok, policy} <-
           Elzoo.RetryTimeout.policy(
             max_attempts: 16,
             base_backoff_ms: 1000,
             max_backoff_ms: 30_000
           ) do
      {:ok, %{c | retry_policy: policy}}
    else
      _ -> {:error, :configuration}
    end
  rescue
    _ -> {:error, :configuration}
  end

  def configure(_), do: {:error, :configuration}

  defp valid_limits?(c) do
    Enum.all?(
      [
        {c.maximum, 1, 16},
        {c.total_ms, 1, 3000},
        {c.connect_ms, 1, 1000},
        {c.receive_ms, 1, 1000},
        {c.call_ms, 1, 60_000},
        {c.observer_ms, 1, 1000},
        {c.poll_seconds, div(c.total_ms + 999, 1000) + 1, 30}
      ],
      fn {v, lo, hi} -> is_integer(v) and v >= lo and v <= hi end
    ) and
      is_function(c.observer, 1) and c.transport_supervisor != c.caller_supervisor
  end

  @doc "Consumer-owned finite task pool; use separate instances for owner, transport and runner calls."
  def task_spec(name, max_children) when is_atom(name) and max_children in 1..64,
    do: Supervisor.child_spec({Task.Supervisor, name: name, max_children: max_children}, id: name)

  @doc "Validate declaration and return exact Intent admission fields; does not create an owner or enqueue."
  def admission(%Config{} = c, declaration) do
    with {:ok, _} <- Elzoo.Effect.validate(declaration),
         "untrusted" <- declaration["classification"],
         "integration/http" <- declaration["capability_id"],
         "publication" <- declaration["operation"],
         command = declaration["command"],
         "elzoo/publication" <- command["schema_id"],
         1 <- command["schema_version"],
         ref when is_binary(ref) <- command["idempotency_key"],
         true <- Wire.text?(ref, 128),
         deadline
         when is_integer(deadline) and deadline >= 0 and deadline <= 9_223_372_036_854_775_807 <-
           command["deadline_unix_ms"],
         :ok <- Wire.publication(command["payload"]),
         {:ok, b} <- Elzoo.EffectIntent.Binding.load(c.binding),
         true <- b.provider_account == c.origin,
         {:ok, _} <- Elzoo.EffectIntent.Binding.recovery_deadline(deadline, b.recovery_grace_ms) do
      identity = [c.tenant, b.provider_account, b.id, b.operation, ref]

      {:ok,
       %{
         key: Elzoo.EffectIntent.Model.key(identity),
         identity: identity,
         arguments: command["payload"],
         deadline: deadline
       }}
    else
      _ -> {:error, :admission}
    end
  rescue
    _ -> {:error, :admission}
  end

  def admission(_, _), do: {:error, :admission}

  @doc "Runner callbacks for an explicitly consumer-owned Elzoo.Jobs queue registration."
  def runner(%Config{} = c),
    do: %{perform: &perform(c, &1), backoff: fn job -> backoff(c, job.attempt) end}

  defp backoff(c, n) do
    case Elzoo.RetryTimeout.backoff(c.retry_policy, min(max(n, 1), 16)) do
      {:ok, ms} -> div(ms + 999, 1000)
      _ -> 30
    end
  end

  def perform(
        %Config{} = c,
        %Oban.Job{args: %{"v" => 1, "queue" => queue, "job_key" => key} = args} = job
      ) do
    # ELZ-052: bounded :job events (observation only; results unchanged). No
    # emission sits inside a call_ms or observer_ms timer; the start event
    # precedes the owner's deadline reading: a handler's run time is elapsed time.
    mark = Telemetry.mark()
    meta = job_meta(c, key, job.attempt)

    Telemetry.emit(
      [:elzoo, :job, :start],
      Telemetry.compact(%{queue_wait: Telemetry.queue_wait(job.attempted_at, job.scheduled_at)}),
      meta
    )

    try do
      started = System.monotonic_time(:millisecond)

      result =
        if queue == c.queue and map_size(args) == 3 and Wire.hex?(key),
          do: tick(c, key),
          else: {:cancel, :invalid_job}

      observe(c, result, System.monotonic_time(:millisecond) - started)

      Telemetry.emit(
        [:elzoo, :job, :stop],
        %{duration: Telemetry.duration(mark)},
        Map.put(meta, :outcome, Telemetry.job_outcome(result))
      )

      result
    rescue
      _ -> job_exception(meta, mark, :error)
    catch
      kind, _ -> job_exception(meta, mark, kind)
    end
  rescue
    _ -> {:error, :owner_unavailable}
  catch
    _, _ -> {:error, :owner_unavailable}
  end

  def perform(_, _), do: {:cancel, :invalid_job}

  defp job_meta(c, key, attempt),
    do:
      Telemetry.compact(%{
        adapter: "assembly/http-job",
        operation: :perform,
        attempt: attempt,
        request_ref: if(Wire.hex?(key), do: key),
        queue: c.queue,
        tenant: c.tenant
      })

  defp job_exception(meta, mark, kind) do
    Telemetry.emit(
      [:elzoo, :job, :exception],
      %{duration: Telemetry.duration(mark)},
      Map.put(meta, :reason, Telemetry.reason(kind))
    )

    {:error, :owner_unavailable}
  end

  defp tick(c, key) do
    with {:ok, {:ok, pid}} <- call(c, fn -> c.resolve_intent.(key) end),
         true <- is_pid(pid),
         {:ok, status} <- call(c, fn -> Intent.status(pid) end),
         true <- status.key == key and status.active,
         {:ok, {:ok, _}} <- call(c, fn -> Intent.advance(pid, :expire) end),
         {:ok, current} <- call(c, fn -> Intent.status(pid) end),
         true <- current.key == key do
      act(c, pid, Policy.action(current, c.maximum))
    else
      _ -> {:error, :owner_unavailable}
    end
  end

  defp act(_, _, :JobFinish), do: :ok
  defp act(_, _, :JobOperator), do: {:cancel, :operator_required}
  defp act(_, _, :JobExhausted), do: {:cancel, :exhausted}

  defp act(c, pid, action) when action in [:JobDispatch, :JobPoll, :JobRearm] do
    command = %{JobDispatch: :dispatch, JobPoll: :poll, JobRearm: :rearm}[action]

    case {action, call(c, fn -> Intent.advance(pid, command) end)} do
      {:JobDispatch, {:ok, {:ok, :dispatched}}} ->
        {:snooze, c.poll_seconds}

      {:JobPoll, {:ok, {:ok, :polling}}} ->
        {:snooze, c.poll_seconds}

      {:JobPoll, {:ok, {:error, :task_start}}} ->
        {:snooze, c.poll_seconds}

      {:JobRearm, {:ok, {:ok, :Stop}}} ->
        {:snooze, 1}

      {:JobDispatch, {:ok, {:error, :not_dispatchable}}} ->
        confirm_refusal(c, pid, :JobDispatch, :not_dispatchable)

      {:JobRearm, {:ok, {:error, :not_rearmable}}} ->
        confirm_refusal(c, pid, :JobRearm, :exhausted)

      _ ->
        {:error, :owner_unavailable}
    end
  end

  defp act(_, _, _), do: {:error, :owner_unavailable}
  # Another live execution may have advanced the owner after our status read.
  # Reconcile once; never issue another owner command from this wake.
  defp confirm_refusal(c, pid, attempted, reason) do
    case call(c, fn -> Intent.status(pid) end) do
      {:ok, current} ->
        case Policy.action(current, c.maximum) do
          ^attempted -> {:cancel, reason}
          next when next in [:JobDispatch, :JobPoll, :JobRearm] -> {:snooze, c.poll_seconds}
          terminal -> act(c, pid, terminal)
        end

      _ ->
        {:error, :owner_unavailable}
    end
  end

  defp call(c, fun), do: Call.run(c.caller_supervisor, c.call_ms, fun)

  defp observe(c, result, elapsed) do
    tag =
      case result do
        :ok -> :confirmed
        {:snooze, _} -> :waiting
        {:cancel, _} -> :stopped
        _ -> :unavailable
      end

    Call.run(c.caller_supervisor, c.observer_ms, fn ->
      c.observer.(%{event: :http_job, outcome: tag, elapsed_ms: elapsed})
    end)

    :ok
  end

  @doc "Job-control only. Count zero is not cancellation; external outcome remains unknown."
  def cancel(%Config{} = c, oban, key) do
    if Wire.hex?(key) do
      case call(c, fn -> Elzoo.Jobs.cancel(oban, c.queue, key) end) do
        {:ok, {:ok, n}} when is_integer(n) and n >= 0 ->
          {:ok, %{cancelled_jobs: n, external_outcome: :unknown}}

        _ ->
          {:error, :unknown}
      end
    else
      {:error, :invalid_key}
    end
  end

  def cancel(_, _, _), do: {:error, :configuration}
end
