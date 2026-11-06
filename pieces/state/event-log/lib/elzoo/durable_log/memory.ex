# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.Memory do
  @moduledoc "Volatile CAS store with explicit, deterministic failure injection."
  use GenServer
  @behaviour Elzoo.DurableLog.Store
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Store}

  def start_link(opts) do
    if Codec.fold_valid?(Keyword.fetch!(opts, :fold)),
      do: GenServer.start_link(__MODULE__, opts),
      else: {:error, :invalid_fold}
  end

  def store(pid, opts \\ %{}) do
    configuration = GenServer.call(pid, :configuration)
    {__MODULE__, opts |> Map.merge(configuration) |> Map.put(:pid, pid)}
  end

  def fault(store, operation, fault), do: control(store, {:fault, operation, fault})
  def release(store, token), do: control(store, {:release, token})
  def fence(store, nonce), do: control(store, {:fence, nonce})
  def corrupt(store, table, key, changes), do: control(store, {:corrupt, table, key, changes})
  def inspect_state(store), do: control(store, :inspect)

  @doc "Test-only hooks for the adapter-neutral conformance scenarios."
  def conformance_hook(store, :inject, [op, mode]), do: fault(store, op, mode)
  def conformance_hook(store, :release, [token]), do: release(store, token)
  def conformance_hook(store, :reopen, []), do: store(elem(store, 1).pid)
  def conformance_hook(store, action, args), do: control(store, {:conformance, action, args})

  @impl true
  def capabilities({__MODULE__, opts}), do: %{append_visibility: opts.visibility}

  for {name, args} <- [
        head: [:stream],
        read: [:stream, :from, :limit],
        read_at: [:stream, :sequence],
        latest_checkpoint: [:stream, :version],
        pending: [:stream, :limit],
        read_ack: [:id],
        read_checkpoint: [:stream, :sequence, :version],
        read_maintenance: [:stream, :operation]
      ] do
    variables = Enum.map(args, &Macro.var(&1, nil))
    @impl true
    def unquote(name)(store, unquote_splicing(variables)),
      do: transport(store, unquote(name), [unquote_splicing(variables)])
  end

  @impl true
  def append({__MODULE__, opts} = store, stream, expected, records, items) do
    info = %{
      operation: :append,
      stream: stream,
      expected: expected,
      target: nil,
      nonce: nil,
      digest: nil
    }

    try do
      with :ok <- append_preflight(opts, stream, expected, records, items) do
        request = %{
          operation: :append,
          stream: stream,
          expected: expected,
          target: expected + length(records),
          nonce: hd(records).nonce,
          digest: Codec.hash(Enum.map(records, &Log.canonical_bytes/1))
        }

        write(store, :append, [stream, expected, records, items], request)
      end
    catch
      _, _ -> Store.unknown(info, :malformed_reply)
    end
  end

  defp append_preflight(opts, stream, expected, records, items) do
    tuples =
      if is_list(records),
        do:
          Enum.map(records, fn r ->
            if is_map(r),
              do: {Map.get(r, :kind), Map.get(r, :schema_version), Map.get(r, :payload)},
              else: :invalid
          end),
        else: records

    outbox =
      if is_list(items),
        do:
          Enum.map(items, fn i ->
            if is_map(i), do: {Map.get(i, :destination), Map.get(i, :payload)}, else: :invalid
          end),
        else: items

    Log.preflight(
      %{stream: stream, expected: expected, records: tuples, outbox: outbox},
      opts.fold,
      opts.limits
    )
  end

  @impl true
  def put_checkpoint(store, checkpoint) do
    if Codec.checkpoint_valid?(checkpoint) do
      request = %{
        operation: :put_checkpoint,
        stream: checkpoint.stream,
        expected: checkpoint.sequence,
        target: checkpoint.sequence,
        nonce: checkpoint.nonce,
        digest: checkpoint.digest
      }

      write(store, :put_checkpoint, [checkpoint], request)
    else
      Store.unknown(
        %{
          operation: :put_checkpoint,
          stream: nil,
          expected: nil,
          target: nil,
          nonce: nil,
          digest: nil
        },
        :malformed_reply
      )
    end
  end

  @impl true
  def retain(store, stream, expected, through, nonce),
    do:
      receipt_write(
        store,
        :retain,
        [stream, expected, through, nonce],
        stream,
        expected,
        through,
        nonce,
        <<>>
      )

  @impl true
  def ack(store, id, nonce) do
    case Codec.parse_key(id) do
      {:ok, _} ->
        if Codec.nonce?(nonce),
          do: write(store, :ack, [id, nonce], Codec.ack_receipt(id, nonce)),
          else: {:rejected, :invalid_outbox_item}

      _ ->
        {:rejected, :invalid_outbox_item}
    end
  end

  @impl true
  def repair_torn_tail(store, stream, expected, staged_nonce, nonce),
    do:
      receipt_write(
        store,
        :repair_torn_tail,
        [stream, expected, staged_nonce, nonce],
        stream,
        expected,
        expected,
        nonce,
        staged_nonce
      )

  defp receipt_write(store, operation, args, stream, expected, target, nonce, extra) do
    try do
      write(
        store,
        operation,
        args,
        Codec.receipt(operation, stream, expected, target, nonce, extra)
      )
    catch
      _, _ ->
        Store.unknown(
          %{
            operation: operation,
            stream: stream,
            expected: expected,
            target: target,
            nonce: nonce,
            digest: nil
          },
          :malformed_reply
        )
    end
  end

  defp write(store, op, args, request) do
    case transport(store, op, args) do
      {:fault, cause} -> Store.unknown(request, cause)
      reply -> Store.classify_write({:reply, reply}, request)
    end
  end

  defp transport({__MODULE__, opts}, op, args) do
    try do
      message =
        if op == :repair_torn_tail and Map.get(opts, :repair_owner) == self(),
          do: {:owning_repair, args},
          else: {:operation, op, args}

      GenServer.call(opts.pid, message, Map.get(opts, :timeout, 5_000))
    catch
      :exit, {:timeout, _} ->
        {:fault, :timeout}

      :exit, _ ->
        if op in [:append, :put_checkpoint, :retain, :ack, :repair_torn_tail],
          do: {:fault, :exit},
          else: {:error, :unavailable}
    end
  end

  defp control({__MODULE__, opts}, message), do: GenServer.call(opts.pid, message)

  @impl true
  def init(opts) do
    {:ok,
     %{
       heads: %{},
       records: %{},
       items: %{},
       checkpoints: %{},
       receipts: %{},
       staged: %{},
       aborted: MapSet.new(),
       paused: %{},
       faults: %{},
       fold: Keyword.fetch!(opts, :fold),
       limits: Keyword.fetch!(opts, :limits),
       visibility: Keyword.get(opts, :append_visibility, :staged_uncommitted_tail)
     }}
  end

  @impl true
  def handle_call(:inspect, _, state), do: {:reply, state, state}

  def handle_call(:configuration, _, state),
    do: {:reply, Map.take(state, [:fold, :limits, :visibility]), state}

  def handle_call({:conformance, :snapshot, []}, _, state),
    do:
      {:reply,
       Map.take(state, [:heads, :records, :items, :checkpoints, :receipts, :staged, :aborted]),
       state}

  def handle_call({:conformance, :rollback, [token]}, _, state),
    do: {:reply, :ok, %{state | paused: Map.delete(state.paused, token)}}

  def handle_call({:conformance, :duplicate_insert, [row]}, _, state) do
    key = {row.stream, row.sequence}

    if Map.has_key?(state.records, key),
      do: {:reply, {:error, :duplicate}, state},
      else: {:reply, :ok, put_in(state.records[key], row)}
  end

  def handle_call({:owning_repair, [stream, expected, staged_nonce, nonce] = args}, from, state) do
    state =
      case Map.get(state.staged, stream) do
        %{nonce: ^staged_nonce} = staged when state.visibility == :staged_uncommitted_tail ->
          if stream_head(state, stream).revision == expected and Codec.nonce?(nonce) do
            %{
              state
              | staged: Map.put(state.staged, stream, %{staged | fenced: true}),
                aborted: MapSet.put(state.aborted, staged_nonce)
            }
          else
            state
          end

        _ ->
          state
      end

    handle_call({:operation, :repair_torn_tail, args}, from, state)
  end

  def handle_call({:fault, op, fault}, _, state), do: {:reply, :ok, put_in(state.faults[op], fault)}

  def handle_call({:corrupt, table, key, changes}, _, state) do
    next = update_in(state, [table, key], &Map.merge(&1, changes))
    {:reply, :ok, next}
  end

  def handle_call({:fence, nonce}, _, state) do
    staged =
      Map.new(state.staged, fn {stream, entry} ->
        {stream, if(entry.nonce == nonce, do: %{entry | fenced: true}, else: entry)}
      end)

    {:reply, :ok, %{state | staged: staged, aborted: MapSet.put(state.aborted, nonce)}}
  end

  def handle_call({:release, token}, _, state) do
    case Map.pop(state.paused, token) do
      {nil, _} ->
        {:reply, {:error, :absent}, state}

      {{op, args}, paused} ->
        {reply, next} = safe_execute(op, args, %{state | paused: paused})
        {:reply, reply, next}
    end
  end

  def handle_call({:operation, op, args}, _, state) do
    {fault, faults} = Map.pop(state.faults, op)
    state = %{state | faults: faults}

    {reply, state} =
      case fault do
        :unavailable ->
          {{:error, :unavailable}, state}

        :malformed ->
          {:junk, state}

        {:pause, token} ->
          {{:fault, :timeout}, put_in(state.paused[token], {op, args})}

        :stage when op == :append ->
          stage(args, state)

        :reply_loss ->
          {_, next} = safe_execute(op, args, state)
          {{:fault, :unavailable}, next}

        :rollback ->
          safe_execute(op, args, state)
          {{:fault, :unavailable}, state}

        _ ->
          safe_execute(op, args, state)
      end

    {:reply, reply, state}
  end

  defp stream_head(state, stream), do: Map.get(state.heads, stream, %{revision: 0, low_water: 0})

  defp safe_execute(operation, args, state) do
    try do
      execute(operation, args, state)
    catch
      _, _ -> {{:error, :malformed}, state}
    end
  end

  defp conflict(expected, observed), do: {:conflict, %{expected: expected, observed: observed}}
  defp execute(:capabilities, [], state), do: {%{append_visibility: state.visibility}, state}
  defp execute(:head, [stream], state), do: {{:ok, stream_head(state, stream)}, state}

  defp execute(:read, [stream, from, limit], state) do
    h = stream_head(state, stream)

    if from <= h.low_water do
      {{:error, {:pruned, h.low_water}}, state}
    else
      rows =
        state.records
        |> Enum.filter(fn {{s, seq}, _} -> s == stream and seq >= from end)
        |> Enum.sort_by(fn {{_, seq}, _} -> seq end)
        |> Enum.map(&elem(&1, 1))

      {rows, h} =
        case Map.get(state.staged, stream) do
          %{records: [row | _], nonce: nonce} when state.visibility == :staged_uncommitted_tail ->
            if row.sequence >= from,
              do:
                {rows ++ [row],
                 Map.put(h, :staged_tail, %{sequence: row.sequence, nonce: nonce, uncommitted: true})},
              else: {rows, h}

          _ ->
            {rows, h}
        end

      {{:ok, Enum.take(rows, limit), h}, state}
    end
  end

  defp execute(:read_at, [stream, sequence], state) do
    h = stream_head(state, stream)

    if sequence <= h.low_water,
      do: {{:error, {:pruned, h.low_water}}, state},
      else: {{:ok, Map.get(state.records, {stream, sequence}, :absent), h}, state}
  end

  defp execute(:append, [stream, expected, records, items], state) do
    h = stream_head(state, stream)
    tuples = Enum.map(records, &{&1.kind, &1.schema_version, &1.payload})

    request = %{
      stream: stream,
      expected: expected,
      records: tuples,
      outbox: Enum.map(items, &{&1.destination, &1.payload})
    }

    valid = Log.preflight(request, state.fold, state.limits)

    cond do
      valid != :ok ->
        {valid, state}

      h.revision != expected ->
        {conflict(expected, h.revision), state}

      Enum.any?(records, &Map.has_key?(state.records, {stream, &1.sequence})) ->
        {conflict(expected, h.revision), state}

      Enum.any?(records, &MapSet.member?(state.aborted, &1.nonce)) ->
        {conflict(expected, h.revision), state}

      not valid_batch?(records, items, stream, expected, state) ->
        {{:rejected, :invalid_outbox_item}, state}

      true ->
        revision = expected + length(records)

        next = %{
          state
          | heads: Map.put(state.heads, stream, %{h | revision: revision}),
            records: Enum.reduce(records, state.records, &Map.put(&2, {stream, &1.sequence}, &1)),
            items: Enum.reduce(items, state.items, &Map.put(&2, &1.idempotency_key, &1)),
            staged: Map.delete(state.staged, stream)
        }

        {{:committed, revision}, next}
    end
  end

  defp execute(:put_checkpoint, [c], state) do
    h = stream_head(state, c.stream)
    key = {c.stream, c.sequence, c.fold_version}

    cond do
      not Codec.checkpoint_valid?(c) ->
        {{:error, :malformed}, state}

      byte_size(Codec.checkpoint_bytes(c)) + 32 > state.limits.max_checkpoint_bytes ->
        {{:rejected, :checkpoint_too_large}, state}

      c.sequence > h.revision ->
        {{:rejected, :checkpoint_beyond_tail}, state}

      Map.has_key?(state.checkpoints, key) ->
        {conflict(c.sequence, c.sequence), state}

      true ->
        {{:committed, c.sequence}, put_in(state.checkpoints[key], c)}
    end
  end

  defp execute(:latest_checkpoint, [stream, version], state) do
    c =
      state.checkpoints
      |> Enum.filter(fn {{s, _, v}, _} -> s == stream and v == version end)
      |> Enum.max_by(fn {{_, seq, _}, _} -> seq end, fn -> {nil, :none} end)
      |> elem(1)

    {{:ok, c}, state}
  end

  defp execute(:read_checkpoint, [stream, seq, version], state),
    do: {{:ok, Map.get(state.checkpoints, {stream, seq, version}, :absent)}, state}

  defp execute(:pending, [stream, limit], state) do
    rows =
      state.items
      |> Map.values()
      |> Enum.filter(&(&1.stream == stream and &1.state == :pending))
      |> Enum.sort_by(&{&1.sequence, &1.position})
      |> Enum.take(limit)

    {{:ok, rows}, state}
  end

  defp execute(:read_ack, [id], state), do: {{:ok, Map.get(state.items, id, :absent)}, state}

  defp execute(:ack, [id, nonce], state) do
    case Map.get(state.items, id) do
      %{state: :pending} = item ->
        if Codec.nonce?(nonce) and Codec.item_valid?(item) do
          receipt = Codec.ack_receipt(id, nonce)
          next = %{item | state: :acked, ack_nonce: nonce, ack_digest: receipt.digest}
          {{:committed, item.sequence}, put_in(state.items[id], next)}
        else
          {{:error, :malformed}, state}
        end

      _ ->
        {:ok, {_, seq, _}} = Codec.parse_key(id)
        {conflict(seq, :unknown), state}
    end
  end

  defp execute(:retain, [stream, expected, through, nonce], state) do
    h = stream_head(state, stream)

    anchor =
      Enum.any?(state.checkpoints, fn {{s, seq, _}, c} ->
        s == stream and seq >= through and Codec.checkpoint_valid?(c) and elem(c.cursor, 1) == false
      end)

    pending =
      Enum.any?(state.items, fn {_, i} ->
        i.stream == stream and i.state == :pending and i.sequence <= through
      end)

    cond do
      not Codec.uint?(expected) or not Codec.uint?(through) or expected >= through or
        through > h.revision or not Codec.nonce?(nonce) ->
        {{:rejected, :invalid_retention_range}, state}

      expected != h.low_water ->
        {conflict(expected, h.low_water), state}

      not anchor ->
        {{:rejected, :retention_beyond_checkpoint}, state}

      pending ->
        {{:rejected, :retention_beyond_pending_outbox}, state}

      true ->
        items =
          Map.reject(state.items, fn {_, i} ->
            i.stream == stream and i.sequence <= through and i.state == :acked
          end)

        records = Map.reject(state.records, fn {{s, seq}, _} -> s == stream and seq <= through end)
        receipt = Codec.receipt(:retain, stream, expected, through, nonce)

        next = %{
          state
          | items: items,
            records: records,
            heads:
              Map.put(
                state.heads,
                stream,
                Map.put(%{h | low_water: through}, :last_retention, receipt)
              ),
            receipts: Map.put(state.receipts, {stream, :retain}, receipt)
        }

        {{:committed, through}, next}
    end
  end

  defp execute(:read_maintenance, [stream, operation], state),
    do: {{:ok, Map.get(state.receipts, {stream, operation}, :absent)}, state}

  defp execute(:repair_torn_tail, [stream, expected, staged_nonce, nonce], state) do
    h = stream_head(state, stream)
    staged = Map.get(state.staged, stream)

    cond do
      state.visibility != :staged_uncommitted_tail ->
        {{:rejected, :torn_repair_unsupported}, state}

      h.revision != expected ->
        {conflict(expected, h.revision), state}

      staged == nil or staged.nonce != staged_nonce or not staged.fenced ->
        {{:rejected, :unfenced_tail}, state}

      not Codec.nonce?(nonce) ->
        {{:error, :malformed}, state}

      true ->
        receipt = Codec.receipt(:repair_torn_tail, stream, expected, expected, nonce, staged_nonce)

        next = %{
          state
          | staged: Map.delete(state.staged, stream),
            heads: Map.put(state.heads, stream, Map.put(h, :last_repair, receipt)),
            receipts: Map.put(state.receipts, {stream, :repair_torn_tail}, receipt)
        }

        {{:committed, expected}, next}
    end
  end

  defp valid_batch?(records, items, stream, expected, state) do
    nonce = hd(records).nonce

    Enum.with_index(records, expected + 1)
    |> Enum.all?(fn {r, seq} ->
      r.stream == stream and r.sequence == seq and r.nonce == nonce and
        Log.validate_row(r, state.fold, state.limits) == :ok
    end) and
      Enum.all?(items, fn i ->
        Codec.item_valid?(i) and i.stream == stream and i.nonce == nonce and i.state == :pending and
          i.sequence > expected and i.sequence <= expected + length(records) and
          not Map.has_key?(state.items, i.idempotency_key)
      end) and length(Enum.uniq_by(items, & &1.idempotency_key)) == length(items)
  end

  defp stage([stream, expected, records, items] = args, state) do
    if state.visibility == :staged_uncommitted_tail and
         stream_head(state, stream).revision == expected and
         records != [] do
      nonce = hd(records).nonce
      entry = %{nonce: nonce, records: records, items: items, fenced: false}

      next = %{
        state
        | staged: Map.put(state.staged, stream, entry),
          paused: Map.put(state.paused, nonce, {:append, args})
      }

      {{:fault, :unavailable}, next}
    else
      {{:rejected, :torn_repair_unsupported}, state}
    end
  end
end
