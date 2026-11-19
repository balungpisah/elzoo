## SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngine.TestHistoryStore do
  def new(store, control), do: {__MODULE__, %{store: store, control: control}}

  def arm_read_failure(control), do: Agent.update(control, &Map.put(&1, :read_failure, true))

  def arm_input_commit_failure(control),
    do: Agent.update(control, &Map.put(&1, :input_failure, :armed))

  def arm_result_barrier(control, parent, token) do
    Agent.update(control, fn state ->
      state
      |> Map.put(:result_barrier, :armed)
      |> Map.put(:parent, parent)
      |> Map.put(:token, token)
    end)
  end

  def capabilities(store), do: delegate(store, :capabilities, [])
  def head(store, stream), do: delegate(store, :head, [stream])

  def append(store, stream, expected, records, items) do
    result = delegate(store, :append, [stream, expected, records, items])

    input_failure =
      if match?({:committed, _}, result) and
           Enum.any?(records, fn
             %{kind: "input"} -> true
             _ -> false
           end) do
        Agent.get_and_update(store_config(store).control, fn state ->
          if Map.get(state, :input_failure) == :armed,
            do: {:fail, Map.put(state, :input_failure, :consumed)},
            else: {:none, state}
        end)
      else
        :none
      end

    if input_failure == :fail do
      {:indeterminate, %{cause: :unavailable}}
    else
      if match?({:committed, _}, result) and
           Enum.any?(records, fn
             %{kind: "result"} -> true
             _ -> false
           end) do
        case Agent.get_and_update(store_config(store).control, fn state ->
               if state.result_barrier == :armed do
                 {{:block, state.parent, state.token}, %{state | result_barrier: :blocked}}
               else
                 {:none, state}
               end
             end) do
          {:block, parent, token} ->
            send(parent, {:result_committed, token, self(), result})
            receive do: ({:release_result, ^token} -> :ok)

          :none ->
            :ok
        end
      end

      result
    end
  end

  def read(store, stream, from, limit) do
    case Agent.get_and_update(store_config(store).control, fn state ->
           if state.read_failure,
             do: {:fail, %{state | read_failure: false}},
             else: {:read, state}
         end) do
      :fail -> {:error, :unavailable}
      :read -> delegate(store, :read, [stream, from, limit])
    end
  end

  def read_at(store, stream, sequence), do: delegate(store, :read_at, [stream, sequence])
  def put_checkpoint(store, checkpoint), do: delegate(store, :put_checkpoint, [checkpoint])

  def latest_checkpoint(store, stream, low_water),
    do: delegate(store, :latest_checkpoint, [stream, low_water])

  def retain(store, stream, from, through, nonce),
    do: delegate(store, :retain, [stream, from, through, nonce])

  def pending(store, stream, from), do: delegate(store, :pending, [stream, from])
  def ack(store, stream, nonce), do: delegate(store, :ack, [stream, nonce])
  def read_ack(store, stream), do: delegate(store, :read_ack, [stream])

  def read_checkpoint(store, stream, revision, limit),
    do: delegate(store, :read_checkpoint, [stream, revision, limit])

  def read_maintenance(store, stream, kind), do: delegate(store, :read_maintenance, [stream, kind])

  def repair_torn_tail(store, stream, expected, nonce, digest),
    do: delegate(store, :repair_torn_tail, [stream, expected, nonce, digest])

  defp store_config({__MODULE__, config}), do: config

  defp delegate(store, operation, args) do
    config = store_config(store)
    {module, options} = config.store
    options = Map.new(options)

    options =
      if config[:repair_owner],
        do: Map.put(options, :repair_owner, config.repair_owner),
        else: options

    apply(module, operation, [{module, options} | args])
  end
end

defmodule Elzoo.RunEngine.RecoveryPattern do
  def step(%{token: token} = state, input) do
    options = :persistent_term.get({__MODULE__, token}, %{})

    if input["kind"] == "outside_event" do
      if options[:counter], do: Agent.update(options.counter, &(&1 + 1))

      case options[:mode] do
        {:block, parent} ->
          send(parent, {:recovery_step_blocked, self(), token})
          receive do: ({:release_recovery_step, ^token} -> :ok)

        _ ->
          :ok
      end

      {:Transition, state, :none}
    else
      if input["kind"] == "start" do
        request =
          Elzoo.RunEngine.TestHelper.request_v2([
            Elzoo.RunEngine.TestHelper.action("wait", "wait_event")
          ])

        {:Transition, state, {:some, request}}
      else
        {:Transition, state, :none}
      end
    end
  end
end

defmodule Elzoo.RunEngineV2SourceTest do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{AsyncWork, DurableLog, DurableUnit, DynamicUnits, Run, RunEngine}
  alias Elzoo.RunEngine.TestHistoryStore
  alias Elzoo.Budget
  alias Elzoo.DurableLog.{Codec, Postgres, Record, Writer}
  alias Elzoo.Lease
  alias Elzoo.RunEngine.TestRepo

  @stream "source-events"
  @source_limits %{max_record_bytes: 262_144, max_batch_size: 8, max_checkpoint_bytes: 10_000}

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  setup_all do
    repo = database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for pid <- [registry, units], do: Process.unlink(pid)

    on_exit(fn ->
      for pid <- [registry, units, repo], Process.alive?(pid), do: Supervisor.stop(pid)
    end)

    :ok
  end

  test "positive low water refuses activation and every fresh read as a source gap" do
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 2, low_water: 1}}, read: nil})
    c = v2_fixture(source(calls))
    engine = start(c)

    result = RunEngine.input(engine, "start", start_input_v2(), verified())
    assert result in [{:ok, :applied}, {:error, :source_gap}]
    assert Agent.get(calls, & &1.heads) == 1
    assert Agent.get(calls, & &1.reads) == 0
    assert activation_records(c) == []

    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 1, low_water: 2}}, read: nil})
    c = v2_fixture(source(calls))
    engine = start(c)

    result = RunEngine.input(engine, "start", start_input_v2(), verified())
    assert result in [{:ok, :applied}, {:error, :source_unavailable}]
    assert Agent.get(calls, & &1.heads) == 1
    assert Agent.get(calls, & &1.reads) == 0
    assert activation_records(c) == []

    calls =
      agent(%{
        heads: 0,
        reads: 0,
        head: {:ok, %{revision: 0, low_water: 0, extra: true}},
        read: nil
      })

    c = v2_fixture(source(calls))
    engine = start(c)
    result = RunEngine.input(engine, "start", start_input_v2(), verified())
    assert result in [{:ok, :applied}, {:error, :source_unavailable}]
    assert Agent.get(calls, & &1.heads) == 1
    assert Agent.get(calls, & &1.reads) == 0
    assert activation_records(c) == []

    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 0, low_water: 0}}, read: nil})
    {c, engine, wait} = start_wait(source(calls))
    assert Agent.get(calls, & &1.heads) == 1
    before = rows(c)
    event = event(wait, "after-retain", %{"accepted" => true}, 2, 2)

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 2, low_water: 1}, event: event}})
    )

    assert {:error, :source_gap} =
             RunEngine.input(engine, "positive-water", input(wait, "after-retain"), context(wait))

    assert Agent.get(calls, & &1.reads) == 1
    assert rows(c) == before

    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 3, low_water: 0}}, read: nil})
    {c, engine, wait} = start_wait(source(calls))
    assert wait.event_cursor == 3
    before = rows(c)
    retained_row = event(wait, "positive-low-water-after-cursor", %{"accepted" => true}, 4, 4)

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 4, low_water: 1}, event: retained_row}})
    )

    assert {:error, :source_gap} =
             RunEngine.input(
               engine,
               "positive-low-water-after-cursor",
               input(wait, retained_row.id),
               context(wait)
             )

    assert rows(c) == before
    assert unit_state(c).slots[wait.occurrence].event_cursor == 3

    behind_head = event(wait, "cursor-past-head", %{"accepted" => true}, 4, 4)

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 2, low_water: 0}, event: behind_head}})
    )

    assert {:error, :source_gap} =
             RunEngine.input(engine, "cursor-past-head", input(wait, behind_head.id), context(wait))

    assert rows(c) == before
    assert unit_state(c).slots[wait.occurrence].event_cursor == 3
  end

  test "local correlation and payload errors occur before source read" do
    calls =
      agent(%{
        heads: 0,
        reads: 0,
        head: {:ok, %{revision: 0, low_water: 0}},
        read: {:error, :not_found}
      })

    {c, engine, wait} = start_wait(source(calls))
    before = rows(c)

    for {fields, expected} <- [
          {%{"action_id" => "wrong"}, :invalid_correlation},
          {%{"source_id" => "wrong"}, :invalid_correlation},
          {%{"correlation_id" => "wrong"}, :invalid_correlation},
          {%{"schema_id" => "action"}, :invalid_payload},
          {%{"schema_version" => 2}, :invalid_payload},
          {%{"event_id" => ""}, :invalid_payload}
        ] do
      assert {:error, ^expected} =
               RunEngine.input(
                 engine,
                 "bad-#{expected}-#{:erlang.phash2(fields)}",
                 input(wait, "valid-event", %{"accepted" => true}, fields),
                 context(wait)
               )
    end

    assert Agent.get(calls, & &1.reads) == 0
    assert rows(c) == before
  end

  test "source read errors and malformed event proofs retain exact failure classes" do
    calls =
      agent(%{
        heads: 0,
        reads: 0,
        head: {:ok, %{revision: 0, low_water: 0}},
        read: {:error, :not_found}
      })

    {c, engine, wait} = start_wait(source(calls))
    before = rows(c)

    for {response, expected} <- [
          {{:error, :not_found}, :source_not_found},
          {{:error, :unavailable}, :source_unavailable},
          {{:error, :gap}, :source_gap},
          {{:ok, %{head: %{revision: 1, low_water: 2}, event: %{}}}, :source_unavailable},
          {{:ok, %{head: %{revision: 1, low_water: 0}, event: %{}}}, :source_unavailable},
          {{:ok, %{head: %{revision: 1, low_water: 0, extra: true}, event: %{}}},
           :source_unavailable},
          {{:ok, %{head: %{revision: 1, low_water: 0}, event: %{}, extra: true}},
           :source_unavailable}
        ] do
      Agent.update(calls, &Map.put(&1, :read, response))

      assert {:error, ^expected} =
               RunEngine.input(
                 engine,
                 "read-#{expected}-#{:erlang.phash2(response)}",
                 input(wait, "event-#{:erlang.phash2(response)}"),
                 context(wait)
               )
    end

    good_event = event(wait, "event-bad-payload", %{"accepted" => false})

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: good_event}})
    )

    assert {:error, :invalid_payload} =
             RunEngine.input(
               engine,
               "bad-event-payload",
               input(wait, "event-bad-payload", %{"accepted" => true}),
               context(wait)
             )

    bad_correlation = %{good_event | correlation_id: "not-the-ticket", id: "event-bad-correlation"}

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: bad_correlation}})
    )

    assert {:error, :invalid_correlation} =
             RunEngine.input(
               engine,
               "bad-event-correlation",
               input(wait, "event-bad-correlation"),
               context(wait)
             )

    beyond_head = event(wait, "sequence-beyond-head", %{"accepted" => true}, 2, 1)

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: beyond_head}})
    )

    assert {:error, :source_unavailable} =
             RunEngine.input(
               engine,
               "sequence-beyond-head",
               input(wait, beyond_head.id),
               context(wait)
             )

    assert rows(c) == before
  end

  test "a matching source row at or before the immutable cursor is invalid correlation" do
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 1, low_water: 0}}, read: nil})
    {c, engine, wait} = start_wait(source(calls))
    assert wait.event_cursor == 1
    before = rows(c)
    already_acknowledged = event(wait, "already-acknowledged", %{"accepted" => true}, 1, 1)

    Agent.update(
      calls,
      &Map.put(
        &1,
        :read,
        {:ok, %{head: %{revision: 2, low_water: 0}, event: already_acknowledged}}
      )
    )

    assert {:error, :invalid_correlation} =
             RunEngine.input(
               engine,
               "already-acknowledged",
               input(wait, already_acknowledged.id),
               context(wait)
             )

    assert Agent.get(calls, & &1.reads) == 1
    assert rows(c) == before
    assert unit_state(c).slots[wait.occurrence].event_cursor == 1
  end

  test "a source failure keeps the nonzero estimate reserved until authorized close" do
    for close <- [:cancel, :attempt] do
      calls =
        agent(%{
          heads: 0,
          reads: 0,
          head: {:ok, %{revision: 0, low_water: 0}},
          read: {:error, :unavailable}
        })

      {c, engine, wait} = start_wait(source(calls))

      assert {:error, :source_unavailable} =
               RunEngine.input(engine, "source-failure", input(wait, "missing"), context(wait))

      reserved = unit_state(c)
      pending_slot = reserved.slots[wait.occurrence]
      assert pending_slot.reservation.estimate > 0
      assert budget_status(reserved, pending_slot).reserved > 0
      assert budget_status(reserved, pending_slot).committed == 0

      case close do
        :cancel ->
          assert {:ok, :applied} =
                   RunEngine.control(
                     engine,
                     "cancel-source-wait",
                     %{kind: :cancel, attempt_id: "attempt"},
                     verified()
                   )

        :attempt ->
          assert {:ok, :applied} =
                   RunEngine.control(
                     engine,
                     "close-source-attempt",
                     %{kind: :begin_attempt, attempt_id: "attempt-two"},
                     verified()
                   )
      end

      closed = unit_state(c)
      closed_slot = closed.slots[wait.occurrence]
      assert closed_slot.phase == :settled
      assert closed_slot.actual == 0
      assert budget_status(closed, closed_slot).reserved == 0
      assert budget_status(closed, closed_slot).committed == 0
    end
  end

  test "an expired v2 wait releases its estimate with zero actual" do
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 0, low_water: 0}}, read: nil})
    {c, engine, wait} = start_wait(source(calls))
    pending = unit_state(c).slots[wait.occurrence]
    assert pending.reservation.estimate > 0

    Agent.update(c.clock, fn _ -> wait.deadline_ms end)
    wake = %{"type" => "input", "version" => 2, "kind" => "wake"}
    assert {:ok, :applied} = RunEngine.input(engine, "expire-v2-wait", wake, verified())

    expired = unit_state(c).slots[wait.occurrence]
    assert expired.phase == :settled
    assert expired.outcome == "expired"
    assert expired.actual == 0
    assert budget_status(unit_state(c), expired).reserved == 0
    assert budget_status(unit_state(c), expired).committed == 0
  end

  test "a completed Run closes its still-open v2 wait with zero actual" do
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 0, low_water: 0}}, read: nil})
    {c, engine, wait} = start_wait(source(calls))
    state = unit_state(c)
    pending = state.slots[wait.occurrence]
    assert pending.reservation.estimate > 0

    assert {:ok, owner} = Elzoo.RunApprovalRelease.status(c.run, "run")

    assert {:ok, _, _} =
             Elzoo.RunApprovalRelease.command(c.run, %{
               kind: :complete,
               run_id: "run",
               attempt_id: "attempt",
               expected_revision: owner.revision,
               outcome: :failed,
               reason: "engine",
               evidence_ref: nil
             })

    wake = %{"type" => "input", "version" => 2, "kind" => "wake"}
    assert {:ok, :applied} = RunEngine.input(engine, "observe-run-close", wake, verified())

    state = unit_state(c)
    slot = state.slots[wait.occurrence]
    assert state.control.lifecycle.phase == :terminal
    assert slot.phase == :settled
    assert slot.actual == 0
    assert slot.reservation.estimate > 0
    assert budget_status(state, slot).reserved == 0
    assert budget_status(state, slot).committed == 0
    assert Agent.get(calls, & &1.reads) == 0
  end

  test "public PostgreSQL checkpoint and retention make a later unacknowledged row a source gap" do
    store_ref = agent(%{store: nil})
    source = postgres_source(store_ref)
    c = v2_fixture(source)

    store = Postgres.store(TestRepo, prefix: c.prefix, fold: source_fold(), limits: @source_limits)
    Agent.update(store_ref, &Map.put(&1, :store, store))
    {c, engine, wait} = start_wait_in_fixture(c)

    first = %{"id" => "discarded", "sequence" => 1}
    assert {:committed, 1} = append_source_record(store, 0, first)
    {:ok, [row], _} = DurableLog.read(store, @stream, 1, 1)
    assert {:committed, 1} = Postgres.put_checkpoint(store, checkpoint([row]))
    assert {:committed, 1} = Postgres.retain(store, @stream, 0, 1, :crypto.strong_rand_bytes(16))
    later = event(wait, "unacknowledged-2", %{"accepted" => true}, 2, 2)
    assert {:committed, 2} = append_source_record(store, 1, later)
    assert {:ok, %{revision: 2, low_water: 1}} = Postgres.head(store, @stream)
    assert {:ok, [stored], %{revision: 2, low_water: 1}} = DurableLog.read(store, @stream, 2, 1)
    assert :erlang.binary_to_term(stored.payload, [:safe]) == later

    before = rows(c)

    assert {:error, :source_gap} =
             RunEngine.input(engine, "retained-away-row", input(wait, later.id), context(wait))

    assert rows(c) == before
    assert view(engine).slots[wait.occurrence].phase == :waiting
  end

  test "head sample is immutable across the commit interval and restart" do
    test_pid = self()
    token = make_ref()
    calls = agent(%{heads: 0, reads: 0, head: nil, read: nil})

    source = %{
      id: "events",
      version: 1,
      head: fn _ ->
        Agent.update(calls, &Map.update!(&1, :heads, fn count -> count + 1 end))
        send(test_pid, {:head_sampled, token, self()})

        receive do
          {:release_head, ^token} -> {:ok, %{revision: 0, low_water: 0}}
        end
      end,
      read: fn _, _event_id ->
        Agent.update(calls, &Map.update!(&1, :reads, fn count -> count + 1 end))
        Agent.get(calls, & &1.read)
      end
    }

    {c, engine} = start_unfed(source)

    start_task =
      Task.async(fn -> RunEngine.input(engine, "start", start_input_v2(), verified()) end)

    assert_receive {:head_sampled, ^token, head_pid}

    ticket =
      Elzoo.RunEngine.EventIdentity.ticket(
        "tenant",
        "principal",
        "run",
        "attempt",
        {1, 0},
        "events"
      )

    admitted =
      event(
        %{source_id: "events", correlation_id: ticket},
        "after-head",
        %{"accepted" => true},
        1,
        1
      )

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: admitted}})
    )

    send(head_pid, {:release_head, token})
    assert {:ok, :applied} = Task.await(start_task)

    wait = wait_slot(engine)
    assert wait.event_cursor == 0
    deadline = wait.deadline_ms
    assert Agent.get(calls, & &1.heads) == 1

    GenServer.stop(engine)
    engine = start(c)
    wait = wait_slot(engine)
    assert wait.event_cursor == 0
    assert wait.deadline_ms == deadline
    assert Agent.get(calls, & &1.heads) == 1

    assert {:ok, :applied} =
             RunEngine.input(engine, "after-head-row", input(wait, "after-head"), context(wait))

    assert Agent.get(calls, & &1.reads) == 1
  end

  test "a blocked source read released at the exact deadline appends no event" do
    test_pid = self()
    token = make_ref()
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 0, low_water: 0}}, read: nil})

    source = %{
      id: "events",
      version: 1,
      head: fn _ -> {:ok, %{revision: 0, low_water: 0}} end,
      read: fn _, _event_id ->
        Agent.update(calls, &Map.update!(&1, :reads, fn count -> count + 1 end))
        send(test_pid, {:read_blocked, token, self()})

        receive do
          {:release_read, ^token} -> Agent.get(calls, & &1.read)
        end
      end
    }

    {c, engine, wait} = start_wait(source)
    before = rows(c)

    response = %{
      head: %{revision: 1, low_water: 0},
      event: event(wait, "at-deadline", %{"accepted" => true})
    }

    Agent.update(calls, &Map.put(&1, :read, {:ok, response}))

    input_task =
      Task.async(fn ->
        RunEngine.input(engine, "deadline-event", input(wait, "at-deadline"), context(wait))
      end)

    assert_receive {:read_blocked, ^token, read_pid}
    Agent.update(c.clock, fn _ -> wait.deadline_ms end)
    send(read_pid, {:release_read, token})

    assert {:error, :invalid_correlation} = Task.await(input_task)
    assert Agent.get(calls, & &1.reads) == 1
    assert rows(c) == before
    assert view(engine).slots[wait.occurrence].phase == :waiting
  end

  test "paused event input fits the exact slot boundary and refuses one byte over before append" do
    {c, engine, wait, calls, state} = paused_wait()
    event_id_size = 131_072 - paused_slot_bytes(state, wait, "x") + 1
    exact_id = String.duplicate("x", event_id_size)
    assert paused_slot_bytes(state, wait, exact_id) == 131_072

    exact_event = event(wait, exact_id, %{"accepted" => true})

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: exact_event}})
    )

    assert {:ok, :applied} =
             RunEngine.input(engine, "exact-fit", input(wait, exact_id), context(wait))

    settled_state = unit_state(c)
    settled = settled_state.slots[wait.occurrence]

    preflight_control =
      update_in(state.control, [:lifecycle, :waits], &Map.delete(&1, wait.action_id))

    control_delta = slot_bytes(settled_state.control) - slot_bytes(preflight_control)

    assert control_delta > 0

    assert control_usage(settled_state) - control_usage(%{state | control: preflight_control}) ==
             control_delta

    assert slot_bytes(settled) == 131_072
    assert settled.phase == :settled
    assert settled.outcome == "completed"
    assert settled.actual == 0
    assert settled.event_receipt == %{input_id: "exact-fit", sequence: 1}
    assert settled.pending_input.record.input =~ exact_id
    assert budget_status(unit_state(c), settled).reserved == 0
    assert budget_status(unit_state(c), settled).committed == 0
    assert view(engine).phase == :paused

    {c, engine, wait, calls, over_state} = paused_wait()
    over_id_size = 131_072 - paused_slot_bytes(over_state, wait, "x", "over-fit") + 2
    over_id = String.duplicate("x", over_id_size)
    assert paused_slot_bytes(over_state, wait, over_id, "over-fit") == 131_073
    over_event = event(wait, over_id, %{"accepted" => true})

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: over_event}})
    )

    before = rows(c)
    before_slot = over_state.slots[wait.occurrence]
    before_slot_bytes = slot_bytes(before_slot)
    before_cursor = before_slot.event_cursor
    before_reservation = before_slot.reservation

    assert {:error, :invalid_payload} =
             RunEngine.input(engine, "over-fit", input(wait, over_id), context(wait))

    assert rows(c) == before
    assert Agent.get(calls, & &1.reads) == 1
    after_slot = unit_state(c).slots[wait.occurrence]
    assert after_slot == before_slot
    assert slot_bytes(after_slot) == before_slot_bytes
    assert after_slot.event_cursor == before_cursor
    assert after_slot.reservation == before_reservation
    assert is_nil(Map.get(after_slot, :event_receipt))
    assert is_nil(after_slot[:pending_input])
    assert after_slot.phase == :waiting
    assert view(engine).phase == :paused

    {c, engine, wait, calls, boundary_state} = paused_wait()

    preflight_control =
      update_in(boundary_state.control, [:lifecycle, :waits], &Map.delete(&1, wait.action_id))

    target = 2_097_152 - control_delta + 1

    padded_candidate =
      boundary_state
      |> Map.put(:control, Map.put(preflight_control, :test_retained_control, ""))

    padding_size = control_padding_size(padded_candidate, target)
    padding = String.duplicate("x", padding_size)

    padded_candidate = %{
      padded_candidate
      | control: Map.put(padded_candidate.control, :test_retained_control, padding)
    }

    assert control_usage(padded_candidate) == target
    assert control_usage(padded_candidate) <= 2_097_152
    assert control_usage(padded_candidate) + control_delta > 2_097_152

    padded_state = %{
      boundary_state
      | control: Map.put(boundary_state.control, :test_retained_control, padding)
    }

    install_unit_state(c, engine, padded_state)
    assert unit_state(c).control.test_retained_control == padding
    boundary_event = event(wait, "control-boundary", %{"accepted" => true})

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: boundary_event}})
    )

    before = rows(c)
    before_slot = padded_state.slots[wait.occurrence]
    before_slot_bytes = slot_bytes(before_slot)
    before_cursor = before_slot.event_cursor
    before_reservation = before_slot.reservation

    assert {:error, :invalid_payload} =
             RunEngine.input(
               engine,
               "control-boundary",
               input(wait, "control-boundary"),
               context(wait)
             )

    assert rows(c) == before
    after_slot = unit_state(c).slots[wait.occurrence]
    assert after_slot == before_slot
    assert slot_bytes(after_slot) == before_slot_bytes
    assert after_slot.event_cursor == before_cursor
    assert after_slot.reservation == before_reservation
    assert is_nil(after_slot[:event_receipt])
    assert is_nil(after_slot[:pending_input])
    assert Agent.get(calls, & &1.reads) == 1
  end

  defp agent(initial),
    do: ExUnit.Callbacks.start_supervised!({Agent, fn -> initial end}, id: make_ref())

  defp source(agent) do
    %{
      id: "events",
      version: 1,
      head: fn scope ->
        Agent.update(agent, &Map.update!(&1, :heads, fn n -> n + 1 end))
        Agent.get(agent, & &1.head) |> invoke_source(scope)
      end,
      read: fn scope, event_id ->
        Agent.update(agent, &Map.update!(&1, :reads, fn n -> n + 1 end))
        Agent.get(agent, & &1.read) |> invoke_read(scope, event_id)
      end
    }
  end

  defp invoke_source(fun, scope) when is_function(fun, 1), do: fun.(scope)
  defp invoke_source(response, _), do: response
  defp invoke_read(fun, scope, event_id) when is_function(fun, 2), do: fun.(scope, event_id)
  defp invoke_read(response, _, _), do: response

  defp start_wait(source, overrides \\ []) do
    c = v2_fixture(source, overrides)
    start_wait_in_fixture(c)
  end

  defp start_wait_in_fixture(c) do
    engine = start(c)
    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
    {c, engine, wait_slot(engine)}
  end

  defp paused_wait do
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 0, low_water: 0}}, read: nil})
    {c, engine, wait} = start_wait(source(calls))

    assert {:ok, :applied} =
             RunEngine.control(
               engine,
               "pause-source-test",
               %{kind: :pause, pause_deadline: 50_000},
               verified()
             )

    assert view(engine).phase == :paused
    {c, engine, wait, calls, unit_state(c)}
  end

  defp unit_state(c) do
    {:ok, unit} = Elzoo.DynamicUnits.start(c.directory, c.opts[:identity])
    Elzoo.DurableUnit.snapshot(unit)
  end

  defp install_unit_state(c, engine, model_state) do
    {:ok, unit} = Elzoo.DynamicUnits.start(c.directory, c.opts[:identity])
    durable_state = :sys.get_state(unit)
    writer = durable_state.writer

    :sys.replace_state(writer, fn writer_state ->
      put_in(writer_state.replay.model.state, model_state)
    end)

    :sys.replace_state(unit, fn state -> put_in(state.model.state, model_state) end)
    :sys.replace_state(engine, fn state -> %{state | state: nil} end)
  end

  defp control_padding_size(state, target), do: control_padding_size(state, target, 0, target)

  defp control_padding_size(state, target, low, high) when low < high do
    middle = div(low + high, 2)
    candidate = put_in(state.control.test_retained_control, String.duplicate("x", middle))

    if control_usage(candidate) < target,
      do: control_padding_size(state, target, middle + 1, high),
      else: control_padding_size(state, target, low, middle)
  end

  defp control_padding_size(_, _, size, size), do: size

  defp control_usage(state) do
    c = state.control

    {callables_skeleton, open_state_delta, open_reserve} =
      Enum.reduce(c.callables, {%{}, 0, 0}, fn {id, node}, {skeleton, delta, reserve} ->
        if node.closed do
          {Map.put(skeleton, id, node), delta, reserve}
        else
          state_bytes = slot_bytes(node.state)
          bound = Map.get(node, :state_bytes, 65_536)

          {Map.put(skeleton, id, %{node | state: ""}), delta + state_bytes - 6,
           reserve + max(0, bound - state_bytes)}
        end
      end)

    control_bytes = slot_bytes(%{c | callables: callables_skeleton}) + open_state_delta

    active =
      Enum.count(state.slots, fn {_, slot} ->
        slot.phase != :settled or slot[:pending_input] != nil
      end)

    reserved = (c.cap + 1 - map_size(c.receipts)) * 1_024 + active * 4_096 + open_reserve
    control_bytes + reserved
  end

  defp slot_bytes(slot),
    do: byte_size(:erlang.term_to_binary(slot, [:deterministic, {:minor_version, 2}]))

  defp budget_status(state, slot) do
    budget = state.control.budgets[slot.callable]
    {:Transition, _, {:some, {:status, status}}} = Budget.step(budget.state, {2_000, :status})
    status
  end

  defp paused_slot_bytes(state, wait, event_id, record_id \\ "exact-fit") do
    input = input(wait, event_id) |> Map.put("at_ms", 2_000)

    record = %{
      version: 2,
      kind: :protocol,
      id: record_id,
      input: input,
      run_id: "run",
      attempt_id: "attempt",
      correlation: %{
        occurrence: wait.occurrence,
        actual: 0,
        source_version: 1,
        source_sequence: 1,
        source_head_revision: 1,
        activation_id: state.slots[wait.occurrence].activation_id,
        event_digest: <<0::256>>
      },
      context: %{pause_deadline: 50_000}
    }

    pending = %{order: 1, record: %{record | input: Jason.encode!(input)}}

    slot =
      state.slots[wait.occurrence]
      |> Map.take([
        :action_id,
        :kind,
        :attempt_id,
        :callable,
        :verdict,
        :reservation,
        :decision,
        :person_id,
        :deadline_ms,
        :resource_name,
        :intent_digest,
        :request_key,
        :event_source_id,
        :event_source_version,
        :event_cursor,
        :event_ticket,
        :activation_id,
        :activation_at_ms,
        :event_receipt
      ])
      |> Map.merge(%{phase: :settled, outcome: "completed", actual: 0})
      |> Map.put(:event_receipt, %{input_id: record_id, sequence: 1})
      |> Map.put(:pending_input, pending)

    slot_bytes(slot)
  end

  test "paired retries and notifications leave a paused later input and fenced Unit untouched" do
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 0, low_water: 0}}, read: nil})
    clock_calls = agent(0)

    clock = fn ->
      Agent.update(clock_calls, &(&1 + 1))
      2_000
    end

    c = v2_fixture(source(calls), clock: clock)
    engine = start(c)

    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
    wait = wait_slot(engine)

    assert {:ok, :applied} =
             RunEngine.control(
               engine,
               "pause-before-replay",
               %{kind: :pause, pause_deadline: 50_000},
               verified()
             )

    event = event(wait, "event-after-pause", %{"accepted" => true})

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: event}})
    )

    event_id = "paired-replay-input"
    outside_input = input(wait, event.id)
    outside_context = context(wait)
    assert {:ok, :applied} = RunEngine.input(engine, event_id, outside_input, outside_context)

    settled = unit_state(c).slots[wait.occurrence]
    pending = settled.pending_input
    refute is_nil(pending)
    before = rows(c)
    record = stored_input_record(c, event_id)
    assert record.input["at_ms"] == 2_000

    Agent.update(calls, &Map.put(&1, :read, {:error, :unavailable}))
    {:ok, unit} = DynamicUnits.find(c.directory, c.opts[:identity])
    assert :ok = DynamicUnits.stop(c.directory, c.opts[:identity])
    refute Process.alive?(unit)
    :sys.replace_state(engine, &Map.put(&1, :halted, :delivery_unknown))
    clock_before = Agent.get(clock_calls, & &1)

    assert {:ok, :unchanged} = RunEngine.input(engine, event_id, outside_input, outside_context)

    assert {:error, :input_id_conflict} =
             RunEngine.input(
               engine,
               event_id,
               Map.put(outside_input, "payload", %{"changed" => true}),
               outside_context
             )

    assert {:error, :input_id_conflict} =
             RunEngine.input(
               engine,
               event_id,
               outside_input,
               Map.put(outside_context, :run_id, "run-two")
             )

    assert {:error, :delivery_unknown} =
             RunEngine.input(
               engine,
               "fresh-while-halted",
               input(wait, "fresh-event"),
               outside_context
             )

    send(engine, {:durable_unit_input, event_id, record})
    _ = :sys.get_state(engine)

    send(
      engine,
      {:durable_unit_input, "notification-only",
       Map.put(record, :input, input(wait, "not-admitted-event"))}
    )

    _ = :sys.get_state(engine)

    assert :not_found = DynamicUnits.find(c.directory, c.opts[:identity])
    assert rows(c) == before
    assert Agent.get(calls, & &1.reads) == 1
    assert Agent.get(clock_calls, & &1) == clock_before
    assert settled.pending_input == pending
  end

  test "history lookup distinguishes store uncertainty, confirmed absence, and pruned history" do
    control = agent(%{read_failure: false, result_barrier: :disabled, parent: nil, token: nil})

    calls =
      agent(%{
        heads: 0,
        reads: 0,
        head: {:ok, %{revision: 0, low_water: 0}},
        read: {:error, :not_found}
      })

    c = v2_fixture(source(calls)) |> wrap_unit_store(control)
    tree = start_owned_tree(c, c.run)
    on_exit(fn -> stop_owned_tree(tree) end)

    assert {:ok, :applied} = RunEngine.input(tree.engine, "start", start_input_v2(), verified())
    wait = wait_slot(tree.engine)
    before = rows(c)
    TestHistoryStore.arm_read_failure(control)

    assert {:error, :source_unavailable} =
             RunEngine.input(tree.engine, "unknown-history", input(wait, "missing"), context(wait))

    assert rows(c) == before
    assert Agent.get(calls, & &1.reads) == 0

    assert {:error, :source_not_found} =
             RunEngine.input(tree.engine, "confirmed-absent", input(wait, "missing"), context(wait))

    assert Agent.get(calls, & &1.reads) == 1
    event = event(wait, "accepted-event", %{"accepted" => true})

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: event}})
    )

    event_id = "pruned-original"
    outside_input = input(wait, event.id)
    outside_context = context(wait)
    assert {:ok, :applied} = RunEngine.input(tree.engine, event_id, outside_input, outside_context)
    assert Agent.get(calls, & &1.reads) == 2

    assert {:committed, revision} = DurableUnit.checkpoint(tree.unit)

    assert {:ok, pending} = Postgres.pending(c.postgres_unit_store, c.opts[:identity], 128)

    Enum.each(pending, fn item ->
      assert {:committed, _} =
               Postgres.ack(c.postgres_unit_store, item.idempotency_key, item.nonce)
    end)

    assert {:ok, []} = Postgres.pending(c.postgres_unit_store, c.opts[:identity], 128)

    assert {:committed, ^revision} =
             Postgres.retain(
               c.postgres_unit_store,
               c.opts[:identity],
               0,
               revision,
               :crypto.strong_rand_bytes(16)
             )

    assert {:ok, %{revision: ^revision, low_water: low_water}} =
             Postgres.head(c.postgres_unit_store, c.opts[:identity])

    assert low_water > 0

    before_pruned_retry = Postgres.head(c.postgres_unit_store, c.opts[:identity])

    assert {:error, :source_gap} =
             RunEngine.input(tree.engine, event_id, outside_input, outside_context)

    assert Postgres.head(c.postgres_unit_store, c.opts[:identity]) == before_pruned_retry
    assert Agent.get(calls, & &1.reads) == 2
  end

  test "retrying a committed unpaired original fences the active Engine, Unit, and work owner" do
    control = agent(%{read_failure: false, result_barrier: :disabled, parent: nil, token: nil})
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 0, low_water: 0}}, read: nil})
    pattern_calls = agent(0)
    token = "faulted-input-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    :persistent_term.put(
      {Elzoo.RunEngine.RecoveryPattern, token},
      %{mode: :continue, counter: pattern_calls}
    )

    on_exit(fn -> :persistent_term.erase({Elzoo.RunEngine.RecoveryPattern, token}) end)

    c =
      v2_fixture(source(calls),
        pattern: {Elzoo.RunEngine.RecoveryPattern, :step, %{token: token}}
      )
      |> wrap_unit_store(control)

    tree = start_owned_tree(c, c.run)
    on_exit(fn -> stop_owned_tree(tree) end)
    assert {:ok, :applied} = RunEngine.input(tree.engine, "start", start_input_v2(), verified())
    wait = wait_slot(tree.engine)
    event = event(wait, "committed-before-lost-reply", %{"accepted" => true})

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: event}})
    )

    event_id = "unpaired-after-fault"
    outside_input = input(wait, event.id)
    outside_context = context(wait)
    TestHistoryStore.arm_input_commit_failure(control)

    assert {:error, :storage_unknown} =
             RunEngine.input(tree.engine, event_id, outside_input, outside_context)

    before_retry = rows(c)
    original = stored_input_record(c, event_id)
    assert original.input["at_ms"] == 2_000
    refute has_result_row?(before_retry, event_id)
    assert Agent.get(pattern_calls, & &1) == 0

    engine_monitor = Process.monitor(tree.engine)
    async_monitor = Process.monitor(tree.async_work)
    unit_monitor = Process.monitor(tree.unit)
    writer_monitor = Process.monitor(tree.writer)

    assert {:error, :storage_unknown} =
             RunEngine.input(tree.engine, event_id, outside_input, outside_context)

    assert_receive {:DOWN, ^engine_monitor, :process, engine, _}, 5_000
    assert engine == tree.engine
    assert_receive {:DOWN, ^async_monitor, :process, async_work, _}, 5_000
    assert async_work == tree.async_work
    assert_receive {:DOWN, ^unit_monitor, :process, unit, _}, 5_000
    assert unit == tree.unit
    assert_receive {:DOWN, ^writer_monitor, :process, writer, _}, 5_000
    assert writer == tree.writer

    assert :not_found = DynamicUnits.find(tree.directory, c.opts[:identity])
    assert rows(c) == before_retry
    assert stored_input_record(c, event_id) == original
    assert Agent.get(pattern_calls, & &1) == 0
    assert Agent.get(calls, & &1.reads) == 1
  end

  test "an unpaired retry does not claim a fence when its work owner is unavailable" do
    control = agent(%{read_failure: false, result_barrier: :disabled, parent: nil, token: nil})
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 0, low_water: 0}}, read: nil})
    pattern_calls = agent(0)
    token = "failed-fence-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    :persistent_term.put(
      {Elzoo.RunEngine.RecoveryPattern, token},
      %{mode: :continue, counter: pattern_calls}
    )

    on_exit(fn -> :persistent_term.erase({Elzoo.RunEngine.RecoveryPattern, token}) end)

    c =
      v2_fixture(source(calls),
        pattern: {Elzoo.RunEngine.RecoveryPattern, :step, %{token: token}}
      )
      |> wrap_unit_store(control)

    tree = start_owned_tree(c, c.run)
    on_exit(fn -> stop_owned_tree(tree) end)
    assert {:ok, :applied} = RunEngine.input(tree.engine, "start", start_input_v2(), verified())
    wait = wait_slot(tree.engine)
    event = event(wait, "failed-fence-original", %{"accepted" => true})

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: event}})
    )

    event_id = "unpaired-with-unavailable-work"
    outside_input = input(wait, event.id)
    outside_context = context(wait)
    TestHistoryStore.arm_input_commit_failure(control)

    assert {:error, :storage_unknown} =
             RunEngine.input(tree.engine, event_id, outside_input, outside_context)

    before_retry = rows(c)
    assert :ok = GenServer.stop(tree.async_work, :normal, 5_000)

    assert {:error, :stop_unknown} =
             RunEngine.input(tree.engine, event_id, outside_input, outside_context)

    assert Process.alive?(tree.engine)
    assert :not_found = DynamicUnits.find(tree.directory, c.opts[:identity])
    assert rows(c) == before_retry
    assert Agent.get(pattern_calls, & &1) == 0
    assert Agent.get(calls, & &1.reads) == 1
  end

  test "unpaired original input resumes from stored time and facts after owner-tree fencing" do
    control = agent(%{read_failure: false, result_barrier: :disabled, parent: nil, token: nil})
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 0, low_water: 0}}, read: nil})
    pattern_calls = agent(0)
    token = "recovery-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    :persistent_term.put(
      {Elzoo.RunEngine.RecoveryPattern, token},
      %{mode: {:block, self()}, counter: pattern_calls}
    )

    on_exit(fn -> :persistent_term.erase({Elzoo.RunEngine.RecoveryPattern, token}) end)

    c =
      v2_fixture(source(calls), pattern: {Elzoo.RunEngine.RecoveryPattern, :step, %{token: token}})

    c = wrap_unit_store(c, control)
    tree = start_owned_tree(c, c.run)
    on_exit(fn -> stop_owned_tree(tree) end)

    assert {:ok, :applied} = RunEngine.input(tree.engine, "start", start_input_v2(), verified())
    wait = wait_slot(tree.engine)
    event = event(wait, "recovery-event", %{"accepted" => true})

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: event}})
    )

    event_id = "unpaired-original"
    outside_input = input(wait, event.id)
    outside_context = context(wait)
    parent = self()

    spawn(fn ->
      result =
        try do
          RunEngine.input(tree.engine, event_id, outside_input, outside_context)
        catch
          :exit, _ -> :caller_fenced
        end

      send(parent, {:outside_call_finished, token, result})
    end)

    unit = tree.unit
    assert_receive {:recovery_step_blocked, ^unit, ^token}, 5_000
    rows_before_fence = rows(c)
    original = stored_input_record(c, event_id)
    assert original.input["at_ms"] == 2_000
    assert original.correlation.source_sequence == 1
    assert original.correlation.source_head_revision == 1
    refute has_result_row?(rows_before_fence, event_id)

    fence_tree(tree, [])
    assert_receive {:outside_call_finished, ^token, :caller_fenced}, 5_000
    assert rows(c) == rows_before_fence

    :persistent_term.put(
      {Elzoo.RunEngine.RecoveryPattern, token},
      %{mode: :continue, counter: pattern_calls}
    )

    new_run = restart_run_owner(c)
    restarted = start_owned_tree(c, new_run)
    on_exit(fn -> stop_owned_tree(restarted) end)
    recovered_rows = rows(c)
    assert stored_input_record(c, event_id) == original
    assert has_result_row?(recovered_rows, event_id)
    assert Agent.get(pattern_calls, & &1) == 2
    assert Agent.get(calls, & &1.reads) == 1

    assert {:ok, :unchanged} =
             RunEngine.input(restarted.engine, event_id, outside_input, outside_context)

    assert rows(c) == recovered_rows
    assert Agent.get(pattern_calls, & &1) == 2
    assert Agent.get(calls, & &1.reads) == 1
  end

  test "a result committed before reply loss replays without rerunning the Operator" do
    control = agent(%{read_failure: false, result_barrier: :disabled, parent: nil, token: nil})
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 0, low_water: 0}}, read: nil})
    pattern_calls = agent(0)
    pattern_token = "paired-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    :persistent_term.put(
      {Elzoo.RunEngine.RecoveryPattern, pattern_token},
      %{mode: :continue, counter: pattern_calls}
    )

    on_exit(fn -> :persistent_term.erase({Elzoo.RunEngine.RecoveryPattern, pattern_token}) end)

    c =
      v2_fixture(source(calls),
        pattern: {Elzoo.RunEngine.RecoveryPattern, :step, %{token: pattern_token}}
      )
      |> wrap_unit_store(control)

    tree = start_owned_tree(c, c.run)
    on_exit(fn -> stop_owned_tree(tree) end)
    assert {:ok, :applied} = RunEngine.input(tree.engine, "start", start_input_v2(), verified())
    wait = wait_slot(tree.engine)
    event = event(wait, "after-result-commit", %{"accepted" => true})

    Agent.update(
      calls,
      &Map.put(&1, :read, {:ok, %{head: %{revision: 1, low_water: 0}, event: event}})
    )

    event_id = "paired-after-commit"
    outside_input = input(wait, event.id)
    outside_context = context(wait)
    barrier = make_ref()
    TestHistoryStore.arm_result_barrier(control, self(), barrier)
    parent = self()

    caller =
      spawn(fn ->
        result = RunEngine.input(tree.engine, event_id, outside_input, outside_context)
        send(parent, {:outside_call_finished, barrier, result})
      end)

    assert_receive {:result_committed, ^barrier, _writer, {:committed, _}}, 5_000
    rows_after_commit = rows(c)
    original = stored_input_record(c, event_id)
    assert has_result_row?(rows_after_commit, event_id)
    assert original.input["at_ms"] == 2_000
    refute_receive {:outside_call_finished, ^barrier, _}, 0

    fence_tree(tree, [caller])
    assert rows(c) == rows_after_commit

    new_run = restart_run_owner(c)
    restarted = start_owned_tree(c, new_run)
    on_exit(fn -> stop_owned_tree(restarted) end)
    recovered_rows = rows(c)
    assert stored_input_record(c, event_id) == original
    assert has_result_row?(recovered_rows, event_id)
    assert Agent.get(pattern_calls, & &1) == 1
    assert Agent.get(calls, & &1.reads) == 1

    assert {:ok, :unchanged} =
             RunEngine.input(restarted.engine, event_id, outside_input, outside_context)

    assert rows(c) == recovered_rows
    assert Agent.get(pattern_calls, & &1) == 1
    assert Agent.get(calls, & &1.reads) == 1
  end

  test "an authoritative Run cancellation wins a source-read barrier race" do
    test_pid = self()
    token = make_ref()
    calls = agent(%{heads: 0, reads: 0, head: {:ok, %{revision: 0, low_water: 0}}, read: nil})
    {c, engine, wait} = start_wait(source(calls))
    before = rows(c)

    Agent.update(calls, fn state ->
      Map.put(state, :read, fn _scope, event_id ->
        send(test_pid, {:source_read_blocked, token, self()})

        receive do
          {:release_source_read, ^token} ->
            {:ok,
             %{
               head: %{revision: 1, low_water: 0},
               event: %{
                 id: event_id,
                 source_id: "events",
                 correlation_id: wait.event_ticket,
                 sequence: 1,
                 schema_id: "result",
                 schema_version: 1,
                 payload: %{"accepted" => true}
               }
             }}
        end
      end)
    end)

    task =
      Task.async(fn ->
        RunEngine.input(engine, "cancel-race", input(wait, "race-event"), context(wait))
      end)

    assert_receive {:source_read_blocked, ^token, source_pid}
    {:ok, owner} = Run.status(c.run, "run")

    assert {:ok, _, _} =
             Run.command(c.run, %{
               kind: :cancel,
               run_id: "run",
               attempt_id: "attempt",
               expected_revision: owner.revision
             })

    send(source_pid, {:release_source_read, token})
    assert {:error, :invalid_correlation} = Task.await(task, 5_000)
    assert rows(c) == before
    assert Agent.get(calls, & &1.reads) == 1
  end

  defp wrap_unit_store(c, control) do
    store = TestHistoryStore.new(c.postgres_unit_store, control)

    %{
      c
      | store: store,
        unit_opts: Keyword.put(c.unit_opts, :store, store),
        opts: Keyword.put(c.opts, :store, store)
    }
  end

  defp start_owned_tree(c, run_owner) do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 2)
    Process.unlink(supervisor)
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    Process.unlink(task_supervisor)

    evidence_state = :sys.get_state(c.evidence)

    {:ok, evidence_writer} =
      Writer.start_link(
        store: evidence_state.store,
        stream: evidence_state.stream,
        fold: evidence_state.fold,
        limits: evidence_state.limits
      )

    Process.unlink(evidence_writer)

    {:ok, async_work} =
      AsyncWork.start_link(
        owner: c.opts[:name],
        task_supervisor: task_supervisor,
        max_concurrency: 4
      )

    Process.unlink(async_work)

    {:ok, directory} =
      DynamicUnits.start_link(
        registry: Elzoo.RunEngine.UnitRegistry,
        supervisor: supervisor,
        unit_options: fn _ -> c.unit_opts end,
        idle_ms: 60_000
      )

    Process.unlink(directory)

    engine_opts =
      c.opts
      |> Keyword.merge(
        directory: directory,
        async_work: async_work,
        run_owner: run_owner
      )
      |> Keyword.put(:evidence, Map.put(c.opts[:evidence], :writer, evidence_writer))

    {:ok, engine} = RunEngine.start_link(engine_opts)
    Process.unlink(engine)
    {:ok, unit} = DynamicUnits.find(directory, c.opts[:identity])
    writer = :sys.get_state(unit).writer

    %{
      engine: engine,
      directory: directory,
      supervisor: supervisor,
      task_supervisor: task_supervisor,
      async_work: async_work,
      unit: unit,
      writer: writer,
      evidence_writer: evidence_writer,
      run_owner: run_owner
    }
  end

  defp restart_run_owner(c) do
    {:held, held} = Lease.hold(c.lease, c.held.live.key, c.held.owner)

    {:ok, run_owner} =
      Run.start_link(
        store: c.run_store,
        lease: c.lease,
        held: held,
        effect_intent: c.opts[:effect_intent]
      )

    Process.unlink(run_owner)
    run_owner
  end

  defp stop_owned_tree(tree) do
    tree
    |> Map.values()
    |> Enum.filter(&is_pid/1)
    |> Enum.each(fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end

  defp fence_tree(tree, extra) do
    pids =
      (Map.values(tree) ++ extra)
      |> Enum.filter(&is_pid/1)
      |> Enum.uniq()

    monitors = Enum.map(pids, &{&1, Process.monitor(&1)})
    Enum.each(pids, &Process.exit(&1, :kill))

    Enum.each(monitors, fn {pid, reference} ->
      assert_receive {:DOWN, ^reference, :process, ^pid, _reason}, 5_000
    end)
  end

  defp stored_input_record(c, id) do
    Enum.find_value(rows(c), fn
      %{kind: "input", payload: payload} ->
        case :erlang.binary_to_term(payload, [:safe]) do
          {1, {^id, record}} -> record
          _ -> nil
        end

      _ ->
        nil
    end) || flunk("missing durable input #{id}")
  end

  defp has_result_row?(rows, id) do
    Enum.any?(rows, fn
      %{kind: "result", payload: payload} ->
        match?({1, {^id, _}}, :erlang.binary_to_term(payload, [:safe]))

      _ ->
        false
    end)
  end

  defp start_unfed(source) do
    c = v2_fixture(source)
    {c, start(c)}
  end

  defp v2_fixture(source, overrides \\ []) do
    pattern =
      {Elzoo.RunEngine.TestPattern, :step,
       %{requests: [request_v2([action("wait", "wait_event")])]}}

    fixture(
      Keyword.merge(
        [protocol_version: 2, event_source: source, pattern: pattern],
        overrides
      )
    )
  end

  defp wait_slot(engine) do
    scope = %{tenant: "tenant", principal: "principal", run_id: "run"}
    limits = %{max_records: 65_536, max_bytes: 536_870_912}
    assert {:ok, %{waits: [waiting]}} = RunEngine.event_waits(engine, scope, limits)

    waiting
    |> Map.put(:event_ticket, waiting.correlation_id)
    |> Map.put(:event_source_id, waiting.source_id)
    |> Map.put(:event_cursor, waiting.cursor)
  end

  defp input(wait, event_id, payload \\ %{"accepted" => true}, fields \\ %{}) do
    Map.merge(
      %{
        "type" => "input",
        "version" => 2,
        "kind" => "outside_event",
        "action_id" => wait.action_id,
        "source_id" => wait.event_source_id,
        "correlation_id" => wait.event_ticket,
        "event_id" => event_id,
        "schema_id" => "result",
        "schema_version" => 1,
        "payload" => payload
      },
      fields
    )
  end

  defp context(wait),
    do: verified(%{occurrence: wait.occurrence, actual: 0, dispatch: "not_dispatched"})

  defp event(wait, id, payload, sequence \\ 1, _revision \\ 1) do
    source_id = Map.get(wait, :source_id, "events")
    correlation_id = Map.get(wait, :correlation_id) || Map.get(wait, :event_ticket)

    %{
      id: id,
      source_id: source_id,
      correlation_id: correlation_id,
      sequence: sequence,
      schema_id: "result",
      schema_version: 1,
      payload: payload
    }
  end

  defp postgres_source(store_ref) do
    %{
      id: "events",
      version: 1,
      head: fn _ ->
        store = Agent.get(store_ref, & &1.store)

        with {:ok, head} <- Postgres.head(store, @stream),
             do: {:ok, Map.take(head, [:revision, :low_water])}
      end,
      read: fn _, event_id ->
        store = Agent.get(store_ref, & &1.store)

        case DurableLog.read(store, @stream, 2, 1) do
          {:ok, [row], head} ->
            event = :erlang.binary_to_term(row.payload, [:safe])

            if event.id == event_id,
              do: {:ok, %{head: Map.take(head, [:revision, :low_water]), event: event}},
              else: {:error, :not_found}

          {:ok, [], _} ->
            {:error, :not_found}

          {:error, {:pruned, _}} ->
            {:error, :gap}

          _ ->
            {:error, :unavailable}
        end
      end
    }
  end

  defp append_source_record(store, expected, event) do
    sequence = expected + 1

    record = %Record{
      stream: @stream,
      sequence: sequence,
      kind: "event",
      schema_version: 1,
      payload: :erlang.term_to_binary(event, [:deterministic, {:minor_version, 2}]),
      nonce: :crypto.strong_rand_bytes(16)
    }

    record = %{record | digest: DurableLog.digest(record)}
    Postgres.append(store, @stream, expected, [record], [])
  end

  defp checkpoint(rows) do
    replay = DurableLog.replay(rows, List.last(rows).sequence, source_fold())

    checkpoint = %{
      stream: @stream,
      sequence: elem(replay.cursor, 0),
      fold_version: 1,
      model: Integer.to_string(replay.model),
      cursor: replay.cursor,
      seen: replay.seen,
      nonce: :crypto.strong_rand_bytes(16)
    }

    Map.put(checkpoint, :digest, Codec.hash(Codec.checkpoint_bytes(checkpoint)))
  end

  defp source_fold do
    %{
      initial: 0,
      kinds: %{"event" => :state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn n, _, _, _ -> n + 1 end
    }
  end

  defp activation_records(c) do
    for row <- rows(c),
        row.kind == "input",
        {1, {_, %{kind: :event_activation} = record}} <- [
          :erlang.binary_to_term(row.payload, [:safe])
        ],
        do: record
  end
end
