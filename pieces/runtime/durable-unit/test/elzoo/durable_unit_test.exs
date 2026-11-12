# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableUnitTest do
  use ExUnit.Case, async: false
  alias Elzoo.{Checkpoint, DurableUnit, Outbox}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Memory, Record, Writer}

  # Instrumented fixtures deliberately do I/O to place crashes around the pure step.
  # No barrier or fault option is present in the production Unit.
  defmodule Operator do
    def step(state, {factor, add, emit}) do
      next = state * factor + add
      {:Transition, next, if(emit, do: {:some, next + 7}, else: :none)}
    end

    def observed(state, input) do
      %{observer: observer, block: block} = Agent.get(Probe, & &1)
      send(observer, {:transition, self(), state, input})
      if block, do: receive(do: (:continue -> :ok))

      case input do
        :raise -> raise "private payload"
        :throw -> throw(:private_payload)
        :exit -> exit(:private_payload)
        :bad -> {:Transition, state, :bad}
        :large_state -> {:Transition, String.duplicate("x", 600), :none}
        :large_output -> {:Transition, state, {:some, String.duplicate("x", 600)}}
        _ -> step(state, input)
      end
    end
  end

  defmodule BarrierStore do
    for {name, arity} <- [
          capabilities: 0,
          head: 1,
          read: 3,
          read_at: 2,
          latest_checkpoint: 2,
          read_checkpoint: 3,
          pending: 2,
          read_ack: 1,
          read_maintenance: 2,
          retain: 4,
          ack: 2,
          repair_torn_tail: 4
        ] do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)({__MODULE__, opts}, unquote_splicing(args)),
        do: apply(Memory, unquote(name), [{Memory, opts}, unquote_splicing(args)])
    end

    def put_checkpoint({__MODULE__, opts}, checkpoint) do
      send(Agent.get(Probe, & &1.observer), {:checkpoint, checkpoint})
      Memory.put_checkpoint({Memory, opts}, checkpoint)
    end

    def append({__MODULE__, opts}, stream, expected, records, items) do
      %{observer: observer, append: actions} = Agent.get(Probe, & &1)
      send(observer, {:append, self(), expected, records, items})

      case Map.get(actions, expected) do
        :block ->
          receive do: (:continue -> Memory.append({Memory, opts}, stream, expected, records, items))

        {:reject, reason} ->
          {:rejected, reason}

        _ ->
          Memory.append({Memory, opts}, stream, expected, records, items)
      end
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    observer = self()

    start_supervised!(%{
      id: Probe,
      start:
        {Agent, :start_link,
         [fn -> %{observer: observer, block: false, append: %{}} end, [name: Probe]]}
    })

    opts = [
      operator: {Operator, :observed, 2},
      retention_count: 2,
      max_record_bytes: 512,
      max_checkpoint_bytes: 100_000,
      stream: "unit",
      offer: fn %Outbox.Item{} = item ->
        send(observer, {:offer, item})
        :ok
      end
    ]

    memory =
      start_supervised!({Memory, fold: DurableUnit.fold(opts), limits: DurableUnit.limits(opts)})

    raw = Memory.store(memory)
    store = {BarrierStore, elem(raw, 1)}
    %{opts: Keyword.put(opts, :store, store), store: store, raw: raw}
  end

  defp start(opts) do
    {:ok, unit} = DurableUnit.start_link(opts)
    Process.unlink(unit)
    on_exit(fn -> if Process.alive?(unit), do: GenServer.stop(unit) end)
    unit
  end

  defp killed(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp down(pid, reason) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, actual}
    assert actual in [reason, :noproc]
  end

  defp rows(store) do
    {:ok, rows, _} = Log.read(store, "unit", 1, 1_000)
    rows
  end

  defp contents(store), do: Enum.map(rows(store), &{&1.kind, &1.schema_version, decode(&1.payload)})
  defp encode(term), do: :erlang.term_to_binary({1, term}, [:deterministic, {:minor_version, 2}])
  defp decode(bytes), do: elem(:erlang.binary_to_term(bytes, [:safe]), 1)
  defp probe(changes), do: Agent.update(Probe, &Map.merge(&1, changes))

  defp call_step(unit, id, input) do
    observer = self()

    spawn(fn ->
      result =
        try do
          DurableUnit.step(unit, id, input)
        catch
          :exit, _ -> :uncertain
        end

      send(observer, {:reply, result})
    end)
  end

  test "DU1 both intake forms, validation and inclusive input bound inspect committed rows", ctx do
    opts = Keyword.put(ctx.opts, :name, __MODULE__)
    unit = start(opts)
    assert DurableUnit.child_spec(opts).restart == :transient
    assert {:ok, :applied} = DurableUnit.step(__MODULE__, "A", {3, 5, true})
    send(unit, {:durable_unit_input, "B", {2, -4, false}})
    assert DurableUnit.snapshot(unit) == 18

    assert contents(ctx.store) == [
             {"input", 1, {"A", {3, 5, true}}},
             {"result", 1, {"A", 11}},
             {"input", 1, {"B", {2, -4, false}}},
             {"result", 1, {"B", 18}}
           ]

    assert {:ok, [item]} = Outbox.pending(ctx.store, "unit", 64)
    assert decode(item.payload) == 18
    assert_receive {:offer, %{sequence: 2}}
    assert_receive {:offer, %{sequence: 2}}
    assert_receive {:transition, ^unit, 2, {3, 5, true}}
    assert_receive {:transition, ^unit, 11, {2, -4, false}}
    before = Memory.inspect_state(ctx.raw)

    for id <- ["", <<0>>, <<255>>, String.duplicate("i", 161), :not_binary] do
      assert {:error, :invalid_input} = DurableUnit.step(unit, id, {9, 1, true})
      send(unit, {:durable_unit_input, id, {9, 1, true}})
    end

    assert {:error, :input_too_large} = DurableUnit.step(unit, "big", String.duplicate("x", 512))
    send(unit, {:durable_unit_input, "big", String.duplicate("x", 512)})
    assert {:ok, :duplicate} = DurableUnit.step(unit, "A", {3, 5, true})
    assert {:error, :input_id_conflict} = DurableUnit.step(unit, "A", {3, 6, true})
    send(unit, {:durable_unit_input, "A", {3, 6, true}})
    assert DurableUnit.snapshot(unit) == 18
    assert Memory.inspect_state(ctx.raw) == before
    refute_receive {:transition, ^unit, _, _}
    refute_receive {:offer, _}

    # Same asymmetric sequence with the intake forms reversed.
    other = start(Keyword.merge(ctx.opts, stream: "other"))
    send(other, {:durable_unit_input, "A", {3, 5, true}})
    assert {:ok, :applied} = DurableUnit.step(other, "B", {2, -4, false})
    assert DurableUnit.snapshot(other) == 18
    {:ok, other_rows, _} = Log.read(ctx.store, "other", 1, 10)

    assert Enum.map(other_rows, &{&1.kind, decode(&1.payload)}) ==
             Enum.map(rows(ctx.store), &{&1.kind, decode(&1.payload)})

    input = {1, 0, false}
    id = String.duplicate("é", 80)
    bound = byte_size(encode({id, input}))
    exact = start(Keyword.merge(ctx.opts, stream: "exact", max_record_bytes: bound))
    assert {:ok, :applied} = DurableUnit.step(exact, id, input)
    small = start(Keyword.merge(ctx.opts, stream: "small", max_record_bytes: bound - 1))
    assert {:error, :input_too_large} = DurableUnit.step(small, id, input)
    assert {:ok, [], %{revision: 0}} = Log.read(ctx.store, "small", 1, 10)

    for change <- [
          [retention_count: 0],
          [max_record_bytes: -1],
          [max_checkpoint_bytes: 0],
          [stream: ""],
          [stream: <<0>>],
          [stream: String.duplicate("s", 201)],
          [offer: :not_function]
        ] do
      assert {:error, :invalid_options} = DurableUnit.start_link(Keyword.merge(ctx.opts, change))
    end
  end

  test "DU2 crash before input append gives no acknowledgement, record or evaluation", ctx do
    probe(%{append: %{0 => :block}})
    unit = start(ctx.opts)
    call_step(unit, "A", {3, 5, true})
    assert_receive {:append, writer, 0, _, []}
    assert rows(ctx.store) == []
    refute_receive {:transition, _, _, _}
    killed(unit)
    down(writer, :killed)
    assert_receive {:reply, :uncertain}
    probe(%{append: %{}})
    unit = start(ctx.opts)
    assert {:ok, :applied} = DurableUnit.step(unit, "A", {3, 5, true})
    assert DurableUnit.snapshot(unit) == 11
    assert length(rows(ctx.store)) == 2
    assert {:ok, :duplicate} = DurableUnit.step(unit, "A", {3, 5, true})
  end

  test "DU3 interrupted evaluation and result append retry unresolved input across restarts", ctx do
    probe(%{block: true})
    unit = start(ctx.opts)
    call_step(unit, "A", {3, 5, true})
    assert_receive {:transition, ^unit, 2, {3, 5, true}}
    assert contents(ctx.store) == [{"input", 1, {"A", {3, 5, true}}}]
    killed(unit)
    assert_receive {:reply, :uncertain}

    # Deliberate recovery is interrupted while evaluating the same unresolved input.
    parent = self()
    starter = spawn(fn -> send(parent, {:started, DurableUnit.start_link(ctx.opts)}) end)
    assert_receive {:transition, recovering, 2, {3, 5, true}}
    killed(recovering)
    refute_receive {:started, {:ok, _}}
    refute Process.alive?(starter)
    assert length(rows(ctx.store)) == 1

    probe(%{block: false, append: %{1 => :block}})
    spawn(fn -> send(parent, {:started, DurableUnit.start_link(ctx.opts)}) end)
    assert_receive {:transition, recovering, 2, {3, 5, true}}
    assert_receive {:append, writer, 1, _, [_]}
    killed(recovering)
    down(writer, :killed)
    assert length(rows(ctx.store)) == 1

    probe(%{append: %{}})
    unit = start(ctx.opts)
    assert_receive {:transition, ^unit, 2, {3, 5, true}}
    assert DurableUnit.snapshot(unit) == 11
    assert Enum.map(rows(ctx.store), & &1.kind) == ["input", "result"]
    assert {:ok, [_]} = Outbox.pending(ctx.store, "unit", 64)
    assert {:ok, :duplicate} = DurableUnit.step(unit, "A", {3, 5, true})
  end

  test "DU4 committed recovery, failed offers, stable keys, ack and caller-driven 64-item passes",
       ctx do
    observer = self()

    blocked_offer = fn %Outbox.Item{} = item ->
      send(observer, {:before_offer, self(), item})
      receive do: (:continue -> :ok)
    end

    unit = start(Keyword.put(ctx.opts, :offer, blocked_offer))
    call_step(unit, "A", {3, 5, true})
    assert_receive {:transition, ^unit, 2, _}
    assert_receive {:before_offer, ^unit, item}
    assert length(rows(ctx.store)) == 2
    killed(unit)
    assert_receive {:reply, :uncertain}
    unit = start(ctx.opts)
    assert DurableUnit.snapshot(unit) == 11
    refute_receive {:transition, ^unit, _, _}
    assert_receive {:offer, recovered}
    assert recovered.idempotency_key == item.idempotency_key
    assert {:ok, 1} = DurableUnit.offer_pending(unit)
    assert_receive {:offer, ^recovered}

    assert {:committed, 2} =
             Outbox.ack(ctx.store, item.idempotency_key, :crypto.strong_rand_bytes(16))

    assert {:ok, 0} = DurableUnit.offer_pending(unit)

    failures = [
      fn _ -> :not_ok end,
      fn _ -> raise "private" end,
      fn _ -> throw(:private) end,
      fn _ -> exit(:private) end
    ]

    for {fail, index} <- Enum.with_index(failures) do
      stream = "failed-#{index}"
      failing = start(Keyword.merge(ctx.opts, stream: stream, offer: fail))
      assert {:ok, :applied} = DurableUnit.step(failing, "A", {3, 5, true})
      assert DurableUnit.snapshot(failing) == 11
      assert {:error, :offer_unavailable} = DurableUnit.offer_pending(failing)
      assert {:ok, [_]} = Outbox.pending(ctx.store, stream, 64)
      GenServer.stop(failing)
    end

    Memory.fault(ctx.raw, :pending, :unavailable)
    assert {:error, :offer_unavailable} = DurableUnit.offer_pending(unit)

    # No output is acknowledged implicitly; the first 64 remain the first page.
    bulk = start(Keyword.merge(ctx.opts, stream: "bulk", offer: fn _ -> :ok end))
    for i <- 1..65, do: assert({:ok, :applied} = DurableUnit.step(bulk, "#{i}", {1, 1, true}))
    assert {:ok, 64} = DurableUnit.offer_pending(bulk)
    {:ok, first} = Outbox.pending(ctx.store, "bulk", 64)
    assert length(first) == 64

    for pending <- first do
      assert {:committed, _} =
               Outbox.ack(ctx.store, pending.idempotency_key, :crypto.strong_rand_bytes(16))
    end

    assert {:ok, 1} = DurableUnit.offer_pending(bulk)
    assert {:ok, [last]} = Outbox.pending(ctx.store, "bulk", 64)
    assert decode(last.payload) == 74

    assert {:committed, _} =
             Outbox.ack(ctx.store, last.idempotency_key, :crypto.strong_rand_bytes(16))

    assert {:ok, 0} = DurableUnit.offer_pending(bulk)
  end

  test "DU5 checkpoint fault reconciliation, version fallback, pruning and full witness limits",
       ctx do
    for fault <- [:rollback, :reply_loss, {:pause, :checkpoint}] do
      stream = inspect(fault)
      opts = Keyword.put(ctx.opts, :stream, stream)
      unit = start(opts)
      assert {:ok, :applied} = DurableUnit.step(unit, "A", {3, 5, false})
      Memory.fault(ctx.raw, :put_checkpoint, fault)
      assert {:indeterminate, receipt} = DurableUnit.checkpoint(unit)
      assert_receive {:checkpoint, %{stream: ^stream} = attempted}
      assert attempted.nonce == receipt.nonce
      assert receipt.operation == :put_checkpoint

      assert Map.keys(receipt) |> Enum.sort() ==
               Enum.sort([:operation, :stream, :expected, :target, :nonce, :digest, :cause])

      down(unit, {:shutdown, :durable_unit_indeterminate})

      if fault == {:pause, :checkpoint},
        do: assert({:committed, 2} = Memory.release(ctx.raw, :checkpoint))

      {:ok, checkpoint} = Memory.latest_checkpoint(ctx.raw, stream, 1)

      if fault == :rollback do
        assert checkpoint == :none
        assert {:unknown, :unfenced} = Log.confirm_checkpoint(ctx.store, attempted)
        # Absence proves nothing. The caller deliberately supersedes with a fresh-nonce CAS.
        replay =
          Checkpoint.recover(ctx.store, stream, DurableUnit.fold(opts), 1, &{:ok, decode(&1)})

        assert {:committed, 2} =
                 Checkpoint.take(
                   {ctx.store, replay, DurableUnit.limits(opts)},
                   stream,
                   1,
                   &encode/1
                 )

        assert :superseded = Log.confirm_checkpoint(ctx.store, attempted)
      else
        assert checkpoint == attempted
        assert {:committed, 2} = Log.confirm_checkpoint(ctx.store, checkpoint)
      end

      reopened = start(opts)
      assert DurableUnit.snapshot(reopened) == 11
      assert {:ok, :duplicate} = DurableUnit.step(reopened, "A", {3, 5, false})
    end

    unit = start(ctx.opts)
    assert {:ok, :applied} = DurableUnit.step(unit, "A", {3, 5, false})
    assert {:committed, 2} = DurableUnit.checkpoint(unit)
    {:ok, checkpoint} = Memory.latest_checkpoint(ctx.raw, "unit", 1)
    GenServer.stop(unit)
    incompatible = %{checkpoint | fold_version: 2}
    incompatible = %{incompatible | digest: Codec.hash(Checkpoint.canonical_bytes(incompatible))}
    assert {:committed, 2} = Memory.put_checkpoint(ctx.raw, incompatible)
    Memory.corrupt(ctx.raw, :checkpoints, {"unit", 2, 1}, %{digest: <<0::256>>})
    replayed = start(ctx.opts)
    assert DurableUnit.snapshot(replayed) == 11
    refute_receive {:transition, ^replayed, _, _}
    GenServer.stop(replayed)
    # A valid v2 anchor permits pruning, but is not a usable v1 recovery anchor.
    assert {:committed, 2} = Memory.retain(ctx.raw, "unit", 0, 2, :crypto.strong_rand_bytes(16))
    assert {:error, {:shutdown, :durable_unit_recovery_failed}} = DurableUnit.start_link(ctx.opts)

    small_opts = Keyword.merge(ctx.opts, stream: "bounded", max_checkpoint_bytes: 250)
    small = start(small_opts)
    for i <- 1..6, do: assert({:ok, :applied} = DurableUnit.step(small, "#{i}", {1, i, false}))
    assert {:rejected, :checkpoint_too_large} = DurableUnit.checkpoint(small)
    assert {:ok, :none} = Memory.latest_checkpoint(ctx.raw, "bounded", 1)
    {:ok, log, head} = Log.read(ctx.store, "bounded", 1, 100)
    replay = Log.replay(log, head, DurableUnit.fold(small_opts))
    assert map_size(replay.seen) == 12
    assert length(replay.model.completed) == 2
    GenServer.stop(small)
    recovered = start(small_opts)
    assert DurableUnit.snapshot(recovered) == 23
    assert {:rejected, :checkpoint_too_large} = DurableUnit.checkpoint(recovered)
  end

  test "DU6 FIFO retention boundary survives checkpoint/restart and never evicts unresolved input",
       ctx do
    for checkpoint? <- [false, true] do
      opts = Keyword.put(ctx.opts, :stream, "retention-#{checkpoint?}")
      unit = start(opts)
      assert {:ok, :applied} = DurableUnit.step(unit, "A", {3, 5, false})
      assert {:ok, :applied} = DurableUnit.step(unit, "B", {2, -4, false})
      assert {:ok, :duplicate} = DurableUnit.step(unit, "A", {3, 5, false})
      if checkpoint?, do: assert({:committed, 4} = DurableUnit.checkpoint(unit))
      GenServer.stop(unit)
      unit = start(opts)
      assert {:ok, :applied} = DurableUnit.step(unit, "C", {1, 7, false})

      if checkpoint? do
        assert {:committed, 6} = DurableUnit.checkpoint(unit)
        assert {:ok, checkpoint} = Memory.latest_checkpoint(ctx.raw, "retention-true", 1)
        assert map_size(checkpoint.seen) == 6
        assert length(decode(checkpoint.model).completed) == 2
      end

      GenServer.stop(unit)
      unit = start(opts)
      assert {:ok, :duplicate} = DurableUnit.step(unit, "B", {2, -4, false})
      assert {:ok, :applied} = DurableUnit.step(unit, "A", {3, 5, false})
      assert DurableUnit.snapshot(unit) == 80
      {:ok, log, _} = Log.read(ctx.store, Keyword.fetch!(opts, :stream), 1, 100)
      assert length(log) == 8
    end

    unit = start(ctx.opts)
    assert {:ok, :applied} = DurableUnit.step(unit, "A", {3, 5, false})
    assert {:ok, :applied} = DurableUnit.step(unit, "B", {2, -4, false})
    probe(%{block: true})
    call_step(unit, "C", {1, 7, false})
    assert_receive {:transition, ^unit, 18, {1, 7, false}}
    killed(unit)
    assert_receive {:reply, :uncertain}
    {:ok, log, head} = Log.read(ctx.store, "unit", 1, 100)
    replay = Log.replay(log, head, DurableUnit.fold(ctx.opts))
    assert replay.model.pending == {"C", {1, 7, false}}
    assert Enum.map(replay.model.completed, &elem(&1, 0)) == ["A", "B"]

    assert {:committed, 5} =
             Checkpoint.take(
               {ctx.store, replay, DurableUnit.limits(ctx.opts)},
               "unit",
               1,
               &encode/1
             )

    probe(%{block: false})
    recovered = start(ctx.opts)
    assert DurableUnit.snapshot(recovered) == 25
    assert {:ok, :duplicate} = DurableUnit.step(recovered, "C", {1, 7, false})
  end

  test "DU7 losing input/result Writers stop with exact conflict and no losing result or offer",
       ctx do
    winner = start(ctx.opts)
    loser = start(ctx.opts)
    assert {:ok, :applied} = DurableUnit.step(winner, "A", {3, 5, true})
    ref = Process.monitor(loser)
    assert {:error, :durable_unit_conflict} = DurableUnit.step(loser, "losing", {9, 9, true})
    assert_receive {:DOWN, ^ref, :process, ^loser, {:shutdown, :durable_unit_conflict}}
    refute_receive {:transition, ^loser, _, _}
    assert DurableUnit.snapshot(winner) == 11

    probe(%{block: true})
    call_step(winner, "B", {2, -4, true})
    assert_receive {:transition, ^winner, 11, {2, -4, true}}
    # The second Writer finishes the same input first, using the ready CAS unchanged.
    {:ok, contender} =
      Writer.start_link(
        store: ctx.store,
        stream: "unit",
        fold: DurableUnit.fold(ctx.opts),
        limits: DurableUnit.limits(ctx.opts)
      )

    assert {:committed, 4} =
             Writer.append(contender, [{"result", 1, encode({"B", 99})}], [{"outputs", encode(106)}])

    ref = Process.monitor(winner)
    send(winner, :continue)
    assert_receive {:reply, {:error, :durable_unit_conflict}}
    assert_receive {:DOWN, ^ref, :process, ^winner, {:shutdown, :durable_unit_conflict}}
    assert List.last(contents(ctx.store)) == {"result", 1, {"B", 99}}
    assert {:ok, items} = Outbox.pending(ctx.store, "unit", 64)
    assert Enum.map(items, &decode(&1.payload)) == [18, 106]
    refute_receive {:offer, %{sequence: 4}}
    GenServer.stop(contender)
    probe(%{block: false})
    recovered = start(ctx.opts)
    assert DurableUnit.snapshot(recovered) == 99
    refute_receive {:transition, ^recovered, _, _}
  end

  test "DU8 poison/format refusal, transient shutdown, storage uncertainty and unrelated messages",
       ctx do
    for input <- [:raise, :throw, :exit, :bad, :large_state, :large_output] do
      opts = Keyword.put(ctx.opts, :stream, Atom.to_string(input))
      {:ok, supervisor} = Supervisor.start_link([{DurableUnit, opts}], strategy: :one_for_one)
      [{_, unit, _, _}] = Supervisor.which_children(supervisor)
      ref = Process.monitor(unit)
      assert {:error, :durable_unit_transition_failed} = DurableUnit.step(unit, "poison", input)
      assert_receive {:DOWN, ^ref, :process, ^unit, {:shutdown, :durable_unit_transition_failed}}
      assert [{_, :undefined, _, _}] = Supervisor.which_children(supervisor)
      assert {:error, {:shutdown, :durable_unit_transition_failed}} = DurableUnit.start_link(opts)
      {:ok, log, _} = Log.read(ctx.store, Atom.to_string(input), 1, 10)
      assert Enum.map(log, & &1.kind) == ["input"]
      assert {:ok, []} = Outbox.pending(ctx.store, Atom.to_string(input), 64)
      Supervisor.stop(supervisor)
    end

    unit = start(ctx.opts)
    send(unit, {:input, "ignored", {9, 9, true}})
    send(unit, :unrelated)
    assert DurableUnit.snapshot(unit) == 2
    assert rows(ctx.store) == []
    probe(%{append: %{0 => {:reject, :caller_transaction}}})
    assert {:error, {:rejected, :caller_transaction}} = DurableUnit.step(unit, "A", {3, 5, true})
    assert DurableUnit.snapshot(unit) == 2
    assert rows(ctx.store) == []
    probe(%{append: %{1 => {:reject, :caller_transaction}}})
    ref = Process.monitor(unit)
    assert {:error, {:rejected, :caller_transaction}} = DurableUnit.step(unit, "A", {3, 5, true})
    assert_receive {:DOWN, ^ref, :process, ^unit, {:shutdown, :durable_unit_storage_rejected}}
    assert Enum.map(rows(ctx.store), & &1.kind) == ["input"]
    probe(%{append: %{}})
    recovered = start(ctx.opts)
    assert DurableUnit.snapshot(recovered) == 11
    GenServer.stop(recovered)

    for fault <- [:reply_loss, :rollback, :malformed] do
      opts = Keyword.put(ctx.opts, :stream, "unknown-#{fault}")
      unit = start(opts)
      Memory.fault(ctx.raw, :append, fault)
      ref = Process.monitor(unit)
      assert {:indeterminate, receipt} = DurableUnit.step(unit, "A", {3, 5, true})
      assert receipt.operation == :append

      assert Map.keys(receipt) |> Enum.sort() ==
               Enum.sort([:operation, :stream, :expected, :target, :nonce, :digest, :cause])

      assert_receive {:DOWN, ^ref, :process, ^unit, {:shutdown, :durable_unit_indeterminate}}
    end

    probe(%{append: %{1 => :block}})
    opts = Keyword.put(ctx.opts, :stream, "unknown-result")
    unit = start(opts)
    call_step(unit, "A", {3, 5, true})
    assert_receive {:append, writer, 1, [%{stream: "unknown-result"} = result], [_]}
    Memory.fault(ctx.raw, :append, :reply_loss)
    ref = Process.monitor(unit)
    send(writer, :continue)
    assert_receive {:reply, {:indeterminate, receipt}}
    assert receipt.nonce == result.nonce
    assert receipt.target == 2
    assert_receive {:DOWN, ^ref, :process, ^unit, {:shutdown, :durable_unit_indeterminate}}
    assert {:committed, 2} = Log.confirm(ctx.store, "unknown-result", 1, receipt.nonce, [result])
    probe(%{append: %{}})
    recovered = start(opts)
    assert DurableUnit.snapshot(recovered) == 11
    refute_receive {:transition, ^recovered, _, _}

    # Killing the Writer during its call has no receipt, not a safe rejection.
    probe(%{append: %{0 => :block}})
    unit = start(Keyword.put(ctx.opts, :stream, "writer-exit"))
    call_step(unit, "A", {3, 5, true})
    assert_receive {:append, writer, 0, [%{stream: "writer-exit"}], []}
    killed(writer)
    assert_receive {:reply, {:indeterminate, :storage_unknown}}
    down(unit, {:shutdown, :durable_unit_indeterminate})
    probe(%{append: %{}})

    for {kind, payload, version} <- [
          {"input", {"A", {3, 5, false}}, 9},
          {"result", {"A", 11}, 1},
          {"input", :bad_shape, 1}
        ] do
      stream = "damaged-#{kind}-#{version}-#{is_tuple(payload)}"

      row = %Record{
        stream: stream,
        sequence: 1,
        kind: kind,
        schema_version: version,
        payload: encode(payload),
        nonce: <<0::128>>
      }

      row = %{row | digest: Log.digest(row)}
      # Unsupported versions are stored by an older/different writer, then refused by v1.
      valid = %{row | schema_version: 1, kind: "input", payload: encode({"A", {3, 5, false}})}
      valid = %{valid | digest: Log.digest(valid)}
      assert {:committed, 1} = Memory.append(ctx.raw, stream, 0, [valid], [])
      Memory.corrupt(ctx.raw, :records, {stream, 1}, Map.from_struct(row))

      assert {:error, {:shutdown, :durable_unit_recovery_failed}} =
               DurableUnit.start_link(Keyword.put(ctx.opts, :stream, stream))
    end

    Memory.fault(ctx.raw, :head, :unavailable)
    assert {:error, {:shutdown, :durable_unit_recovery_failed}} = DurableUnit.start_link(ctx.opts)
  end
end
