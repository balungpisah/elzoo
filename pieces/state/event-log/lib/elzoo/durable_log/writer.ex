# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.Writer do
  @moduledoc "Single-owner shell; store CAS, not process identity, arbitrates concurrent writers."
  use GenServer
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Record, Store}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def append(writer, records, items \\ [], timeout \\ 5_000),
    do: GenServer.call(writer, {:append, records, items}, timeout)

  def snapshot(writer), do: GenServer.call(writer, :snapshot)

  @impl true
  def init(opts) do
    {module, config} = Keyword.fetch!(opts, :store)

    state = %{
      store: {module, Map.put(Map.new(config), :repair_owner, self())},
      stream: Keyword.fetch!(opts, :stream),
      fold: Keyword.fetch!(opts, :fold),
      limits: Keyword.fetch!(opts, :limits),
      checkpoint: Keyword.get(opts, :checkpoint),
      replay: nil
    }

    with true <- Codec.fold_valid?(state.fold),
         :ok <- reconcile(state.store, state.stream, Keyword.get(opts, :reconcile)),
         {:ok, replay} <- load(state, true),
         :ok <- healthy(replay) do
      {:ok, %{state | replay: replay}}
    else
      false -> {:stop, :invalid_fold}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, state.replay, state}

  def handle_call({:append, records, items}, _, state) do
    expected = elem(state.replay.cursor, 0)
    request = %{stream: state.stream, expected: expected, records: records, outbox: items}

    case Log.preflight(request, state.fold, state.limits) do
      :ok -> append_validated(state, expected, records, items)
      rejected -> {:reply, rejected, state}
    end
  end

  def handle_call({:checkpoint, stream, version, encode}, _, state) do
    if stream == state.stream do
      reply =
        apply(:"Elixir.Elzoo.Checkpoint", :take, [
          {state.store, state.replay, state.limits},
          stream,
          version,
          encode
        ])

      case reply do
        {:indeterminate, info} -> {:stop, {:shutdown, {:indeterminate_write, info}}, reply, state}
        _ -> {:reply, reply, state}
      end
    else
      {:reply, {:rejected, :invalid_stream}, state}
    end
  end

  defp append_validated(state, expected, records, items) do
    nonce = :crypto.strong_rand_bytes(16)

    records =
      Enum.with_index(records, expected + 1)
      |> Enum.map(fn {{kind, version, payload}, sequence} ->
        row = %Record{
          stream: state.stream,
          sequence: sequence,
          kind: kind,
          schema_version: version,
          payload: payload,
          nonce: nonce
        }

        %{row | digest: Log.digest(row)}
      end)

    items =
      Enum.with_index(items, 1)
      |> Enum.map(fn {{destination, payload}, position} ->
        item = %{
          stream: state.stream,
          sequence: expected + length(records),
          position: position,
          destination: destination,
          payload: payload,
          nonce: nonce,
          state: :pending,
          ack_nonce: nil,
          ack_digest: nil,
          idempotency_key: Codec.item_key(state.stream, expected + length(records), position)
        }

        Map.put(item, :digest, Codec.hash(Codec.item_bytes(item)))
      end)

    request = %{
      operation: :append,
      stream: state.stream,
      expected: expected,
      target: expected + length(records),
      nonce: nonce,
      digest: Codec.hash(Enum.map(records, &Log.canonical_bytes/1))
    }

    reply = Store.write(state.store, :append, [state.stream, expected, records, items], request)

    case reply do
      {:committed, revision} ->
        fold = state.fold |> Map.put(:limits, state.limits) |> Map.put(:resume, state.replay)
        replay = Log.replay(records, revision, fold)

        case healthy(replay) do
          :ok -> {:reply, reply, %{state | replay: replay}}
          {:error, reason} -> {:stop, {:shutdown, reason}, reply, %{state | replay: replay}}
        end

      {:conflict, conflict} ->
        case load(state, false) do
          {:ok, replay} ->
            case healthy(replay) do
              :ok ->
                {:reply, {:conflict, conflict.observed}, %{state | replay: replay}}

              {:error, reason} ->
                {:stop, {:shutdown, reason}, {:conflict, conflict.observed}, state}
            end

          {:error, reason} ->
            {:stop, {:shutdown, reason}, {:conflict, conflict.observed}, state}
        end

      {:rejected, _} ->
        {:reply, reply, state}

      {:indeterminate, info} ->
        {:stop, {:shutdown, {:indeterminate_write, info}}, reply, state}
    end
  end

  defp reconcile(store, stream, request) do
    try do
      reconcile_request(store, stream, request)
    catch
      _, _ -> {:error, {:storage, :unfenced}}
    end
  end

  defp reconcile_request(_, _, nil), do: :ok

  defp reconcile_request(
         store,
         stream,
         %{operation: :append, expected: expected, nonce: nonce, records: records} = request
       ) do
    if Map.get(request, :stream) == stream do
      case Log.confirm(store, stream, expected, nonce, records) do
        {:committed, _} -> :ok
        :superseded -> :ok
        _ -> {:error, {:storage, :unfenced}}
      end
    else
      {:error, {:storage, :unfenced}}
    end
  end

  defp reconcile_request(store, stream, %{operation: operation, stream: stream} = request) do
    result =
      case operation do
        :put_checkpoint -> Log.confirm_checkpoint(store, Map.get(request, :checkpoint, %{}))
        :retain -> Log.confirm_retention(store, request)
        :ack -> Log.confirm_ack(store, request)
        :repair_torn_tail -> Log.confirm_repair(store, request)
        _ -> {:unknown, :unfenced}
      end

    case result do
      {:committed, _} -> :ok
      :superseded -> :ok
      _ -> {:error, {:storage, :unfenced}}
    end
  end

  defp reconcile_request(_, _, _), do: {:error, {:storage, :unfenced}}

  defp load(state, repair?) do
    result =
      with {:ok, _} <- Store.read(state.store, :head, [state.stream]) do
        case state.checkpoint do
          nil ->
            read_replay(state, 1, [])

          %{fold_version: version, decode: decode} ->
            apply(:"Elixir.Elzoo.Checkpoint", :recover, [
              state.store,
              state.stream,
              Map.put(state.fold, :limits, state.limits),
              version,
              decode
            ])
        end
      end

    case result do
      %{cursor: {_, true, diagnostics}} -> {:error, {:replay_damaged, diagnostics}}
      %{tail: :torn} when repair? -> repair(state)
      %{tail: :torn} -> {:error, {:storage, :unfenced}}
      %{cursor: _} = replay -> {:ok, replay}
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp repair(state) do
    with {:ok, head} <- Store.read(state.store, :head, [state.stream]),
         {:ok, _,
          %{
            capabilities: %{append_visibility: :staged_uncommitted_tail},
            staged_tail: %{nonce: staged_nonce}
          }} <- Log.read(state.store, state.stream, head.revision + 1, 2) do
      nonce = :crypto.strong_rand_bytes(16)

      request =
        Codec.receipt(
          :repair_torn_tail,
          state.stream,
          head.revision,
          head.revision,
          nonce,
          staged_nonce
        )

      case Store.write(
             state.store,
             :repair_torn_tail,
             [state.stream, head.revision, staged_nonce, nonce],
             request
           ) do
        {:committed, _} -> load(state, false)
        {:conflict, _} -> load(state, false)
        {:indeterminate, info} -> {:error, {:shutdown, {:indeterminate_write, info}}}
        {:rejected, reason} -> {:error, {:storage, reason}}
      end
    else
      {:error, reason} -> {:error, {:storage, reason}}
      _ -> {:error, {:storage, :unfenced}}
    end
  end

  defp read_replay(state, from, acc) do
    with {:ok, rows, head} <- Log.read(state.store, state.stream, from, 1_000) do
      last =
        Enum.reduce(rows, from - 1, fn row, seq ->
          if is_map(row) and is_integer(Map.get(row, :sequence)),
            do: max(seq, row.sequence),
            else: seq
        end)

      if length(rows) == 1_000 and last >= from,
        do: read_replay(state, last + 1, acc ++ rows),
        else:
          Log.replay(
            acc ++ rows,
            head,
            state.fold |> Map.delete(:resume) |> Map.put(:limits, state.limits)
          )
    end
  end

  defp healthy(%{cursor: {_, false, _}}), do: :ok
  defp healthy(%{cursor: {_, true, diagnostics}}), do: {:error, {:replay_damaged, diagnostics}}
end
