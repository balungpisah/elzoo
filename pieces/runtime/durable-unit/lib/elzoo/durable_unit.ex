# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableUnit do
  @moduledoc "Input-before-transition Unit with retained identities and committed outbox offers."
  use GenServer, restart: :transient
  alias Elzoo.{Checkpoint, Outbox}
  alias Elzoo.DurableLog.{Codec, Writer}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def step(server, input_id, input), do: GenServer.call(server, {:step, input_id, input})
  def snapshot(server), do: GenServer.call(server, :snapshot)
  def checkpoint(server), do: GenServer.call(server, :checkpoint)
  def offer_pending(server), do: GenServer.call(server, :offer_pending)

  def limits(opts) do
    %{
      max_batch_size: 1,
      max_record_bytes: Keyword.fetch!(opts, :max_record_bytes),
      max_checkpoint_bytes: Keyword.fetch!(opts, :max_checkpoint_bytes)
    }
  end

  def fold(opts) do
    {_, _, initial} = Keyword.fetch!(opts, :operator)
    retention = Keyword.fetch!(opts, :retention_count)

    %{
      initial: %{state: initial, pending: nil, completed: []},
      kinds: %{"input" => :state_bearing, "result" => :state_bearing},
      versions: [1],
      destinations: ["outputs"],
      reduce: fn model, kind, 1, bytes ->
        case {kind, decode(bytes), model.pending} do
          {"input", {id, input}, nil} ->
            true = input_id?(id) and not List.keymember?(model.completed, id, 0)
            %{model | pending: {id, input}}

          {"result", {id, next}, {id, input}} ->
            completed = Enum.take(model.completed ++ [{id, digest(input)}], -retention)
            %{model | state: next, pending: nil, completed: completed}
        end
      end
    }
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with :ok <- validate_options(opts),
         {:ok, writer} <-
           Writer.start_link(
             store: Keyword.fetch!(opts, :store),
             stream: Keyword.fetch!(opts, :stream),
             fold: fold(opts),
             limits: limits(opts),
             checkpoint: %{fold_version: 1, decode: fn bytes -> {:ok, decode(bytes)} end}
           ) do
      state = %{
        writer: writer,
        store: Keyword.fetch!(opts, :store),
        stream: Keyword.fetch!(opts, :stream),
        operator: Keyword.fetch!(opts, :operator),
        max_record_bytes: Keyword.fetch!(opts, :max_record_bytes),
        offer: Keyword.fetch!(opts, :offer),
        model: Writer.snapshot(writer).model
      }

      case finish_pending(state) do
        {:ok, state} ->
          offer_pass(state)
          {:ok, state}

        {:stop, reason, _, state} ->
          stop_writer(state)
          {:stop, {:shutdown, reason}}
      end
    else
      {:error, :invalid_options} -> {:stop, :invalid_options}
      _ -> {:stop, {:shutdown, :durable_unit_recovery_failed}}
    end
  catch
    _, _ -> {:stop, {:shutdown, :durable_unit_recovery_failed}}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, state.model.state, state}
  def handle_call(:offer_pending, _, state), do: {:reply, offer_pass(state), state}

  def handle_call(:checkpoint, _, state) do
    case writer_call(fn -> Checkpoint.take(state.writer, state.stream, 1, &encode/1) end) do
      {:indeterminate, info} ->
        {:stop, {:shutdown, :durable_unit_indeterminate}, {:indeterminate, info}, state}

      reply ->
        {:reply, reply, state}
    end
  end

  def handle_call({:step, id, input}, _, state) do
    case intake(state, id, input) do
      {:ok, reply, state} -> {:reply, reply, state}
      {:stop, reason, reply, state} -> {:stop, {:shutdown, reason}, reply, state}
    end
  end

  @impl true
  def handle_info({:durable_unit_input, id, input}, state) do
    case intake(state, id, input) do
      {:ok, _, state} -> {:noreply, state}
      {:stop, reason, _, state} -> {:stop, {:shutdown, reason}, state}
    end
  end

  def handle_info({:EXIT, writer, _}, %{writer: writer} = state),
    do: {:stop, {:shutdown, :durable_unit_indeterminate}, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: stop_writer(state)

  defp intake(state, id, input) do
    bytes = encode({id, input})

    cond do
      not input_id?(id) ->
        {:ok, {:error, :invalid_input}, state}

      byte_size(bytes) > state.max_record_bytes ->
        {:ok, {:error, :input_too_large}, state}

      true ->
        case List.keyfind(state.model.completed, id, 0) do
          {^id, hash} ->
            reply =
              if hash == digest(input),
                do: {:ok, :duplicate},
                else: {:error, :input_id_conflict}

            {:ok, reply, state}

          nil ->
            case append(state, "input", bytes, []) do
              {:ok, state} ->
                case finish_pending(state) do
                  {:ok, state} ->
                    offer_pass(state)
                    {:ok, {:ok, :applied}, state}

                  stopped ->
                    stopped
                end

              {:stop, :durable_unit_storage_rejected, reply, state} ->
                {:ok, reply, state}

              stopped ->
                stopped
            end
        end
    end
  end

  defp finish_pending(%{model: %{pending: nil}} = state), do: {:ok, state}

  defp finish_pending(state) do
    case transition(state) do
      {:ok, result, items} -> append(state, "result", result, items)
      :error -> failure(state, :durable_unit_transition_failed)
    end
  end

  defp transition(state) do
    {module, function, _} = state.operator
    {id, input} = state.model.pending
    {:Transition, next, output} = apply(module, function, [state.model.state, input])
    result = encode({id, next})

    items =
      case output do
        :none -> []
        {:some, value} -> [{"outputs", encode(value)}]
      end

    if byte_size(result) <= state.max_record_bytes and
         Enum.all?(items, fn {_, bytes} -> byte_size(bytes) <= state.max_record_bytes end),
       do: {:ok, result, items},
       else: :error
  catch
    _, _ -> :error
  end

  defp append(state, kind, bytes, items) do
    case writer_call(fn ->
           with {:committed, _} <- Writer.append(state.writer, [{kind, 1, bytes}], items) do
             {:ok, Writer.snapshot(state.writer).model}
           end
         end) do
      {:ok, model} ->
        {:ok, %{state | model: model}}

      {:conflict, _} ->
        failure(state, :durable_unit_conflict)

      {:rejected, reason} ->
        {:stop, :durable_unit_storage_rejected, {:error, {:rejected, reason}}, state}

      {:indeterminate, info} ->
        {:stop, :durable_unit_indeterminate, {:indeterminate, info}, state}
    end
  end

  defp writer_call(call) do
    call.()
  catch
    :exit, _ -> {:indeterminate, :storage_unknown}
  end

  defp failure(state, reason), do: {:stop, reason, {:error, reason}, state}

  defp offer_pass(state) do
    case Outbox.pending(state.store, state.stream, 64) do
      {:ok, items} ->
        Enum.reduce_while(items, {:ok, 0}, fn item, {:ok, count} ->
          # Stores may return maps; callers always receive the existing Item type.
          case state.offer.(struct!(Outbox.Item, Map.delete(item, :__struct__))) do
            :ok -> {:cont, {:ok, count + 1}}
            _ -> {:halt, {:error, :offer_unavailable}}
          end
        end)

      _ ->
        {:error, :offer_unavailable}
    end
  catch
    _, _ -> {:error, :offer_unavailable}
  end

  defp stop_writer(state), do: Process.exit(state.writer, :shutdown)

  defp validate_options(opts) do
    {module, function, _} = Keyword.fetch!(opts, :operator)
    {store, _} = Keyword.fetch!(opts, :store)

    if is_atom(module) and is_atom(function) and is_atom(store) and
         Codec.stream?(Keyword.fetch!(opts, :stream)) and
         is_function(Keyword.fetch!(opts, :offer), 1) and
         Enum.all?([:retention_count, :max_record_bytes, :max_checkpoint_bytes], fn key ->
           value = Keyword.fetch!(opts, key)
           is_integer(value) and value > 0
         end),
       do: :ok,
       else: {:error, :invalid_options}
  catch
    _, _ -> {:error, :invalid_options}
  end

  defp input_id?(id), do: Codec.text?(id) and byte_size(id) in 1..160
  defp digest(input), do: :crypto.hash(:sha256, encode(input))
  defp encode(term), do: :erlang.term_to_binary({1, term}, [:deterministic, {:minor_version, 2}])

  defp decode(bytes) do
    {1, term} = :erlang.binary_to_term(bytes, [:safe])
    term
  end
end
