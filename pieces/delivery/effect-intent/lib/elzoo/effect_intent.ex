# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EffectIntent do
  @moduledoc """
  Serialized checkpoint-before-send owner. All recovery activations are read-only
  until a nonce/snapshot-bound trusted host callback grants activation.
  Every caller timeout is unknown; status is inspection, not a durable receipt.
  """
  use GenServer
  alias Elzoo.EffectIntent.{Binding, Model, Policy}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Store, Record}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def advance(pid, command), do: GenServer.call(pid, {:advance, command}, :infinity)
  def observe(pid, result), do: GenServer.call(pid, {:observe, result}, :infinity)
  def revise(pid, arguments), do: GenServer.call(pid, {:revise, arguments}, :infinity)
  def status(pid), do: GenServer.call(pid, :status)
  def limits, do: Model.limits()

  def fold(binding_module) do
    {:ok, b} = Binding.load(binding_module)
    Model.fold(b)
  end

  @impl true
  def init(opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         {:ok, b} <- Binding.load(opts[:binding]),
         true <- Model.valid_identity?(opts[:identity]),
         true <- is_binary(opts[:arguments]) and byte_size(opts[:arguments]) <= 65_536,
         true <- Binding.uint?(opts[:deadline]),
         true <- is_function(opts[:clock], 0),
         true <- not is_nil(opts[:task_supervisor]),
         {module, store_opts} = store when is_atom(module) and is_map(store_opts) <- opts[:store],
         true <-
           Enum.all?(Model.limits(), fn {k, v} ->
             Map.get(Map.get(store_opts, :limits, %{}), k, 0) >= v
           end),
         true <- module != Elzoo.DurableLog.Memory or opts[:allow_volatile] == true,
         key = Model.key(opts[:identity]),
         stream = Model.stream(key),
         snapshot when is_map(snapshot) <-
           Elzoo.Checkpoint.recover(store, stream, Model.fold(b), 1, &Model.decode(&1, b)),
         true <- clean?(snapshot),
         true <-
           snapshot.model == nil or
             (snapshot.model.identity == opts[:identity] and
                snapshot.model.arguments == opts[:arguments] and snapshot.model.binding == b.digest) do
      s = %{
        store: store,
        binding: b,
        key: key,
        stream: stream,
        snapshot: snapshot,
        clock: opts[:clock],
        supervisor: opts[:task_supervisor],
        context: opts[:adapter_context],
        active: false,
        halt: :host_reconciliation_required,
        tasks: %{},
        grant: nil
      }

      nonce = :crypto.strong_rand_bytes(16)
      request = snapshot_request(s, nonce)
      s = activate(s, opts[:host], request)

      if s.active and snapshot.model == nil do
        schema = safe(fn -> b.adapter.schema() end)
        delta = Model.admission(opts[:identity], opts[:arguments], schema, opts[:deadline], now(s))

        case commit(s, delta, true) do
          {:ok, s, _} -> {:ok, s}
          {:error, reason, s} -> {:ok, halt(s, {:admission, reason})}
        end
      else
        {:ok, s}
      end
    else
      _ -> {:stop, :invalid_options_or_recovery}
    end
  rescue
    _ -> {:stop, :invalid_options_or_recovery}
  end

  defp activate(s, {host, context}, request) when is_atom(host) do
    case safe(fn -> host.activate(context, request) end) do
      {:active, generation, grant} when is_map(grant) ->
        with true <- Map.take(grant, [:key, :nonce, :revision, :digest]) == request,
             true <-
               is_integer(generation) and generation in 1..4096 and grant[:generation] == generation,
             {:ok, head} <- Store.read(s.store, :head, [s.stream]),
             true <- head.revision == request.revision,
             reloaded when is_map(reloaded) <-
               Elzoo.Checkpoint.recover(
                 s.store,
                 s.stream,
                 Model.fold(s.binding),
                 1,
                 &Model.decode(&1, s.binding)
               ),
             true <- clean?(reloaded),
             refreshed = snapshot_request(%{s | snapshot: reloaded}, request.nonce),
             true <- refreshed == request do
          %{s | active: true, halt: nil, grant: grant, snapshot: reloaded}
        else
          _ -> %{s | halt: :grant_mismatch}
        end

      _ ->
        s
    end
  end

  defp activate(s, _, _), do: s

  defp snapshot_request(s, nonce) do
    revision = elem(s.snapshot.cursor, 0)

    encoded =
      if s.snapshot.model == nil,
        do: Model.binary({:empty_intent, 1, s.key}),
        else: Model.encode(s.snapshot.model)

    %{
      key: s.key,
      nonce: nonce,
      revision: revision,
      digest: Model.hash(<<1, revision::64, encoded::binary>>)
    }
  end

  defp clean?(%{model: nil, cursor: {0, false, []}, tail: :intact}), do: true
  defp clean?(%{model: %{events: n}, cursor: {n, false, []}, tail: :intact}), do: true
  defp clean?(_), do: false

  @impl true
  def handle_call(:status, _, s), do: {:reply, view(s), s}
  def handle_call(_, _, %{active: false} = s), do: {:reply, {:error, :read_only}, s}

  def handle_call({:advance, :poll}, _, s) do
    case launch(s, :poll) do
      {:ok, s} -> {:reply, {:ok, :polling}, s}
      {:error, r, s} -> {:reply, {:error, r}, s}
    end
  end

  def handle_call({:advance, command}, _, s) when command in [:dispatch, :rearm, :expire] do
    event = Map.fetch!(%{dispatch: :Arm, rearm: :Rearm, expire: :Expired}, command)

    case advance_event(s, event) do
      {:ok, s, action} -> {:reply, {:ok, action}, s}
      {:error, r, s} -> {:reply, {:error, r}, s}
    end
  end

  def handle_call({:revise, args}, _, s) do
    schema = safe(fn -> s.binding.adapter.schema() end)

    if is_binary(args) and byte_size(args) <= 65_536 and Binding.text?(schema) and
         safe(fn -> s.binding.adapter.validate(args, schema) end) == :ok do
      delta = Model.transition(:Revise, current(s), now(s), %{arguments: args, schema: schema})
      reply_commit(s, delta, true)
    else
      {:reply, {:error, :schema}, s}
    end
  end

  def handle_call({:observe, result}, _, s) when is_map(result) do
    {reply, s} = observe_result(s, result)
    {:reply, reply, s}
  end

  def handle_call({:observe, _}, _, s), do: {:reply, {:error, :invalid_observation}, s}
  def handle_call(_, _, s), do: {:reply, {:error, :command}, s}

  defp advance_event(s, :Arm) do
    m = s.snapshot.model
    schema = safe(fn -> s.binding.adapter.schema() end)

    if schema == m.schema and safe(fn -> s.binding.adapter.validate(m.arguments, schema) end) == :ok do
      with {:ok, config} <- Policy.config(s.binding, m.deadline, m.anchor, now(s)),
           true <- Policy.permitted?(m.policy, :Arm, config) do
        case commit(s, Model.transition(:Arm, current(s), elem(config, 1)), true) do
          {:ok, s, :Dispatch} ->
            case launch(s, :send) do
              {:ok, s} -> {:ok, s, :dispatched}
              {:error, r, s} -> {:error, r, s}
            end

          {:ok, s, _} ->
            {:error, :not_dispatchable, s}

          other ->
            other
        end
      else
        _ -> {:error, :not_dispatchable, s}
      end
    else
      case commit(s, Model.transition(:SchemaInvalid, current(s), now(s)), false) do
        {:ok, s, _} -> {:error, :schema, s}
        other -> other
      end
    end
  end

  defp advance_event(s, :Rearm) do
    with {:ok, c} <-
           Policy.config(s.binding, s.snapshot.model.deadline, s.snapshot.model.anchor, now(s)),
         true <- Policy.permitted?(s.snapshot.model.policy, :Rearm, c) do
      commit(s, Model.transition(:Rearm, current(s), elem(c, 1)), true)
    else
      _ -> {:error, :not_rearmable, s}
    end
  end

  defp advance_event(s, e), do: commit(s, Model.transition(e, current(s), now(s)), false)

  defp reply_commit(s, delta, barrier) do
    case commit(s, delta, barrier) do
      {:ok, s, a} -> {:reply, {:ok, a}, s}
      {:error, r, s} -> {:reply, {:error, r}, s}
    end
  end

  defp launch(s, operation) do
    m = s.snapshot.model
    n = current(s)

    if n == 0 or (operation == :poll and not match?({:Dispatched, _, _}, Policy.phase(m.policy))) do
      {:error, :not_pollable, s}
    else
      request = request(s, n)

      task =
        Task.Supervisor.async_nolink(
          s.supervisor,
          fn ->
            if operation == :send,
              do: s.binding.adapter.send_effect(request),
              else: s.binding.adapter.poll(request)
          end,
          shutdown: :brutal_kill
        )

      {:ok, %{s | tasks: Map.put(s.tasks, task.ref, {n, request, operation})}}
    end
  catch
    _, _ ->
      # A failure to start/track a task is not used as an Adapter no-send claim.
      {_, next} = observe_event(s, :Lost, current(s), {:task_start, :unknown})
      {:error, :task_start, next}
  end

  defp request(s, n) do
    m = s.snapshot.model
    {^n, schema, digest, binding, _} = Enum.at(m.attempts, n - 1)

    %{
      key: m.key,
      attempt: n,
      attempt_id: Model.attempt_id(m, n),
      arguments: if(Model.hash(m.arguments) == digest, do: m.arguments, else: nil),
      arguments_digest: digest,
      schema: schema,
      binding: binding,
      context: s.context
    }
  end

  @impl true
  def handle_info({ref, result}, s) when is_reference(ref) do
    case Map.pop(s.tasks, ref) do
      {nil, _} ->
        {:noreply, s}

      {{n, request, operation}, tasks} ->
        Process.demonitor(ref, [:flush])
        s = %{s | tasks: tasks}
        result = translate(s, result, request, operation)

        {_, s} =
          if s.active,
            do: observe_result(s, {:from_adapter, n, result}),
            else: {{:error, :read_only}, s}

        {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, s) do
    case Map.pop(s.tasks, ref) do
      {nil, _} ->
        {:noreply, s}

      {{n, _, _}, tasks} ->
        s = %{s | tasks: tasks}

        {_, s} =
          if s.active,
            do: observe_event(s, :Lost, n, {:task_down, reason}),
            else: {{:error, :read_only}, s}

        {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp translate(s, {:error, tag, detail}, request, :send) do
    case Map.fetch(s.binding.failures, tag) do
      {:ok, {outcome, dispatch, error}} ->
        {:mapped,
         %{
           "version" => 1,
           "message_id" => s.key,
           "correlation_id" => s.key,
           "attempt_id" => request.attempt_id,
           "outcome" => outcome,
           "dispatch" => dispatch,
           "error_class" => error
         }, detail}

      :error ->
        {:observed, {:unclassified, :unknown}}
    end
  end

  # Only the explicit poll/reconciliation boundary can issue provider evidence.
  # A send callback returning a poll-shaped value is an invalid observation.
  defp translate(_, {kind, _}, _, :send)
       when kind in [:pending, :unavailable, :unknown_to_provider, :no_effect],
       do: {:observed, {:invalid_send_evidence, kind}}

  defp translate(_, result, _, _), do: {:observed, result}

  defp observe_result(s, {:from_adapter, n, {:mapped, envelope, detail}}) do
    with {:ok, _} <- Elzoo.Envelope.validate_result(envelope) do
      observe_event(s, result_event(envelope), n, {envelope, detail})
    else
      _ -> observe_event(s, :Lost, n, :bad_mapping)
    end
  end

  defp observe_result(s, {:from_adapter, n, {:observed, {kind, evidence}}})
       when kind in [:pending, :unavailable, :unknown_to_provider, :no_effect] do
    # Poll evidence still requires binding authentication, even from our task.
    req = request(s, n)

    if safe(fn -> s.binding.adapter.authenticate({kind, evidence}, req) end) == :ok do
      event =
        Map.fetch!(
          %{
            pending: :Pending,
            unavailable: :Lost,
            unknown_to_provider: :ProviderUnknown,
            no_effect: :NoEffect
          },
          kind
        )

      observe_event(s, event, n, {kind, evidence})
    else
      observe_event(s, :Refused, n, :unauthenticated)
    end
  end

  defp observe_result(s, {:from_adapter, n, {:observed, result}}) do
    case observe_envelope(s, result) do
      {:error, :invalid_observation} -> observe_event(s, :Refused, n, :invalid_observation)
      other -> other
    end
  end

  defp observe_result(s, result) do
    case observe_envelope(s, result) do
      {:error, :invalid_observation} -> retain_refusal(s, result)
      other -> other
    end
  end

  # An invalid result can never settle an attempt, but a known correlated
  # attempt still owns its reserved first-refusal slot. Unattributable input
  # has no such slot and is rejected without changing durable state.
  defp retain_refusal(s, result) when is_map(result) do
    n = find_attempt(s.snapshot.model, result["attempt_id"])

    if is_integer(n) and result["message_id"] == s.key and result["correlation_id"] == s.key do
      case observe_event(s, :Refused, n, {:invalid_observation, result}) do
        {{:ok, :retained}, next} -> {{:refused, :retained}, next}
        other -> other
      end
    else
      {{:error, :invalid_observation}, s}
    end
  end

  defp retain_refusal(s, _), do: {{:error, :invalid_observation}, s}

  defp observe_envelope(s, result) do
    m = s.snapshot.model

    with {:ok, _} <- Elzoo.Envelope.validate_result(result),
         true <- result["message_id"] == s.key and result["correlation_id"] == s.key,
         n when is_integer(n) <- find_attempt(m, result["attempt_id"]),
         req = request(s, n),
         :ok <- safe(fn -> s.binding.adapter.validate_result(result, req) end),
         :ok <- safe(fn -> s.binding.adapter.authenticate(result, req) end) do
      observe_event(s, result_event(result), n, result)
    else
      _ -> {:error, :invalid_observation}
    end
  end

  defp find_attempt(m, id) when is_binary(id) do
    Enum.find_value(m.attempts, fn {n, _, _, _, _} -> if Model.attempt_id(m, n) == id, do: n end)
  end

  defp find_attempt(_, _), do: nil
  defp result_event(%{"outcome" => "completed"}), do: :Completed

  defp result_event(%{"dispatch" => "not_dispatched", "error_class" => "permanent"}),
    do: :PermanentNoSend

  defp result_event(%{"dispatch" => "not_dispatched"}), do: :NoSend
  defp result_event(%{"outcome" => "timed_out"}), do: :TimedOut
  defp result_event(%{"outcome" => "failed"}), do: :Failed
  defp result_event(_), do: :Lost

  defp observe_event(s, event, n, raw) do
    time = now(s)

    evidence =
      if event in [:Pending, :Lost, :TimedOut, :Failed, :Resume],
        do: %{},
        else: %{evidence: Model.evidence(event, n, time, raw)}

    delta = Model.transition(event, n, time, evidence)

    case commit(s, delta, false) do
      {:ok, s, _} ->
        {{:ok, if(map_size(evidence) == 0, do: :counted, else: :retained)}, s}

      {:error, r, s} ->
        critical =
          Policy.classify(s.snapshot.model.policy, event, n) in [
            :Contradiction,
            :Completed,
            :NoSend,
            :PermanentNoSend,
            :NoEffect
          ]

        {{:not_retained, r}, if(critical, do: halt(s, {:evidence, r}), else: s)}
    end
  end

  defp commit(s, delta, checkpoint?) do
    expected = elem(s.snapshot.cursor, 0)

    with {:ok, next, action} <- Model.apply_delta(s.snapshot.model, delta, s.binding),
         payload = Model.binary(delta),
         :ok <-
           Log.preflight(
             %{stream: s.stream, expected: expected, records: [{"intent", 1, payload}], outbox: []},
             Model.fold(s.binding),
             Model.limits()
           ),
         true <- Model.reserved_checkpoint_size(next) <= Model.limits().max_checkpoint_bytes,
         row = %Record{
           stream: s.stream,
           sequence: expected + 1,
           kind: "intent",
           schema_version: 1,
           payload: payload,
           nonce: :crypto.strong_rand_bytes(16)
         },
         row = %{row | digest: Log.digest(row)},
         req = %{
           operation: :append,
           stream: s.stream,
           expected: expected,
           target: expected + 1,
           nonce: row.nonce,
           digest: row.digest
         },
         {:committed, revision} <-
           Store.write(s.store, :append, [s.stream, expected, [row], []], req) do
      snapshot = Log.replay([row], revision, Map.put(Model.fold(s.binding), :resume, s.snapshot))

      if clean?(snapshot) and snapshot.model == next do
        s = %{s | snapshot: snapshot}

        if checkpoint? do
          case Elzoo.Checkpoint.take(
                 {s.store, snapshot, Model.limits()},
                 s.stream,
                 1,
                 &Model.encode/1
               ) do
            {:committed, ^revision} -> {:ok, s, action}
            result -> {:error, {:checkpoint, result}, halt(s, {:checkpoint, result})}
          end
        else
          {:ok, s, action}
        end
      else
        {:error, :fold_mismatch, halt(s, :fold_mismatch)}
      end
    else
      {:error, reason} -> {:error, reason, s}
      false -> {:error, :checkpoint_capacity, s}
      {:rejected, reason} -> {:error, reason, s}
      result -> {:error, {:write, result}, halt(s, {:write, result})}
    end
  rescue
    _ -> {:error, :write_unknown, halt(s, :write_unknown)}
  catch
    _, _ -> {:error, :write_unknown, halt(s, :write_unknown)}
  end

  defp halt(s, reason), do: %{s | active: false, halt: reason}

  defp current(s),
    do: if(s.snapshot.model == nil, do: 0, else: Policy.count(s.snapshot.model.policy))

  defp now(s), do: safe(s.clock)

  defp safe(fun) do
    fun.()
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp view(s) do
    m = s.snapshot.model

    %{
      key: s.key,
      phase: if(m == nil, do: :absent, else: Policy.phase(m.policy)),
      active: s.active,
      reason: if(s.active, do: nil, else: :read_only),
      revision: elem(s.snapshot.cursor, 0),
      attempts: current(s),
      flags: if(m == nil, do: %{}, else: Policy.flags(m.policy)),
      evidence: if(m == nil, do: 0, else: map_size(m.evidence))
    }
  end
end
