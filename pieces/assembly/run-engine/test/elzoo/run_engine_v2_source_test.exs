## SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineV2SourceTest do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableLog, RunEngine}
  alias Elzoo.Budget
  alias Elzoo.DurableLog.{Codec, Postgres, Record}
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
