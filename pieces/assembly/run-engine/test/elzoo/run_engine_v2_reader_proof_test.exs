## SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngine.ReaderProofPattern do
  def step(%{token: token, requests: [request | rest]} = state, _input) do
    Agent.update(:persistent_term.get({__MODULE__, token}), &(&1 + 1))
    {:Transition, %{state | requests: rest}, {:some, request}}
  end

  def step(%{token: token} = state, _input) do
    Agent.update(:persistent_term.get({__MODULE__, token}), &(&1 + 1))
    {:Transition, state, :none}
  end
end

defmodule Elzoo.RunEngine.ReaderProofStore do
  def new(store) do
    control =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{reads: 0, writes: 0, hook: nil} end},
        id: make_ref()
      )

    {__MODULE__, %{store: store, control: control}}
  end

  def counts({__MODULE__, %{control: control}}),
    do: Agent.get(control, &Map.take(&1, [:reads, :writes]))

  def read_hook(store, hook), do: read_hook(store, nil, hook)

  def read_hook({__MODULE__, %{control: control}}, from, hook),
    do: Agent.update(control, &Map.put(&1, :hook, %{from: from, function: hook}))

  def capabilities(store), do: read_operation(store, :capabilities, [])
  def head(store, stream), do: read_operation(store, :head, [stream])

  def read({__MODULE__, %{control: control}} = adapter, stream, from, limit) do
    hook =
      Agent.get_and_update(control, fn state ->
        run_hook = state.hook && (is_nil(state.hook.from) or state.hook.from == from)
        hook = if run_hook, do: state.hook.function, else: nil

        {hook, %{state | reads: state.reads + 1, hook: if(run_hook, do: nil, else: state.hook)}}
      end)

    if hook, do: hook.(stream, from, limit)
    delegate(adapter, :read, [stream, from, limit])
  end

  def append({__MODULE__, %{control: control}} = adapter, stream, expected, records, items) do
    Agent.update(control, &Map.update!(&1, :writes, fn count -> count + 1 end))
    delegate(adapter, :append, [stream, expected, records, items])
  end

  def ack(adapter, id, nonce), do: write(adapter, :ack, [id, nonce])

  def retain(adapter, stream, expected, through, nonce),
    do: write(adapter, :retain, [stream, expected, through, nonce])

  def put_checkpoint(adapter, checkpoint), do: write(adapter, :put_checkpoint, [checkpoint])

  def repair_torn_tail(adapter, stream, expected, staged, nonce),
    do: write(adapter, :repair_torn_tail, [stream, expected, staged, nonce])

  def read_at(adapter, stream, sequence), do: read_operation(adapter, :read_at, [stream, sequence])
  def pending(adapter, stream, limit), do: read_operation(adapter, :pending, [stream, limit])

  def latest_checkpoint(adapter, stream, version),
    do: read_operation(adapter, :latest_checkpoint, [stream, version])

  def read_ack(adapter, id), do: read_operation(adapter, :read_ack, [id])

  def read_checkpoint(adapter, stream, sequence, version),
    do: read_operation(adapter, :read_checkpoint, [stream, sequence, version])

  def read_maintenance(adapter, stream, operation),
    do: read_operation(adapter, :read_maintenance, [stream, operation])

  defp write({__MODULE__, %{control: control}} = adapter, operation, args) do
    Agent.update(control, &Map.update!(&1, :writes, fn count -> count + 1 end))
    delegate(adapter, operation, args)
  end

  defp read_operation({__MODULE__, %{control: control}} = adapter, operation, args) do
    Agent.update(control, &Map.update!(&1, :reads, fn count -> count + 1 end))
    delegate(adapter, operation, args)
  end

  defp delegate({__MODULE__, %{store: {module, _} = store}}, operation, args),
    do: apply(module, operation, [store | args])
end

defmodule Elzoo.RunEngineV2ReaderProofTest do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableLog, DurableUnit, DynamicUnits, RunEngine, RunApprovalRelease}
  alias Elzoo.RunEngine.ReaderProofPattern
  alias Elzoo.RunEngine.ReaderProofStore
  alias Elzoo.RunEngine.TestPattern

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  setup_all do
    pid = database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for process <- [registry, units], do: Process.unlink(process)

    on_exit(fn ->
      for process <- [registry, units, pid], Process.alive?(process), do: Supervisor.stop(process)
    end)

    :ok
  end

  test "event_waits and result read paired waiting and settled event history without callbacks" do
    waiting = reader_fixture([request_v2([action("wait", "wait_event")])])
    waiting_engine = start_waiting(waiting)
    {:ok, %{waits: [active]}} = event_waits(waiting_engine)
    before_wait_read = callback_counts(waiting)

    assert_reader_no_operator(waiting_engine, waiting, fn ->
      assert {:ok, %{waits: [^active]}} = event_waits(waiting_engine)
    end)

    assert callback_counts(waiting) == before_wait_read
    assert Agent.get(waiting.callbacks.source, & &1.read) == 0

    settled =
      reader_fixture([
        request_v2([action("wait", "wait_event")]),
        request_v2([finish_action("finish", %{"action_id" => "wait"})])
      ])

    engine = start_waiting(settled)
    {:ok, %{waits: [wait]}} = event_waits(engine)

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "accepted-event",
               outside_event(settled, wait, "accepted-event"),
               event_context(wait)
             )

    assert wait_for(engine, &(&1.outcome == :completed)).outcome == :completed
    before_reads = callback_counts(settled)

    assert_reader_no_operator(engine, settled, fn ->
      assert {:ok, %{waits: [accepted]}} = event_waits(engine)

      assert accepted.accepted_event == %{
               event_id: "accepted-event",
               input_id: "accepted-event",
               sequence: 1
             }

      assert {:ok, %{action_id: "wait", payload: %{"accepted" => true}}} =
               RunEngine.result(engine, result_scope(), result_limits())
    end)

    assert callback_counts(settled) == before_reads
  end

  test "event_waits returns an empty projection without invoking callbacks" do
    c = reader_fixture([request_v2([])])
    engine = start_run(c)
    before_reads = callback_counts(c)

    assert_reader_no_operator(engine, c, fn ->
      assert {:ok, %{waits: []}} = event_waits(engine)
    end)

    assert callback_counts(c) == before_reads
  end

  test "audited v1 and v2 empty projections preserve their native empty shapes" do
    v1 = reader_fixture([], protocol_version: 1)

    v1_engine =
      start_run(v1,
        result_reader: %{evidence_store: v1.evidence_store, retention_count: 1_024}
      )

    assert {:ok, %{waits: []}} = event_waits(v1_engine)
    configure = input_row(v1, &(&1.kind == :configure))
    {1, {_, configure_record}} = :erlang.binary_to_term(configure.payload, [:safe])
    refute Map.has_key?(configure_record.control, :protocol_version)
    refute Keyword.has_key?(v1.opts, :event_source)

    v1_with_nil_source = reader_fixture([], protocol_version: 1)

    v1_nil_engine =
      start_run(v1_with_nil_source,
        event_source: nil,
        result_reader: %{evidence_store: v1_with_nil_source.evidence_store, retention_count: 1_024}
      )

    assert {:ok, %{waits: []}} = event_waits(v1_nil_engine)

    v2 = reader_fixture([request_v2([])])
    v2_engine = start_run(v2)
    assert {:ok, %{waits: []}} = event_waits(v2_engine)
  end

  test "one request at cap one projects every simultaneous event wait" do
    c =
      reader_fixture(
        [
          request_v2([
            action("first", "wait_event"),
            action("second", "wait_event")
          ])
        ],
        request_cap: 1
      )

    engine = start_run(c)

    wait_for(engine, fn state ->
      Enum.count(state.slots, fn {_key, slot} ->
        slot.kind == "wait_event" and slot.phase == :waiting
      end) == 2
    end)

    assert {:ok, %{waits: waits}} = event_waits(engine)
    assert c.opts[:request_cap] == 1
    assert Enum.map(waits, & &1.action_id) == ["first", "second"]
  end

  test "scope, reader configuration, limits, and retained-row budgets fail before unintended reads" do
    c = reader_fixture([request_v2([])])
    engine = start_run(c)

    assert_no_owner_reader_io(engine, c, fn ->
      assert {:error, :scope} =
               RunEngine.event_waits(
                 engine,
                 %{tenant: "other", principal: "principal", run_id: "run"},
                 result_limits()
               )

      for invalid <- [
            nil,
            :malformed,
            %{max_records: 1},
            %{max_bytes: 1},
            %{max_records: 1, max_bytes: 1, extra: true},
            %{max_records: 0, max_bytes: 1},
            %{max_records: -1, max_bytes: 1},
            %{max_records: 1.5, max_bytes: 1},
            %{max_records: 65_537, max_bytes: 1},
            %{max_records: 1, max_bytes: 0},
            %{max_records: 1, max_bytes: -1},
            %{max_records: 1, max_bytes: 1.5},
            %{max_records: 1, max_bytes: 536_870_913}
          ] do
        assert {:error, :invalid_limits} =
                 RunEngine.event_waits(engine, result_scope(), invalid)
      end
    end)

    v1 = reader_fixture([], protocol_version: 1)
    unconfigured = start_run(v1)

    assert_no_owner_reader_io(unconfigured, v1, fn ->
      assert {:error, :reader_unconfigured} = event_waits(unconfigured)
    end)

    retained = rows(c)

    exact_bytes =
      Enum.reduce(retained, 0, fn row, total ->
        total + :erlang.iolist_size(DurableLog.canonical_bytes(row))
      end)

    exact_limits = %{max_records: length(retained), max_bytes: exact_bytes}

    assert {:ok, %{waits: []}} =
             RunEngine.event_waits(engine, result_scope(), exact_limits)

    assert {:error, :read_limit} =
             RunEngine.event_waits(engine, result_scope(), %{
               exact_limits
               | max_records: length(retained) - 1
             })

    assert {:error, :read_limit} =
             RunEngine.event_waits(engine, result_scope(), %{
               exact_limits
               | max_bytes: exact_bytes - 1
             })
  end

  test "intermediate control selectors, configure trackers, and caps remain version-strict" do
    for mutation <- [
          :intermediate_selector,
          :configure_selector,
          :configure_tracker,
          :configure_cap,
          :invalid_cap
        ] do
      c = reader_fixture([request_v2([action("wait", "wait_event")])])
      engine = start_waiting(c)
      configure = input_row(c, &(&1.kind == :configure))

      case mutation do
        :intermediate_selector ->
          row = result_row(c, configure.sequence + 1)

          rewrite_row(c, row, fn {1, {id, state}} ->
            {1, {id, put_in(state.control.protocol_version, 1)}}
          end)

        :configure_selector ->
          rewrite_row(c, configure, fn {1, {id, record}} ->
            {1, {id, put_in(record.control.protocol_version, 1)}}
          end)

        :configure_tracker ->
          rewrite_row(c, configure, fn {1, {id, record}} ->
            {1, {id, put_in(record.control.lifecycle.tracker, {:PatternStepTracker, %{}})}}
          end)

        :configure_cap ->
          rewrite_row(c, configure, fn {1, {id, record}} ->
            {1, {id, put_in(record.control.cap, 257)}}
          end)

        :invalid_cap ->
          row = result_row(c, configure.sequence + 1)

          rewrite_row(c, row, fn {1, {id, state}} ->
            {1, {id, put_in(state.control.cap, 257)}}
          end)
      end

      assert {:error, :history} = event_waits(engine)
    end
  end

  test "selected-version validation does not recurse into application payloads" do
    c =
      reader_fixture([
        request_v2([
          action("wait", "wait_event", %{
            "protocol_version" => 1,
            "tracker" => "PatternStepTracker"
          })
        ])
      ])

    engine = start_waiting(c)
    assert {:ok, %{waits: [_]}} = event_waits(engine)
  end

  test "recovery binds selected protocol and event-source identity to the retained Unit" do
    c = reader_fixture([request_v2([action("wait", "wait_event")])])
    engine = start_waiting(c)
    assert {:ok, %{waits: [original_wait]}} = event_waits(engine)
    {:ok, unit} = DynamicUnits.find(c.directory, c.opts[:identity])
    retained_rows = rows(c)
    retained_state = DurableUnit.snapshot(unit)
    retained_fingerprint = retained_state.control.fingerprint
    callbacks_before = callback_counts(c)

    GenServer.stop(engine)
    assert Process.alive?(unit)
    assert rows(c) == retained_rows
    assert DurableUnit.snapshot(unit) == retained_state

    replacement_calls =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{head: 0, read: 0} end},
        id: make_ref()
      )

    source_for = fn id, version ->
      %{
        id: id,
        version: version,
        head: fn _ ->
          Agent.update(replacement_calls, &Map.update!(&1, :head, fn n -> n + 1 end))
          {:ok, %{revision: 0, low_water: 0}}
        end,
        read: fn _, _ ->
          Agent.update(replacement_calls, &Map.update!(&1, :read, fn n -> n + 1 end))
          {:error, :not_found}
        end
      }
    end

    replacement_source = source_for.("events", 1)
    recovered = start(c, event_source: replacement_source)
    assert {:ok, %{waits: [recovered_wait]}} = event_waits(recovered)
    assert recovered_wait.occurrence == original_wait.occurrence
    assert recovered_wait.correlation_id == original_wait.correlation_id
    assert DurableUnit.snapshot(unit).control.fingerprint == retained_fingerprint
    assert rows(c) == retained_rows
    assert DurableUnit.snapshot(unit) == retained_state
    assert callback_counts(c) == callbacks_before
    assert Agent.get(replacement_calls, & &1) == %{head: 0, read: 0}
    GenServer.stop(recovered)

    refuse_recovery = fn options ->
      assert {:error, :incompatible_recovery} = RunEngine.start_link(options)
      assert rows(c) == retained_rows
      assert DurableUnit.snapshot(unit) == retained_state
      assert callback_counts(c) == callbacks_before
      assert Agent.get(replacement_calls, & &1) == %{head: 0, read: 0}
    end

    refuse_recovery.(
      c.opts
      |> Keyword.delete(:protocol_version)
      |> Keyword.delete(:event_source)
    )

    refuse_recovery.(
      c.opts
      |> Keyword.put(:protocol_version, 1)
      |> Keyword.delete(:event_source)
    )

    refuse_recovery.(Keyword.put(c.opts, :event_source, source_for.("other-events", 1)))
    refuse_recovery.(Keyword.put(c.opts, :event_source, source_for.("events", 2)))

    v1 = reader_fixture([], protocol_version: 1)
    {:ok, v1_unit} = DynamicUnits.start(v1.directory, v1.opts[:identity])
    v1_empty_state = DurableUnit.snapshot(v1_unit)
    v1_empty_rows = rows(v1)
    assert v1_empty_state == %{version: 1, control: nil, slots: %{}, requests: %{}}

    assert {:error, :incompatible_recovery} =
             RunEngine.start_link(
               v1.opts
               |> Keyword.put(:protocol_version, 2)
               |> Keyword.put(:event_source, source_for.("events", 1))
             )

    assert DurableUnit.snapshot(v1_unit) == v1_empty_state
    assert rows(v1) == v1_empty_rows
    assert Agent.get(replacement_calls, & &1) == %{head: 0, read: 0}
  end

  test "intermediate request-cache JSON requires the selected request version" do
    c =
      reader_fixture([
        request_v2([action("wait", "wait_event")]),
        request_v2([finish_action("finish", %{"action_id" => "wait"})])
      ])

    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "request-cache-event",
               outside_event(c, wait, "request-cache-event"),
               event_context(wait)
             )

    wait_for(engine, &(&1.outcome == :completed))

    cache_row =
      Enum.find(rows(c), fn row ->
        if row.kind == "result" do
          {1, {_, state}} = :erlang.binary_to_term(row.payload, [:safe])
          map_size(state.requests) > 0
        else
          false
        end
      end)

    assert cache_row
    original = :erlang.binary_to_term(cache_row.payload, [:safe])
    {1, {_, cached_state}} = original
    assert cached_state.version == 2
    assert map_size(cached_state.requests) > 0
    {1, {_, final_state}} = :erlang.binary_to_term(result_row(c, length(rows(c))).payload, [:safe])
    assert final_state.version == 2
    assert cache_row.sequence < length(rows(c))

    for mutation <- [:legacy, :missing_version] do
      rewrite_row(c, cache_row, fn {1, {id, state}} ->
        requests =
          Map.new(state.requests, fn {ordinal, encoded} ->
            request = Jason.decode!(encoded)

            request =
              case mutation do
                :legacy -> Map.put(request, "version", 1)
                :missing_version -> Map.delete(request, "version")
              end

            {ordinal, Jason.encode!(request)}
          end)

        {1, {id, %{state | requests: requests}}}
      end)

      assert {:error, :history} = event_waits(engine)
      restore_row(c, cache_row, original)
    end
  end

  test "intermediate paused slot input requires the selected protocol version" do
    c =
      reader_fixture([
        request_v2([action("wait", "wait_event")]),
        request_v2([finish_action("finish", %{"action_id" => "wait"})])
      ])

    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)

    assert {:ok, :applied} =
             RunEngine.control(
               engine,
               "pause-reader",
               %{kind: :pause, pause_deadline: 50_000},
               verified()
             )

    assert view(engine).phase == :paused

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "paused-slot-event",
               outside_event(c, wait, "paused-slot-event"),
               event_context(wait)
             )

    pending_row =
      Enum.find(rows(c), fn row ->
        if row.kind == "result" do
          {1, {_, state}} = :erlang.binary_to_term(row.payload, [:safe])
          Enum.any?(state.slots, fn {_, slot} -> not is_nil(slot[:pending_input]) end)
        else
          false
        end
      end)

    assert pending_row
    original = :erlang.binary_to_term(pending_row.payload, [:safe])
    {1, {_, pending_state}} = original
    assert pending_state.version == 2

    [{_, pending_slot}] =
      Enum.filter(pending_state.slots, fn {_, slot} -> not is_nil(slot[:pending_input]) end)

    pending_input = pending_slot.pending_input.record.input
    assert is_binary(pending_input)
    assert Jason.decode!(pending_input)["version"] == 2

    assert {:ok, :applied} =
             RunEngine.control(
               engine,
               "continue-reader",
               %{kind: :continue, person_id: "person", run_deadline: 60_000},
               verified(%{verified_person: "person"})
             )

    wait_for(engine, &(&1.outcome == :completed))
    {1, {_, final_state}} = :erlang.binary_to_term(result_row(c, length(rows(c))).payload, [:safe])
    assert final_state.version == 2
    assert pending_row.sequence < length(rows(c))

    for mutation <- [:legacy, :missing_version] do
      rewrite_row(c, pending_row, fn {1, {id, state}} ->
        slots =
          Map.new(state.slots, fn {key, slot} ->
            case slot[:pending_input] do
              %{record: %{input: encoded} = record} = pending ->
                input = Jason.decode!(encoded)

                input =
                  case mutation do
                    :legacy -> Map.put(input, "version", 1)
                    :missing_version -> Map.delete(input, "version")
                  end

                record = %{record | input: Jason.encode!(input)}
                {key, %{slot | pending_input: %{pending | record: record}}}

              _ ->
                {key, slot}
            end
          end)

        {1, {id, %{state | slots: slots}}}
      end)

      assert {:error, :history} = event_waits(engine)
      restore_row(c, pending_row, original)
    end
  end

  test "owner failures, mismatches, and changes during the retained fold are unavailable" do
    failed = reader_fixture([request_v2([action("wait", "wait_event")])])
    failed_engine = start_waiting(failed)
    reads_before = ReaderProofStore.counts(failed.reader_store)
    owner_ref = Process.monitor(failed.run)
    Process.exit(failed.run, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, _, _}, 5_000
    assert {:error, :unavailable} = event_waits(failed_engine)
    assert ReaderProofStore.counts(failed.reader_store) == reads_before

    changed = reader_fixture([request_v2([action("wait", "wait_event")])])
    changed_engine = start_waiting(changed)
    {:ok, owner} = RunApprovalRelease.status(changed.run, "run")

    assert {:ok, _, _} =
             RunApprovalRelease.command(changed.run, %{
               kind: :begin_attempt,
               run_id: "run",
               attempt_id: "attempt-next",
               expected_revision: owner.revision
             })

    assert {:error, :unavailable} = event_waits(changed_engine)
    assert ReaderProofStore.counts(changed.reader_store).reads > 0

    between = reader_fixture([request_v2([action("wait", "wait_event")])])
    between_engine = start_waiting(between)
    parent = self()

    ReaderProofStore.read_hook(between.reader_store, fn _stream, _from, _limit ->
      send(parent, {:reader_store_barrier, self()})

      receive do
        :release_reader_store -> :ok
      after
        5_000 -> raise "reader store barrier timed out"
      end
    end)

    task = Task.async(fn -> event_waits(between_engine) end)
    assert_receive {:reader_store_barrier, engine}, 5_000
    {:ok, owner} = RunApprovalRelease.status(between.run, "run")

    assert {:ok, _, _} =
             RunApprovalRelease.command(between.run, %{
               kind: :begin_attempt,
               run_id: "run",
               attempt_id: "attempt-next",
               expected_revision: owner.revision
             })

    send(engine, :release_reader_store)
    assert {:error, :unavailable} = Task.await(task, 5_000)
  end

  test "a changed retained head is rejected between history and stable-head checks" do
    c = reader_fixture([request_v2([action("wait", "wait_event")])])
    engine = start_waiting(c)
    next_sequence = length(rows(c)) + 1
    parent = self()

    ReaderProofStore.read_hook(c.reader_store, next_sequence, fn _stream, _from, _limit ->
      send(parent, {:head_recheck_barrier, self()})

      receive do
        :release_head_recheck -> :ok
      after
        5_000 -> raise "head recheck barrier timed out"
      end
    end)

    task = Task.async(fn -> event_waits(engine) end)
    assert_receive {:head_recheck_barrier, reader}, 5_000
    append_unpaired_input(c)
    send(reader, :release_head_recheck)
    assert {:error, :history} = Task.await(task, 5_000)
  end

  test "read transport failure is distinct from staged, unpaired, corrupt, gapped, and pruned history" do
    unavailable = reader_fixture([request_v2([])])
    unavailable_engine = start_run(unavailable)
    assert :ok = DurableLog.Memory.fault(unavailable.store, :read, :unavailable)
    assert {:error, :unavailable} = event_waits(unavailable_engine)

    staged = reader_fixture([request_v2([])])
    staged_engine = start_run(staged)
    assert :ok = DurableLog.Memory.fault(staged.store, :append, :stage)
    wake = %{"type" => "input", "version" => 2, "kind" => "wake"}
    _ = RunEngine.input(staged_engine, "staged-reader-tail", wake, verified())
    assert {:error, :history} = event_waits(staged_engine)

    unpaired = reader_fixture([request_v2([])])
    unpaired_engine = start_run(unpaired)
    append_unpaired_input(unpaired)
    assert {:error, :history} = event_waits(unpaired_engine)

    corrupt = reader_fixture([request_v2([])])
    corrupt_engine = start_run(corrupt)
    corrupt_row = List.last(rows(corrupt))

    assert :ok =
             DurableLog.Memory.corrupt(
               corrupt.store,
               :records,
               {corrupt_row.stream, corrupt_row.sequence},
               %{digest: <<0::256>>}
             )

    assert {:error, :history} = event_waits(corrupt_engine)

    gap = reader_fixture([request_v2([])])
    gap_engine = start_run(gap)
    gap_rows = rows(gap)
    [first | _] = gap_rows
    missing = Enum.at(gap_rows, 1)
    store_pid = elem(gap.store, 1).pid

    :sys.replace_state(store_pid, fn state ->
      %{state | records: Map.delete(state.records, {first.stream, missing.sequence})}
    end)

    assert {:error, :history} = event_waits(gap_engine)

    pruned = reader_fixture([request_v2([])])
    pruned_engine = start_run(pruned)
    {:ok, unit} = DynamicUnits.find(pruned.directory, pruned.opts[:identity])
    assert {:committed, _} = DurableUnit.checkpoint(unit)
    pruned_rows = rows(pruned)
    [pruned_row | _] = pruned_rows
    through = length(pruned_rows)

    assert {:committed, ^through} =
             DurableLog.Memory.retain(
               pruned.store,
               pruned_row.stream,
               0,
               through,
               :crypto.strong_rand_bytes(16)
             )

    assert {:error, :history} = event_waits(pruned_engine)
  end

  test "unpaired close projections are rejected; public Run closure and receipts are honored" do
    for projection <- [:stop_pending, :native_terminal] do
      c = reader_fixture([request_v2([action("wait", "wait_event")])])
      engine = start_waiting(c)
      row = result_row(c, length(rows(c)))

      rewrite_row(c, row, fn {1, {id, state}} ->
        state =
          case projection do
            :stop_pending -> put_in(state.control.stop_pending, :cancelled)
            :native_terminal -> put_in(state.control.lifecycle.phase, :terminal)
          end

        {1, {id, state}}
      end)

      assert {:error, :history} = event_waits(engine)
    end

    open = reader_fixture([request_v2([action("wait", "wait_event")])])
    open_engine = start_waiting(open)
    {:ok, owner} = RunApprovalRelease.status(open.run, "run")

    assert {:ok, _, _} =
             RunApprovalRelease.command(open.run, %{
               kind: :cancel,
               run_id: "run",
               attempt_id: owner.current_attempt,
               expected_revision: owner.revision
             })

    assert {:ok, %{waits: [closed]}} = event_waits(open_engine)
    assert closed.status == :closed
    assert is_nil(closed.outcome)
    assert is_nil(closed.accepted_event)

    settled =
      reader_fixture([
        request_v2([action("wait", "wait_event")]),
        request_v2([finish_action("finish", %{"action_id" => "wait"})])
      ])

    settled_engine = start_waiting(settled)
    {:ok, %{waits: [wait]}} = event_waits(settled_engine)

    assert {:ok, :applied} =
             RunEngine.input(
               settled_engine,
               "closed-run-event",
               outside_event(settled, wait, "closed-run-event"),
               event_context(wait)
             )

    wait_for(settled_engine, &(&1.outcome == :completed))
    assert {:ok, %{waits: [observed]}} = event_waits(settled_engine)
    assert observed.status == :settled

    assert observed.accepted_event == %{
             event_id: "closed-run-event",
             input_id: "closed-run-event",
             sequence: 1
           }
  end

  test "later ordinary wake cannot forge a close marker and over-cap output remains valid" do
    for projection <- [:stop_pending, :native_terminal] do
      c = reader_fixture([request_v2([action("wait", "wait_event")])])
      engine = start_waiting(c)
      assert {:ok, :applied} = append_wake(engine, "close-marker-wake-#{projection}")
      row = result_row(c, length(rows(c)))

      rewrite_row(c, row, fn {1, {id, state}} ->
        state =
          case projection do
            :stop_pending -> put_in(state.control.stop_pending, :cancelled)
            :native_terminal -> put_in(state.control.lifecycle.phase, :terminal)
          end

        {1, {id, state}}
      end)

      assert {:error, :history} = event_waits(engine)
    end

    c =
      reader_fixture(
        [
          request_v2([action("wait", "wait_event")]),
          request_v2([action("after", "local_work")])
        ],
        request_cap: 1
      )

    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "over-cap-event",
               outside_event(c, wait, "over-cap-event"),
               event_context(wait)
             )

    input = input_row(c, &(Map.get(&1, :id) == "over-cap-event"))
    before = result_row(c, input.sequence - 1)
    after_row = result_row(c, input.sequence + 1)
    {1, {_, before_state}} = :erlang.binary_to_term(before.payload, [:safe])
    {1, {_, record}} = :erlang.binary_to_term(input.payload, [:safe])
    {1, {_, after_state}} = :erlang.binary_to_term(after_row.payload, [:safe])

    assert {:ok, expected_state} = RunEngine.project_event_wait_transition(before_state, record)
    assert :ok = RunEngine.valid_event_wait_close_transition?(before_state, record, after_state)
    assert expected_state.slots[wait.occurrence] == after_state.slots[wait.occurrence]

    below_cap_before = put_in(before_state.control.cap, 3)
    below_cap_after = put_in(after_state.control.cap, 3)

    assert {:error, :history} =
             RunEngine.valid_event_wait_close_transition?(below_cap_before, record, below_cap_after)

    assert {:ok, %{waits: [settled]}} = event_waits(engine)
    assert settled.status == :settled
    assert settled.accepted_event.event_id == "over-cap-event"
  end

  test "a waiting event slot without activation provenance is rejected at its paired result" do
    c = reader_fixture([request_v2([action("wait", "wait_event")])])
    engine = start_waiting(c)
    activation = input_row(c, &(&1.kind == :event_activation))
    before_activation = result_row(c, activation.sequence - 1)

    rewrite_row(c, before_activation, fn {1, {id, state}} ->
      [key] = for {key, slot} <- state.slots, slot.kind == "wait_event", do: key
      {1, {id, put_in(state.slots[key].phase, :waiting)}}
    end)

    assert {:error, :history} = event_waits(engine)
  end

  test "later paired result cannot omit an activated event wait" do
    c = reader_fixture([request_v2([action("wait", "wait_event")])])
    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)
    assert {:ok, :applied} = append_wake(engine, "wait-continuity-wake")
    later = result_row(c, length(rows(c)))

    rewrite_row(c, later, fn {1, {id, state}} ->
      {1, {id, %{state | slots: Map.delete(state.slots, wait.occurrence)}}}
    end)

    assert {:error, :history} = event_waits(engine)
  end

  test "later paired result cannot change an activated event wait kind" do
    c = reader_fixture([request_v2([action("wait", "wait_event")])])
    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)
    assert {:ok, :applied} = append_wake(engine, "wait-kind-wake")
    later = result_row(c, length(rows(c)))

    rewrite_row(c, later, fn {1, {id, state}} ->
      {1, {id, put_in(state.slots[wait.occurrence].kind, "local_work")}}
    end)

    assert {:error, :history} = event_waits(engine)
  end

  test "later paired result cannot invent failed settlement without a receipt" do
    c = reader_fixture([request_v2([action("wait", "wait_event")])])
    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)
    assert {:ok, :applied} = append_wake(engine, "wait-failed-wake")
    later = result_row(c, length(rows(c)))

    rewrite_row(c, later, fn {1, {id, state}} ->
      slot = state.slots[wait.occurrence] |> Map.merge(%{phase: :settled, outcome: "failed"})
      {1, {id, put_in(state.slots[wait.occurrence], Map.delete(slot, :event_receipt))}}
    end)

    assert {:error, :history} = event_waits(engine)
  end

  test "an intermediate activated-wait deletion is rejected even when later state restores it" do
    c = reader_fixture([request_v2([action("wait", "wait_event")])])
    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)
    activation = input_row(c, &(&1.kind == :event_activation))
    activation_result = result_row(c, activation.sequence + 1)
    assert {:ok, :applied} = append_wake(engine, "wait-delete-wake")
    intermediate = result_row(c, length(rows(c)))
    assert {:ok, :applied} = append_wake(engine, "wait-restore-wake")
    later = result_row(c, length(rows(c)))
    {1, {_, later_state}} = :erlang.binary_to_term(later.payload, [:safe])
    assert later_state.slots[wait.occurrence].phase == :waiting

    assert activation_result.sequence < intermediate.sequence
    assert intermediate.sequence < later.sequence

    rewrite_row(c, intermediate, fn {1, {id, state}} ->
      {1, {id, %{state | slots: Map.delete(state.slots, wait.occurrence)}}}
    end)

    assert {:error, :history} = event_waits(engine)
  end

  test "a later record cannot rewrite the first event settlement" do
    c = reader_fixture([request_v2([action("wait", "wait_event")])])
    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "first-event-settlement",
               outside_event(c, wait, "first-event-settlement"),
               event_context(wait)
             )

    assert wait_for(engine, &(&1.slots[wait.occurrence].phase == :settled))
    assert {:ok, :applied} = append_wake(engine, "first-settlement-retention-wake")
    later = result_row(c, length(rows(c)))

    rewrite_row(c, later, fn {1, {id, state}} ->
      slot = state.slots[wait.occurrence] |> Map.merge(%{outcome: "failed"})
      slot = Map.delete(slot, :event_receipt)
      {1, {id, put_in(state.slots[wait.occurrence], slot)}}
    end)

    assert {:error, :history} = event_waits(engine)
  end

  test "paired expiry and Attempt closure preserve activated wait continuity" do
    expired = reader_fixture([request_v2([action("wait", "wait_event")])])
    expired_engine = start_waiting(expired)
    {:ok, %{waits: [expired_wait]}} = event_waits(expired_engine)
    Agent.update(expired.clock, fn _ -> expired_wait.deadline_ms end)
    assert {:ok, :applied} = append_wake(expired_engine, "reader-expiry-wake")
    assert {:ok, %{waits: [expired_projection]}} = event_waits(expired_engine)
    assert expired_projection.status == :settled
    assert expired_projection.outcome == "expired"
    assert is_nil(expired_projection.accepted_event)

    attempted = reader_fixture([request_v2([action("wait", "wait_event")])])
    attempted_engine = start_waiting(attempted)

    assert {:ok, :applied} =
             RunEngine.control(
               attempted_engine,
               "reader-attempt-change",
               %{kind: :begin_attempt, attempt_id: "attempt-two"},
               verified()
             )

    assert {:ok, %{waits: []}} = event_waits(attempted_engine)
  end

  test "public reader accepts a genuine terminal-to-new-Run configure pair" do
    c = reader_fixture([request_v2([action("wait", "wait_event")])])
    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)
    assert {:ok, owner} = RunApprovalRelease.status(c.run, "run")
    {:ok, unit} = DynamicUnits.start(c.directory, c.opts[:identity])

    assert {:ok, _, _} =
             RunApprovalRelease.command(c.run, %{
               kind: :complete,
               run_id: "run",
               attempt_id: owner.current_attempt,
               expected_revision: owner.revision,
               outcome: :failed,
               reason: "engine",
               evidence_ref: nil
             })

    assert {:ok, :applied} = append_wake(engine, "reader-terminal-wake")
    terminal = DurableUnit.snapshot(unit)
    assert terminal.control.lifecycle.phase == :terminal
    configure = input_row(c, &(&1.kind == :configure))
    {1, {_, record}} = :erlang.binary_to_term(configure.payload, [:safe])

    control =
      record.control
      |> Map.put(:run_id, "run-two")
      |> Map.put(:operation_id, "operation-two")
      |> Map.put(:attempt_id, "attempt-two")

    record = %{record | control: control}

    assert {:ok, reset} = RunEngine.project_event_wait_transition(terminal, record)
    assert reset.control.run_id == "run-two"
    refute Map.has_key?(reset.slots, wait.occurrence)

    assert {:ok, :applied} = DurableUnit.step(unit, "reader-new-run-configure", record)

    new_owner = %{
      id: "run-two",
      operation_id: "operation-two",
      current_attempt: "attempt-two",
      revision: 1,
      outcome: nil
    }

    assert {:ok, %{run_id: "run-two", attempt_id: "attempt-two", waits: []}} =
             Elzoo.RunEngine.ResultReader.event_waits(
               c.opts[:store],
               c.opts[:identity],
               new_owner,
               c.opts[:result_reader].retention_count,
               result_limits(),
               c.opts[:bindings],
               %{
                 version: 2,
                 tenant: "tenant",
                 principal: "principal",
                 source_id: "events",
                 source_version: 1
               },
               {RunEngine, :step, %{version: 2, control: nil, slots: %{}, requests: %{}}}
             )
  end

  test "public readers retain older activations across a new Run source change" do
    c =
      reader_fixture([
        request_v2([action("wait", "wait_event")]),
        request_v2([finish_action("finish", %{"action_id" => "wait"})])
      ])

    engine = start_waiting(c)
    assert {:ok, %{waits: [_]}} = event_waits(engine)
    assert {:ok, owner} = RunApprovalRelease.status(c.run, "run")
    {:ok, unit} = DynamicUnits.start(c.directory, c.opts[:identity])

    assert {:ok, _, _} =
             RunApprovalRelease.command(c.run, %{
               kind: :complete,
               run_id: "run",
               attempt_id: owner.current_attempt,
               expected_revision: owner.revision,
               outcome: :failed,
               reason: "engine",
               evidence_ref: nil
             })

    assert {:ok, :applied} = append_wake(engine, "reader-terminal-wake")
    assert DurableUnit.snapshot(unit).control.lifecycle.phase == :terminal
    activation = input_row(c, &(&1.kind == :event_activation))
    {1, {_, activation_record}} = :erlang.binary_to_term(activation.payload, [:safe])
    assert activation_record.source_id == "events"
    assert activation_record.source_version == 1
    GenServer.stop(engine)

    assert {:ok, old_owner} = RunApprovalRelease.status(c.run, "run")

    assert {:ok, revision, _} =
             RunApprovalRelease.command(c.run, %{
               kind: :create,
               run_id: "run-two",
               operation_id: "operation-two",
               provider_refs: %{},
               expected_revision: old_owner.revision
             })

    assert {:ok, _, _} =
             RunApprovalRelease.command(c.run, %{
               kind: :begin_attempt,
               run_id: "run-two",
               attempt_id: "attempt-two",
               expected_revision: revision
             })

    source = next_event_source(c)
    new_engine = start(c, run_id: "run-two", event_source: source)
    assert {:ok, ^unit} = DynamicUnits.find(c.directory, c.opts[:identity])
    assert DurableUnit.snapshot(unit).control.event_source == %{id: "events-next", version: 2}

    assert {:ok, :applied} =
             RunEngine.input(
               new_engine,
               "reader-start-two",
               start_input_v2(),
               verified(%{run_id: "run-two", attempt_id: "attempt-two"})
             )

    scope = %{tenant: "tenant", principal: "principal", run_id: "run-two"}

    _view =
      wait_for(new_engine, fn view ->
        Enum.any?(view.slots, fn {_, slot} ->
          slot.kind == "wait_event" and slot.phase == :waiting
        end)
      end)

    event_waits_result = RunEngine.event_waits(new_engine, scope, result_limits())

    assert {:ok, %{run_id: "run-two", attempt_id: "attempt-two", waits: [wait]}} =
             event_waits_result

    assert wait.source_id == "events-next"
    assert wait.status == :waiting

    event_id = "run-two-source-event"

    assert {:ok, :applied} =
             RunEngine.input(
               new_engine,
               event_id,
               outside_event(c, wait, event_id),
               verified(%{
                 run_id: "run-two",
                 attempt_id: "attempt-two",
                 occurrence: wait.occurrence,
                 actual: 0,
                 dispatch: "not_dispatched"
               })
             )

    assert wait_for(new_engine, &(&1.outcome == :completed)).outcome == :completed
    result = RunEngine.result(new_engine, scope, result_limits())

    assert {:ok, %{action_id: "wait", payload: %{"accepted" => true}}} = result
  end

  test "advancing only the clock past a wait deadline does not expire it during inspection" do
    c = reader_fixture([request_v2([action("wait", "wait_event")])])
    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)
    Agent.update(c.clock, fn _ -> wait.deadline_ms + 1 end)
    before = callback_counts(c)
    clock_calls_before = Agent.get(c.callbacks.clock, & &1)

    assert {:ok, %{waits: [observed]}} = event_waits(engine)
    assert observed.status == :waiting
    assert is_nil(observed.outcome)
    assert callback_counts(c) == before
    assert Agent.get(c.callbacks.clock, & &1) == clock_calls_before
  end

  test "activation proof rejects extra keys and pre-activation permission failures" do
    for mutation <- [
          :activation_extra_key,
          :missing_lifecycle_wait,
          {:phase, :paused},
          {:phase, :terminal},
          {:stop_pending, :completed},
          {:generation_closed, true},
          {:wait_one_shot, false},
          {:wait_source_id, "wrong-source"},
          {:wait_correlation_id, "wrong-ticket"}
        ] do
      c = reader_fixture([request_v2([action("wait", "wait_event")])])
      engine = start_waiting(c)
      activation = input_row(c, &(&1.kind == :event_activation))

      case mutation do
        :activation_extra_key ->
          rewrite_row(c, activation, fn {1, {id, record}} ->
            {1, {id, Map.put(record, :forged, true)}}
          end)

        :missing_lifecycle_wait ->
          after_activation = result_row(c, activation.sequence + 1)

          rewrite_row(c, after_activation, fn {1, {id, state}} ->
            {1, {id, update_in(state.control.lifecycle.waits, &Map.delete(&1, "wait"))}}
          end)

        {field, value} when field in [:wait_one_shot, :wait_source_id, :wait_correlation_id] ->
          after_activation = result_row(c, activation.sequence + 1)

          rewrite_row(c, after_activation, fn {1, {id, state}} ->
            key =
              if field == :wait_one_shot,
                do: :one_shot,
                else: if(field == :wait_source_id, do: :source_id, else: :correlation_id)

            {1, {id, put_in(state.control.lifecycle.waits["wait"][key], value)}}
          end)

        state_change ->
          before = result_row(c, activation.sequence - 1)

          rewrite_row(c, before, fn {1, {id, state}} ->
            {1, {id, update_pre_activation(state, state_change)}}
          end)
      end

      assert {:error, :history} = event_waits(engine)
    end
  end

  test "pure activation step requires a ready wait_event slot" do
    c = reader_fixture([request_v2([action("wait", "wait_event")])])
    start_waiting(c)
    activation = input_row(c, &(&1.kind == :event_activation))
    before = result_row(c, activation.sequence - 1)
    {1, {_, state}} = :erlang.binary_to_term(before.payload, [:safe])
    {1, {_, record}} = :erlang.binary_to_term(activation.payload, [:safe])
    key = record.occurrence

    assert state.slots[key].kind == "wait_event"
    assert state.slots[key].phase == :ready
    before_callbacks = callback_counts(c)
    wrong_kind = put_in(state.slots[key].kind, "local_work")

    assert {:Transition, after_state, :none} = RunEngine.step(wrong_kind, record)
    assert after_state.slots[key].kind == "local_work"
    assert after_state.slots[key].phase == :ready
    refute Map.has_key?(after_state.slots[key], :activation_id)
    assert callback_counts(c) == before_callbacks
  end

  test "the first event receipt must match its paired source record exactly" do
    c =
      reader_fixture([
        request_v2([action("wait", "wait_event")]),
        request_v2([finish_action("finish", %{"action_id" => "wait"})])
      ])

    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "receipt-event",
               outside_event(c, wait, "receipt-event"),
               event_context(wait)
             )

    wait_for(engine, &(&1.outcome == :completed))

    final = result_row(c, length(rows(c)))

    original = :erlang.binary_to_term(final.payload, [:safe])

    for mutation <- [:input_id, :extra_key, :sequence] do
      rewrite_row(c, final, fn {1, {id, state}} ->
        [key] = for {key, slot} <- state.slots, slot.kind == "wait_event", do: key

        receipt = state.slots[key].event_receipt

        receipt =
          case mutation do
            :extra_key -> Map.put(receipt, :forged, true)
            :input_id -> Map.put(receipt, :input_id, "wrong-original-input")
            :sequence -> Map.put(receipt, :sequence, receipt.sequence + 1)
          end

        {1, {id, put_in(state.slots[key].event_receipt, receipt)}}
      end)

      assert {:error, :history} = event_waits(engine)
      assert {:error, :history} = RunEngine.result(engine, result_scope(), result_limits())
      restore_row(c, final, original)
    end
  end

  test "mixed-version intermediate edges and paired outer IDs are rejected natively" do
    c =
      reader_fixture([
        request_v2([action("wait", "wait_event")]),
        request_v2([finish_action("finish", %{"action_id" => "wait"})])
      ])

    engine = start_waiting(c)
    {:ok, %{waits: [wait]}} = event_waits(engine)

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "coherent-event",
               outside_event(c, wait, "coherent-event"),
               event_context(wait)
             )

    assert wait_for(engine, &(&1.outcome == :completed)).outcome == :completed

    fold =
      DurableUnit.fold(
        operator: {RunEngine, :step, %{version: 2, control: nil, slots: %{}, requests: %{}}},
        retention_count: 1_024
      )

    start = input_row(c, &(&1.kind == :protocol and &1.id == "reader-start"))
    start_result = result_row(c, start.sequence + 1)
    start_term = :erlang.binary_to_term(start.payload, [:safe])
    start_result_term = :erlang.binary_to_term(start_result.payload, [:safe])

    rewrite_row(c, start, fn {1, {id, record}} ->
      input = Map.put(record.input, "version", 1)
      {1, {id, %{record | version: 1, input: input}}}
    end)

    rewrite_row(c, start_result, fn {1, {id, state}} -> {1, {id, %{state | version: 1}}} end)
    current_start = Enum.find(rows(c), &(&1.sequence == start.sequence))
    current_start_result = Enum.find(rows(c), &(&1.sequence == start.sequence + 1))

    assert :ok = DurableLog.validate_row(current_start, fold, %{max_record_bytes: 16_777_216})

    assert :ok =
             DurableLog.validate_row(current_start_result, fold, %{max_record_bytes: 16_777_216})

    model = fold.reduce.(fold.initial, "input", current_start.schema_version, current_start.payload)

    model =
      fold.reduce.(
        model,
        "result",
        current_start_result.schema_version,
        current_start_result.payload
      )

    assert model.pending == nil
    assert model.state.version == 1
    {1, {_, intermediate}} = :erlang.binary_to_term(current_start_result.payload, [:safe])
    {1, {_, final_state}} = :erlang.binary_to_term(result_row(c, length(rows(c))).payload, [:safe])
    assert intermediate.version == 1
    assert final_state.version == 2
    assert {:error, :history} = event_waits(engine)

    restore_row(c, start, start_term)
    restore_row(c, start_result, start_result_term)

    event_input_row = input_row(c, &(&1.kind == :protocol and &1.input["kind"] == "outside_event"))
    event_result = result_row(c, event_input_row.sequence + 1)

    rewrite_row(c, event_input_row, fn {1, {_outer, record}} ->
      {1, {"counterfeit-outer-id", record}}
    end)

    rewrite_row(c, event_result, fn {1, {_outer, state}} ->
      {1, {"counterfeit-outer-id", state}}
    end)

    event_input = Enum.find(rows(c), &(&1.sequence == event_input_row.sequence))
    {1, {input_id, record}} = :erlang.binary_to_term(event_input.payload, [:safe])

    {1, {result_id, _}} =
      :erlang.binary_to_term(result_row(c, event_result.sequence).payload, [:safe])

    assert input_id == result_id
    assert record.id == "coherent-event"

    event_result = result_row(c, event_result.sequence)
    assert :ok = DurableLog.validate_row(event_input, fold, %{max_record_bytes: 16_777_216})
    assert :ok = DurableLog.validate_row(event_result, fold, %{max_record_bytes: 16_777_216})
    model = fold.reduce.(fold.initial, "input", event_input.schema_version, event_input.payload)
    model = fold.reduce.(model, "result", event_result.schema_version, event_result.payload)
    assert model.pending == nil
    assert {:error, :history} = event_waits(engine)
  end

  test "lifecycle and request trackers must retain the selected tag in reader and retry reconciliation" do
    for tracker_kind <- [:lifecycle, :request] do
      c = reader_fixture([request_v2([action("wait", "wait_event")])])
      engine = start_waiting(c)
      {:ok, %{waits: [wait]}} = event_waits(engine)
      event_id = "tracker-tag-event"

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 event_id,
                 outside_event(c, wait, event_id),
                 event_context(wait)
               )

      start = input_row(c, &(&1.kind == :protocol and &1.id == "reader-start"))
      intermediate = result_row(c, start.sequence + 1)

      rewrite_row(c, intermediate, fn {1, {id, state}} ->
        state =
          case tracker_kind do
            :lifecycle ->
              {:PatternStepTrackerV2, actions} = state.control.lifecycle.tracker
              put_in(state.control.lifecycle.tracker, {:PatternStepTracker, actions})

            :request ->
              [{ordinal, request} | _] = Map.to_list(state.control.trackers)
              {:PatternStepTrackerV2, actions} = request.tracker
              put_in(state.control.trackers[ordinal].tracker, {:PatternStepTracker, actions})
          end

        {1, {id, state}}
      end)

      counts = callback_counts(c)
      assert {:error, :history} = event_waits(engine)

      assert {:error, :source_unavailable} =
               RunEngine.input(
                 engine,
                 event_id,
                 outside_event(c, wait, event_id),
                 event_context(wait)
               )

      assert callback_counts(c) == counts
    end
  end

  test "public event_waits binds coherent retained rows to configured scope and source" do
    script = [
      request_v2([action("wait", "wait_event")]),
      request_v2([finish_action("finish", %{"action_id" => "wait"})])
    ]

    target = reader_fixture(script)
    target_engine = start_waiting(target)
    {:ok, %{waits: [target_wait]}} = event_waits(target_engine)
    event_id = "coherent-config-event"

    assert {:ok, :applied} =
             RunEngine.input(
               target_engine,
               event_id,
               outside_event(target, target_wait, event_id),
               event_context(target_wait)
             )

    wait_for(target_engine, &(&1.outcome == :completed))

    for {field, value} <- [
          {:tenant, "other-tenant"},
          {:principal, "other-principal"},
          {:source_id, "other-events"},
          {:source_version, 2}
        ] do
      donor = reader_fixture(script, [{field, value}])
      donor_engine = start_waiting(donor)

      donor_scope = %{
        tenant: donor.opts[:tenant],
        principal: donor.opts[:principal],
        run_id: "run"
      }

      {:ok, %{waits: [donor_wait]}} =
        RunEngine.event_waits(donor_engine, donor_scope, result_limits())

      assert {:ok, :applied} =
               RunEngine.input(
                 donor_engine,
                 event_id,
                 outside_event(donor, donor_wait, event_id),
                 event_context(donor_wait)
               )

      wait_for(donor_engine, &(&1.outcome == :completed))
      transplant_history(target, donor)
      assert {:error, :history} = event_waits(target_engine)
    end
  end

  test "event_waits checks selected result schema from static schema-map bindings" do
    c =
      reader_fixture([
        request_v2([action("wait", "wait_event")]),
        request_v2([finish_action("finish", %{"action_id" => "wait"})])
      ])

    bindings =
      Map.update!(c.opts[:bindings], "wait_event", fn binding -> %{"action" => binding} end)

    engine = start_waiting(c, bindings: bindings)
    {:ok, %{waits: [wait]}} = event_waits(engine)

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "schema-event",
               outside_event(c, wait, "schema-event"),
               event_context(wait)
             )

    wait_for(engine, &(&1.outcome == :completed))
    row = input_row(c, &(&1.kind == :protocol and &1.input["kind"] == "outside_event"))

    rewrite_row(c, row, fn {1, {id, record}} ->
      input = Map.put(record.input, "schema_id", "wrong-result")

      event_digest =
        RunEngine.event_digest(
          input["event_id"],
          input["source_id"],
          input["correlation_id"],
          record.correlation.source_sequence,
          record.correlation.source_version,
          input["schema_id"],
          input["schema_version"],
          input["payload"]
        )

      correlation = Map.put(record.correlation, :event_digest, event_digest)
      {1, {id, %{record | input: input, correlation: correlation}}}
    end)

    assert {:error, :history} = event_waits(engine)
  end

  test "result refuses a forged earlier wait proof when local work is the completion source" do
    c =
      reader_fixture([
        request_v2([action("wait", "wait_event")]),
        request_v2([action("local", "local_work")]),
        request_v2([finish_action("finish", %{"action_id" => "local"})])
      ])

    parent = self()

    bindings =
      Map.update!(c.opts[:bindings], "local_work", fn binding ->
        Map.put(binding, :work, fn action ->
          {TestPattern, :blocked, [parent, action["payload"]]}
        end)
      end)

    engine = start_waiting(c, bindings: bindings)
    {:ok, %{waits: [wait]}} = event_waits(engine)

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "local-event",
               outside_event(c, wait, "local-event"),
               event_context(wait)
             )

    assert_receive {:local_started, task}, 5_000
    assert {:ok, %{waits: [settled]}} = event_waits(engine)
    assert settled.status == :settled
    assert settled.accepted_event.event_id == "local-event"

    send(task, :finish)
    assert wait_for(engine, &(&1.outcome == :completed)).outcome == :completed

    activation = input_row(c, &(&1.kind == :event_activation))

    rewrite_row(c, activation, fn {1, {id, record}} -> {1, {id, Map.put(record, :forged, true)}} end)

    assert {:error, :history} = RunEngine.result(engine, result_scope(), result_limits())
  end

  defp reader_fixture(requests, configuration \\ []) do
    protocol_version = Keyword.get(configuration, :protocol_version, 2)
    tenant = Keyword.get(configuration, :tenant, "tenant")
    principal = Keyword.get(configuration, :principal, "principal")
    source_id = Keyword.get(configuration, :source_id, "events")
    source_version = Keyword.get(configuration, :source_version, 1)
    request_cap = Keyword.get(configuration, :request_cap, 20)
    token = "reader-proof-#{System.unique_integer([:positive])}"
    pattern_calls = ExUnit.Callbacks.start_supervised!({Agent, fn -> 0 end}, id: make_ref())
    :persistent_term.put({ReaderProofPattern, token}, pattern_calls)
    on_exit(fn -> :persistent_term.erase({ReaderProofPattern, token}) end)

    source_calls =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{head: 0, read: 0, ticket: nil} end},
        id: make_ref()
      )

    gate_calls = ExUnit.Callbacks.start_supervised!({Agent, fn -> 0 end}, id: make_ref())
    clock_calls = ExUnit.Callbacks.start_supervised!({Agent, fn -> 0 end}, id: make_ref())
    binding_calls = ExUnit.Callbacks.start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    source = %{
      id: source_id,
      version: source_version,
      head: fn _ ->
        Agent.update(source_calls, &Map.update!(&1, :head, fn n -> n + 1 end))
        {:ok, %{revision: 0, low_water: 0}}
      end,
      read: fn _, event_id ->
        Agent.update(source_calls, &Map.update!(&1, :read, fn n -> n + 1 end))

        {:ok,
         %{
           head: %{revision: 1, low_water: 0},
           event: %{
             id: event_id,
             source_id: source_id,
             correlation_id: Agent.get(source_calls, & &1.ticket),
             sequence: 1,
             schema_id: "result",
             schema_version: 1,
             payload: %{"accepted" => true}
           }
         }}
      end
    }

    unit_store = memory_unit_store(protocol_version)
    reader_store = ReaderProofStore.new(unit_store)

    fixture_options = [
      protocol_version: protocol_version,
      unit_store: unit_store,
      store: reader_store,
      tenant: tenant,
      principal: principal,
      request_cap: request_cap,
      pattern: {ReaderProofPattern, :step, %{token: token, requests: requests}}
    ]

    fixture_options =
      if protocol_version == 2,
        do: Keyword.put(fixture_options, :event_source, source),
        else: fixture_options

    c = fixture(fixture_options)
    bindings = instrument_binding_callbacks(c.opts[:bindings], binding_calls)
    c = Map.update!(c, :opts, &Keyword.put(&1, :bindings, bindings))

    c
    |> Map.put(:reader_store, reader_store)
    |> Map.put(:callbacks, %{
      pattern: pattern_calls,
      source: source_calls,
      gate: gate_calls,
      clock: clock_calls,
      binding: binding_calls
    })
  end

  defp start_waiting(c, overrides \\ []) do
    engine = start_run(c, overrides)

    wait_for(engine, fn view ->
      Enum.any?(view.slots, fn {_, slot} -> slot.kind == "wait_event" and slot.phase == :waiting end)
    end)

    engine
  end

  defp next_event_source(c) do
    %{
      id: "events-next",
      version: 2,
      head: fn _ ->
        Agent.update(c.callbacks.source, &Map.update!(&1, :head, fn count -> count + 1 end))
        {:ok, %{revision: 0, low_water: 0}}
      end,
      read: fn _, event_id ->
        Agent.update(c.callbacks.source, &Map.update!(&1, :read, fn count -> count + 1 end))

        {:ok,
         %{
           head: %{revision: 1, low_water: 0},
           event: %{
             id: event_id,
             source_id: "events-next",
             correlation_id: Agent.get(c.callbacks.source, & &1.ticket),
             sequence: 1,
             schema_id: "result",
             schema_version: 1,
             payload: %{"accepted" => true}
           }
         }}
      end
    }
  end

  defp start_run(c, overrides \\ []) do
    gate = %{
      id: "gate",
      version: 1,
      call: fn _, _ ->
        Agent.update(c.callbacks.gate, &(&1 + 1))
        :allow
      end
    }

    clock = fn ->
      Agent.update(c.callbacks.clock, &(&1 + 1))
      Agent.get(c.clock, & &1)
    end

    engine = start(c, Keyword.merge([gate: gate, clock: clock], overrides))
    input = if c.opts[:protocol_version] == 1, do: start_input(), else: start_input_v2()
    assert {:ok, :applied} = RunEngine.input(engine, "reader-start", input, verified())
    engine
  end

  defp event_waits(engine), do: RunEngine.event_waits(engine, result_scope(), result_limits())

  defp append_wake(engine, id) do
    RunEngine.input(
      engine,
      id,
      %{"type" => "input", "version" => 2, "kind" => "wake"},
      verified()
    )
  end

  defp result_scope, do: %{tenant: "tenant", principal: "principal", run_id: "run"}
  defp result_limits, do: %{max_records: 65_536, max_bytes: 536_870_912}

  defp callback_counts(c),
    do:
      {Agent.get(c.callbacks.pattern, & &1), Agent.get(c.callbacks.source, & &1),
       Agent.get(c.callbacks.gate, & &1), Agent.get(c.callbacks.clock, & &1),
       Agent.get(c.callbacks.binding, & &1)}

  defp instrument_binding_callbacks(bindings, counter) do
    Map.new(bindings, fn {kind, binding} ->
      binding =
        Enum.reduce([:facts, :proposal, :work, :person, :nested], binding, fn field, current ->
          case Map.get(current, field) do
            fun when is_function(fun, 1) ->
              Map.put(current, field, fn argument ->
                Agent.update(counter, &(&1 + 1))
                fun.(argument)
              end)

            _ ->
              current
          end
        end)

      {kind, binding}
    end)
  end

  defp outside_event(c, wait, event_id) do
    Agent.update(c.callbacks.source, &Map.put(&1, :ticket, wait.correlation_id))

    %{
      "type" => "input",
      "version" => 2,
      "kind" => "outside_event",
      "action_id" => wait.action_id,
      "source_id" => wait.source_id,
      "correlation_id" => wait.correlation_id,
      "event_id" => event_id,
      "schema_id" => "result",
      "schema_version" => 1,
      "payload" => %{"accepted" => true}
    }
  end

  defp event_context(wait),
    do: verified(%{occurrence: wait.occurrence, actual: 0, dispatch: "not_dispatched"})

  defp input_row(c, predicate) do
    Enum.find(rows(c), fn row ->
      if row.kind == "input" do
        case :erlang.binary_to_term(row.payload, [:safe]) do
          {1, {_, record}} when is_map(record) -> predicate.(record)
          _ -> false
        end
      else
        false
      end
    end)
  end

  defp result_row(c, sequence),
    do: Enum.find(rows(c), &(&1.sequence == sequence and &1.kind == "result"))

  defp transplant_history(target, donor) do
    target_rows = rows(target)
    donor_rows = rows(donor)

    assert Enum.map(target_rows, &{&1.sequence, &1.kind}) ==
             Enum.map(donor_rows, &{&1.sequence, &1.kind})

    Enum.zip(target_rows, donor_rows)
    |> Enum.each(fn {target_row, donor_row} ->
      term = :erlang.binary_to_term(donor_row.payload, [:safe])
      rewrite_row(target, target_row, fn _ -> term end)
    end)
  end

  defp rewrite_row(c, row, transform) do
    payload =
      row.payload
      |> :erlang.binary_to_term([:safe])
      |> transform.()
      |> then(&:erlang.term_to_binary(&1, [:deterministic, {:minor_version, 2}]))

    changed = %{row | payload: payload}
    changed = %{changed | digest: DurableLog.digest(changed)}

    assert :ok =
             DurableLog.Memory.corrupt(c.store, :records, {row.stream, row.sequence}, %{
               payload: changed.payload,
               digest: changed.digest
             })
  end

  defp restore_row(c, row, term), do: rewrite_row(c, row, fn _ -> term end)

  defp update_pre_activation(state, {:phase, phase}),
    do: put_in(state.control.lifecycle.phase, phase)

  defp update_pre_activation(state, {:stop_pending, outcome}),
    do: put_in(state.control.stop_pending, outcome)

  defp update_pre_activation(state, {:generation_closed, closed}),
    do: put_in(state.control.generation_closed, closed)

  defp memory_unit_store(version) do
    options = [
      operator: {RunEngine, :step, %{version: version, control: nil, slots: %{}, requests: %{}}},
      retention_count: 1_024,
      max_record_bytes: 16_777_216,
      max_checkpoint_bytes: 33_554_432
    ]

    pid =
      ExUnit.Callbacks.start_supervised!(%{
        id: make_ref(),
        start:
          {DurableLog.Memory, :start_link,
           [[fold: DurableUnit.fold(options), limits: DurableUnit.limits(options)]]}
      })

    DurableLog.Memory.store(pid)
  end

  defp append_unpaired_input(c) do
    source = input_row(c, &(&1.kind == :protocol))
    {1, {_, record}} = :erlang.binary_to_term(source.payload, [:safe])
    id = "reader-unpaired-tail"
    input = Map.put(record.input, "kind", "wake")
    record = %{record | id: id, input: input}
    payload = :erlang.term_to_binary({1, {id, record}}, [:deterministic, {:minor_version, 2}])
    expected = length(rows(c))
    row = %{source | sequence: expected + 1, payload: payload, nonce: :crypto.strong_rand_bytes(16)}
    row = %{row | digest: DurableLog.digest(row)}

    assert {:committed, _} =
             DurableLog.Memory.append(c.store, source.stream, expected, [row], [])
  end

  defp assert_reader_no_operator(engine, c, assert_reads) do
    {:ok, unit} = DynamicUnits.find(c.directory, c.opts[:identity])
    patterns = reader_forbidden_patterns()
    before_callbacks = callback_counts(c)
    before_store = ReaderProofStore.counts(c.reader_store)
    before_rows = rows(c)

    for {mfa, flags} <- patterns, do: :erlang.trace_pattern(mfa, true, flags)
    :erlang.trace(engine, true, [:call])
    :erlang.trace(unit, true, [:call])

    try do
      assert_reads.()
      delivered_engine = :erlang.trace_delivered(engine)
      delivered_unit = :erlang.trace_delivered(unit)
      assert_receive {:trace_delivered, ^engine, ^delivered_engine}, 5_000
      assert_receive {:trace_delivered, ^unit, ^delivered_unit}, 5_000
      calls = collect_reader_calls([engine, unit], [])

      refute Enum.any?(calls, fn {_pid, module, function, arity} ->
               Enum.any?(patterns, fn {{pattern_module, pattern_function, pattern_arity}, _} ->
                 module == pattern_module and function == pattern_function and
                   arity == pattern_arity
               end)
             end)
    after
      :erlang.trace(engine, false, [:call])
      :erlang.trace(unit, false, [:call])
      for {mfa, flags} <- patterns, do: :erlang.trace_pattern(mfa, false, flags)
    end

    after_callbacks = callback_counts(c)
    after_store = ReaderProofStore.counts(c.reader_store)
    assert after_callbacks == before_callbacks
    assert after_store.reads > before_store.reads
    assert after_store.writes == before_store.writes
    assert rows(c) == before_rows
  end

  defp assert_no_owner_reader_io(engine, c, assertion) do
    before_callbacks = callback_counts(c)
    before_store = ReaderProofStore.counts(c.reader_store)
    :erlang.trace_pattern({RunApprovalRelease, :status, 2}, true, [:global])
    :erlang.trace(engine, true, [:call])

    try do
      assertion.()
      delivered = :erlang.trace_delivered(engine)
      assert_receive {:trace_delivered, ^engine, ^delivered}, 5_000
      calls = collect_reader_calls([engine], [])

      refute Enum.any?(calls, fn {_pid, module, function, arity} ->
               {module, function, arity} == {RunApprovalRelease, :status, 2}
             end)
    after
      :erlang.trace(engine, false, [:call])
      :erlang.trace_pattern({RunApprovalRelease, :status, 2}, false, [:global])
    end

    assert ReaderProofStore.counts(c.reader_store) == before_store
    assert callback_counts(c) == before_callbacks
  end

  defp reader_forbidden_patterns do
    exported =
      Enum.flat_map(
        [
          Elzoo.PayloadSchema,
          Elzoo.EffectIntent.Binding,
          DynamicUnits,
          ReaderProofPattern,
          TestPattern
        ],
        fn module ->
          if Code.ensure_loaded?(module) do
            for {function, arity} <- module.module_info(:functions),
                do: {{module, function, arity}, [:global]}
          else
            []
          end
        end
      )

    unit_lifecycle =
      Enum.flat_map([DurableUnit], fn module ->
        if Code.ensure_loaded?(module) do
          for {function, arity} <- module.module_info(:functions),
              function in [:start, :start_link, :step, :recover, :recover_state],
              do: {{module, function, arity}, [:global]}
        else
          []
        end
      end)

    writes =
      for {function, arity} <- [
            {:append, 5},
            {:ack, 3},
            {:retain, 5},
            {:put_checkpoint, 2},
            {:repair_torn_tail, 5}
          ],
          do: {{Elzoo.DurableLog.Memory, function, arity}, [:global]}

    local =
      for {function, arity} <- [
            {:dispatch, 3},
            {:ingest, 4},
            {:apply_control, 4},
            {:commit, 3},
            {:finish_run, 3},
            {:submit_ingress, 6},
            {:internal_outcome, 6}
          ],
          do: {{RunEngine, function, arity}, [:local]}

    Enum.uniq([{{RunEngine, :step, 2}, [:global]} | exported ++ unit_lifecycle ++ writes ++ local])
  end

  defp collect_reader_calls(pids, acc) do
    receive do
      {:trace, pid, :call, {module, function, args}} ->
        calls =
          if pid in pids,
            do: [{pid, module, function, length(args)} | acc],
            else: acc

        collect_reader_calls(pids, calls)
    after
      0 -> acc
    end
  end
end
