# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ScheduleOccurrenceTest do
  use ExUnit.Case, async: false
  alias Elzoo.ScheduleOccurrence, as: S

  @source File.read!(Path.expand("../../cure/elzoo/schedule_occurrence.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  defp schedule(policy, overrides \\ %{}),
    do:
      Map.merge(
        %{schedule_id: "digest", generation: 1, policy: policy, payload: "weekly"},
        overrides
      )

  defp arrival(now, boundary), do: %{now_unix_ms: now, available_since_unix_ms: boundary}
  defp id(slot, gen \\ 1, sid \\ "digest"), do: {:OccurrenceId, sid, gen, slot}
  defp unsettled(state), do: elem(S.inspect_state(state), 1).unsettled
  defp watermark(state), do: elem(S.inspect_state(state), 1).last_recorded_unix_ms

  # A serialized test owner: the only process that applies transitions. It also
  # follows the delivery/time recipe as the clock port: timer scheduling with
  # Process.send_after and clock reads stay in this shell; the pure transition
  # receives the instant and the boundary as data.
  defmodule Owner do
    use GenServer

    def start_link(state, opts), do: GenServer.start_link(__MODULE__, {state, opts}, [])

    def init({state, opts}),
      do:
        {:ok,
         %{
           state: state,
           clock: opts[:clock],
           boundary: opts[:boundary],
           slots: opts[:slots] || [],
           log: [],
           timer: nil
         }}

    def handle_call({:admit, slots, arrival}, _from, owner) do
      {:ok, next, decisions} = Elzoo.ScheduleOccurrence.admit_slots(owner.state, slots, arrival)
      {:reply, decisions, %{owner | state: next}}
    end

    # The delivery/time recipe: Process.send_after schedules the tick and the
    # returned reference cancels it. The owner keeps at most one pending timer.
    def handle_call({:schedule_tick, delay_ms}, _from, %{timer: nil} = owner) do
      timer = Process.send_after(self(), :tick, delay_ms)
      {:reply, {:ok, timer}, %{owner | timer: timer}}
    end

    def handle_call({:schedule_tick, _delay_ms}, _from, owner),
      do: {:reply, {:error, :timer_pending}, owner}

    # A tick already handled leaves no timer; cancelling then is a no-op reply,
    # never a call to Process.cancel_timer(nil).
    def handle_call(:cancel_tick, _from, %{timer: nil} = owner),
      do: {:reply, {:ok, :no_timer}, owner}

    def handle_call(:cancel_tick, _from, owner) do
      case Process.cancel_timer(owner.timer) do
        remaining when is_integer(remaining) ->
          {:reply, {:ok, {:cancelled, remaining}}, %{owner | timer: nil}}

        false ->
          {:reply, {:ok, :already_fired}, %{owner | timer: nil}}
      end
    end

    def handle_call(:log, _from, owner), do: {:reply, Enum.reverse(owner.log), owner}

    def handle_info(:tick, owner) do
      now = owner.clock.()
      due = Enum.filter(owner.slots, &(&1 <= now))

      {:ok, next, decisions} =
        Elzoo.ScheduleOccurrence.admit_slots(owner.state, due, %{
          now_unix_ms: now,
          available_since_unix_ms: owner.boundary
        })

      {:noreply, %{owner | state: next, log: [{now, decisions} | owner.log], timer: nil}}
    end
  end

  test "S1 two activations of one slot: sequential replay and two concurrent callers through one owner" do
    {:ok, state} = S.new(schedule(:skip), 0)
    {:ok, state1, decision} = S.admit_slot(state, 1_000, arrival(1_000, 500))
    assert decision == {:occurrence, id(1_000), :live}
    {:ok, state2, second} = S.admit_slot(state1, 1_000, arrival(1_001, 500))
    assert second == {:already_recorded, 1_000}
    assert state2 == state1

    {:ok, owner} = Owner.start_link(state, [])
    parent = self()

    for n <- 1..2 do
      spawn_link(fn ->
        send(
          parent,
          {:activation, n, GenServer.call(owner, {:admit, [1_000], arrival(1_000 + n, 500)})}
        )
      end)
    end

    results = for _ <- 1..2, do: receive(do: ({:activation, _, decisions} -> decisions))

    assert Enum.sort(results) ==
             Enum.sort([[{:occurrence, id(1_000), :live}], [{:already_recorded, 1_000}]])

    # Conclusion scoped to serialized ownership: both activations went through one process.
  end

  test "S2 restart with an unsettled occurrence keeps identity for the retry and refuses the duplicate" do
    {:ok, state} = S.new(schedule(:skip), 0)
    {:ok, state, _} = S.admit_slot(state, 1_000, arrival(1_000, 0))
    retained = S.inspect_state(state) |> elem(1)

    {:ok, restored} =
      S.restore(retained.schedule, retained.last_recorded_unix_ms, retained.unsettled)

    assert restored == state
    {:ok, restored, decision} = S.admit_slot(restored, 1_000, arrival(5_000, 4_000))
    assert decision == {:already_recorded, 1_000}
    assert S.admit_delivery(restored, id(1_000), "weekly") == {:ok, :admitted}
    assert S.admit_delivery(restored, id(1_000), "weekly") == {:ok, :admitted}
    {:ok, settled, result} = S.settle(restored, {:acknowledged, id(1_000)})
    assert result == {:settled, :acknowledged, id(1_000)}
    assert unsettled(settled) == []
    assert S.admit_delivery(settled, id(1_000), "weekly") == {:ok, {:rejected, :unknown_occurrence}}

    assert {:ok, ^settled, {:rejected, :unknown_occurrence}} =
             S.settle(settled, {:released, id(1_000)})

    assert S.restore(retained.schedule, 999, retained.unsettled) == {:error, :invalid_unsettled}

    assert S.restore(retained.schedule, 1_000, [id(1_000), id(1_000)]) ==
             {:error, :invalid_unsettled}

    assert S.restore(retained.schedule, 1_000, [id(500), id(1_000)]) == {:error, :invalid_unsettled}
  end

  test "S3 replay after a skipped slot, after settlement and after a redefinition records only the slot" do
    {:ok, state} = S.new(schedule(:skip), 0)
    {:ok, state, _} = S.admit_slot(state, 1_000, arrival(1_000, 0))
    {:ok, state, skipped} = S.admit_slot(state, 2_000, arrival(2_000, 0))
    assert skipped == {:skipped, 2_000, :overlap}
    {:ok, state, replay} = S.admit_slot(state, 2_000, arrival(2_000, 0))
    assert replay == {:already_recorded, 2_000}
    {:ok, state, _} = S.settle(state, {:acknowledged, id(1_000)})
    {:ok, state, replay} = S.admit_slot(state, 1_000, arrival(2_000, 0))
    assert replay == {:already_recorded, 1_000}
    {:ok, state, {:redefined, 1, []}} = S.redefine(state, schedule({:queue, 2}, %{generation: 2}))
    {:ok, same, replay} = S.admit_slot(state, 2_000, arrival(3_000, 0))
    assert replay == {:already_recorded, 2_000}
    assert same == state
    assert watermark(same) == 2_000
  end

  test "S4 skip: overlap skipped, settlement frees the slot" do
    {:ok, state} = S.new(schedule(:skip), 0)
    {:ok, state, decisions} = S.admit_slots(state, [1_000, 2_000], arrival(2_000, 0))
    assert decisions == [{:occurrence, id(1_000), :live}, {:skipped, 2_000, :overlap}]
    assert unsettled(state) == [id(1_000)]
    assert watermark(state) == 2_000
    {:ok, state, _} = S.settle(state, {:released, id(1_000)})
    {:ok, state, decision} = S.admit_slot(state, 3_000, arrival(3_000, 0))
    assert decision == {:occurrence, id(3_000), :live}
    assert unsettled(state) == [id(3_000)]
  end

  test "S5 queue(2): bound, queue_full and release" do
    {:ok, state} = S.new(schedule({:queue, 2}), 0)
    {:ok, state, decisions} = S.admit_slots(state, [1_000, 2_000, 3_000], arrival(3_000, 0))

    assert decisions == [
             {:occurrence, id(1_000), :live},
             {:occurrence, id(2_000), :live},
             {:skipped, 3_000, :queue_full}
           ]

    assert Enum.sort(unsettled(state)) == [id(1_000), id(2_000)]
    {:ok, state, _} = S.settle(state, {:acknowledged, id(1_000)})
    {:ok, state, decision} = S.admit_slot(state, 4_000, arrival(4_000, 0))
    assert decision == {:occurrence, id(4_000), :live}
    assert Enum.sort(unsettled(state)) == [id(2_000), id(4_000)]
  end

  test "S6 replace: replaced{old, new}; old delivery and old settlement rejected" do
    {:ok, state} = S.new(schedule(:replace), 0)
    {:ok, state, decisions} = S.admit_slots(state, [1_000, 2_000], arrival(2_000, 0))
    assert decisions == [{:occurrence, id(1_000), :live}, {:replaced, id(1_000), id(2_000)}]
    assert unsettled(state) == [id(2_000)]
    assert S.admit_delivery(state, id(1_000), "weekly") == {:ok, {:rejected, :unknown_occurrence}}

    assert {:ok, ^state, {:rejected, :unknown_occurrence}} =
             S.settle(state, {:acknowledged, id(1_000)})

    assert S.admit_delivery(state, id(2_000), "weekly") == {:ok, :admitted}
  end

  test "S7 offline catch-up: skipped under skip and replace, bounded admission under queue" do
    for policy <- [:skip, :replace] do
      {:ok, state} = S.new(schedule(policy), 0)
      {:ok, state, decisions} = S.admit_slots(state, [1_000, 2_000, 3_000], arrival(3_500, 2_500))

      assert decisions == [
               {:skipped, 1_000, :offline_catch_up},
               {:skipped, 2_000, :offline_catch_up},
               {:occurrence, id(3_000), :live}
             ]

      assert unsettled(state) == [id(3_000)]
      assert watermark(state) == 3_000
    end

    {:ok, state} = S.new(schedule({:queue, 2}), 0)

    {:ok, state, decisions} =
      S.admit_slots(state, [1_000, 2_000, 3_000, 4_000], arrival(4_500, 3_500))

    assert decisions == [
             {:occurrence, id(1_000), :offline_catch_up},
             {:occurrence, id(2_000), :offline_catch_up},
             {:skipped, 3_000, :queue_full},
             {:skipped, 4_000, :queue_full}
           ]

    assert watermark(state) == 4_000
    # a live slot after an offline slot in the same batch follows the overlap policy
    {:ok, state} = S.new(schedule(:skip), 0)
    {:ok, _, decisions} = S.admit_slots(state, [1_000, 2_000], arrival(2_000, 1_500))
    assert decisions == [{:skipped, 1_000, :offline_catch_up}, {:occurrence, id(2_000), :live}]
  end

  test "S8 clock and ordering edges and fail-closed refusals" do
    {:ok, state} = S.new(schedule(:skip), 500)
    {:ok, _, decision} = S.admit_slot(state, 1_000, arrival(1_000, 1_000))
    assert decision == {:occurrence, id(1_000), :live}, "slot equal to the boundary is live"
    {:ok, _, decision} = S.admit_slot(state, 1_000, arrival(1_000, 0))
    assert decision == {:occurrence, id(1_000), :live}, "slot equal to now is due"
    assert S.admit_slot(state, 1_001, arrival(1_000, 0)) == {:error, {:not_due, 1_001}}
    assert S.admit_slots(state, [600, 1_001], arrival(1_000, 0)) == {:error, {:not_due, 1_001}}
    assert S.admit_slot(state, 600, arrival(1_000, 1_001)) == {:error, :boundary_after_now}

    assert S.admit_slot(state, 600, %{now_unix_ms: 1_000}) ==
             {:error, :missing_availability_boundary}

    assert S.admit_slot(state, 600, %{now_unix_ms: 1_000, available_since_unix_ms: nil}) ==
             {:error, :invalid_arrival}

    assert S.admit_slot(state, 600, nil) == {:error, :invalid_arrival}
    assert S.admit_slots(state, [700, 600], arrival(1_000, 0)) == {:error, :unsorted_slots}
    assert S.admit_slots(state, [600, :x], arrival(1_000, 0)) == {:error, :invalid_slots}
    assert S.admit_slots(state, [600 | 700], arrival(1_000, 0)) == {:error, :invalid_slots}
    {:ok, next, decisions} = S.admit_slots(state, [600, 600], arrival(1_000, 0))
    assert decisions == [{:occurrence, id(600), :live}, {:already_recorded, 600}]
    assert unsettled(next) == [id(600)]
    {:ok, _, decision} = S.admit_slot(state, 500, arrival(1_000, 0))
    assert decision == {:already_recorded, 500}, "initial watermark excludes earlier slots"
    {:ok, _, decision} = S.admit_slot(state, 400, arrival(1_000, 0))
    assert decision == {:already_recorded, 400}
  end

  test "S9 generation: stale redefinitions keep pending work, greater generation supersedes" do
    {:ok, state} = S.new(schedule({:queue, 2}), 0)
    {:ok, state, _} = S.admit_slots(state, [1_000, 2_000], arrival(2_000, 0))

    for gen <- [0, 1] do
      assert {:ok, ^state, {:rejected, :stale_generation}} =
               S.redefine(state, schedule(:skip, %{generation: gen}))
    end

    assert {:ok, ^state, {:rejected, :schedule_mismatch}} =
             S.redefine(state, schedule(:skip, %{generation: 2, schedule_id: "other"}))

    assert S.redefine(state, schedule({:queue, 0}, %{generation: 2})) == {:error, :invalid_policy}
    {:ok, next, result} = S.redefine(state, schedule(:replace, %{generation: 2, payload: "daily"}))
    assert result == {:redefined, 1, [id(2_000), id(1_000)]}
    assert unsettled(next) == []
    assert watermark(next) == 2_000
    assert {:ok, ^next, {:rejected, :stale_generation}} = S.settle(next, {:acknowledged, id(1_000)})
    assert S.admit_delivery(next, id(1_000), "weekly") == {:ok, {:rejected, :stale_generation}}
    {:ok, next, decision} = S.admit_slot(next, 2_000, arrival(3_000, 0))
    assert decision == {:already_recorded, 2_000}, "watermark kept across redefinition"
    {:ok, next, decision} = S.admit_slot(next, 3_000, arrival(3_000, 0))
    assert decision == {:occurrence, id(3_000, 2), :live}
    assert S.admit_delivery(next, id(3_000, 2), "daily") == {:ok, :admitted}
    assert S.admit_delivery(next, id(3_000, 2), "weekly") == {:ok, {:rejected, :payload_mismatch}}
  end

  test "S10 delivery admission is a query" do
    {:ok, state} = S.new(schedule(:skip), 0)
    {:ok, state, _} = S.admit_slot(state, 1_000, arrival(1_000, 0))
    assert S.admit_delivery(state, id(1_000), "other") == {:ok, {:rejected, :payload_mismatch}}
    assert S.admit_delivery(state, id(2_000), "weekly") == {:ok, {:rejected, :unknown_occurrence}}

    assert S.admit_delivery(state, id(1_000, 1, "other"), "weekly") ==
             {:ok, {:rejected, :unknown_occurrence}}

    assert S.admit_delivery(state, id(1_000), "weekly") == {:ok, :admitted}
    assert S.admit_delivery(state, {:OccurrenceId, "", 1, 1_000}, "weekly") == {:error, :invalid_id}
    assert S.admit_delivery(state, :bad, "weekly") == {:error, :invalid_delivery}
    assert S.admit_delivery(:bad, id(1_000), "weekly") == {:error, :invalid_state}
    assert S.settle(state, {:done, id(1_000)}) == {:error, :invalid_settlement}
  end

  test "S11 identity fields, encoding round trip and DST fixtures as supplied instants" do
    assert S.identify("digest", 1, 1_000) == id(1_000)
    assert S.identify("", 1, 1_000) == {:error, :invalid_id}
    assert S.identify("digest", -1, 1_000) == {:error, :invalid_id}

    for sid <- ["digest", "a:b:c", "x@y", "https://example.test/sched?x=1:2"] do
      {:ok, text} = S.encode_id(id(-5, 7, sid))
      assert text == "7:-5:" <> sid
      assert S.decode_id(text) == {:ok, id(-5, 7, sid)}
    end

    assert S.decode_id("7:5") == {:error, :invalid_encoded_id}
    assert S.decode_id("x:5:digest") == {:error, :invalid_encoded_id}
    assert S.decode_id("7:5:") == {:error, :invalid_encoded_id}
    assert S.encode_id({:OccurrenceId, "", 1, 1}) == {:error, :invalid_id}

    # Europe/Berlin 2026-10-25 fall-back: wall-clock 02:30 happens at two instants.
    first = DateTime.to_unix(~U[2026-10-25 00:30:00Z], :millisecond)
    second = DateTime.to_unix(~U[2026-10-25 01:30:00Z], :millisecond)
    assert first != second
    {:ok, state} = S.new(schedule({:queue, 2}), 0)
    {:ok, state, decisions} = S.admit_slots(state, [first, second], arrival(second, 0))
    assert decisions == [{:occurrence, id(first), :live}, {:occurrence, id(second), :live}]
    assert length(Enum.uniq(unsettled(state))) == 2

    # 2026-03-29 spring-forward: a calculator shifting the missing 02:30 to 03:00 CEST
    # yields the same instant as the 03:00 slot; one identity results.
    shifted = DateTime.to_unix(~U[2026-03-29 01:00:00Z], :millisecond)
    {:ok, state} = S.new(schedule({:queue, 2}), 0)
    {:ok, state, decisions} = S.admit_slots(state, [shifted, shifted], arrival(shifted, 0))
    assert decisions == [{:occurrence, id(shifted), :live}, {:already_recorded, shifted}]
    assert unsettled(state) == [id(shifted)]
  end

  test "S12 configuration and malformed terms are refused" do
    assert S.new(schedule(:cron), 0) == {:error, :invalid_policy}
    assert S.new(schedule({:queue, 0}), 0) == {:error, :invalid_policy}
    assert S.new(schedule({:queue, 1_025}), 0) == {:error, :invalid_policy}
    assert {:ok, _} = S.new(schedule({:queue, 1_024}), 0)
    assert S.new(schedule(:skip, %{schedule_id: ""}), 0) == {:error, :invalid_schedule_id}
    assert S.new(schedule(:skip, %{generation: -1}), 0) == {:error, :invalid_generation}
    assert S.new(schedule(:skip, %{payload: 1}), 0) == {:error, :invalid_payload}
    assert S.new(%{}, 0) == {:error, :invalid_schedule}
    assert S.new(schedule(:skip), 1.5) == {:error, :invalid_instant}

    for bad <- [
          nil,
          {:ScheduleState, {:Schedule, "d", 1, :Skip, "p"}, 0.0, []},
          {:ScheduleState, {:Schedule, "d", 1, :Skip, "p"}, 10,
           [{:Occurrence, id(5, 1, "d"), "p"}, {:Occurrence, id(6, 1, "d"), "p"}]},
          {:ScheduleState, {:Schedule, "d", 1, :Skip, "p"}, 10,
           [{:Occurrence, id(11, 1, "d"), "p"}]},
          {:ScheduleState, {:Schedule, "d", 1, :Skip, "p"}, 10,
           [{:Occurrence, id(5, 1, "d"), "other"}]},
          {:ScheduleState, {:Schedule, "d", 1, :Skip, "p"}, 10,
           [{:Occurrence, id(5, 2, "d"), "p"}]},
          {:ScheduleState, {:Schedule, "d", 1, {:Queue, :Z}, "p"}, 10, []},
          {:ScheduleState, {:Schedule, "d", 1, {:Queue, {:S, :bad}}, "p"}, 10, []},
          {:ScheduleState, {:Schedule, "d", 1, :Skip, "p"}, 10, [1 | 2]}
        ] do
      assert S.admit_slot(bad, 20, arrival(20, 0)) == {:error, :invalid_state}
      assert S.inspect_state(bad) == {:error, :invalid_state}
      assert S.redefine(bad, schedule(:skip, %{generation: 2})) == {:error, :invalid_state}
    end

    {:ok, state} = S.new(schedule({:queue, 3}), 0)

    assert S.inspect_state(state) ==
             {:ok, %{schedule: schedule({:queue, 3}), last_recorded_unix_ms: 0, unsettled: []}}
  end

  test "S13a composition: core/envelope DeliveryResult rows settle or leave the occurrence" do
    {:ok, state} = S.new(schedule(:skip), 0)
    {:ok, state, _} = S.admit_slot(state, 1_000, arrival(1_000, 0))
    {:ok, key} = S.encode_id(id(1_000))

    base = %{"version" => 1, "message_id" => "m-1", "correlation_id" => key}

    completed =
      Map.merge(base, %{
        "outcome" => "completed",
        "dispatch" => "dispatched",
        "value" => %{},
        "value_schema_id" => "digest.result",
        "value_schema_version" => 1
      })

    rows = [
      {completed, {:acknowledged, id(1_000)}},
      {Map.merge(base, %{
         "outcome" => "rejected",
         "dispatch" => "not_dispatched",
         "error_class" => "permanent"
       }), {:released, id(1_000)}},
      {Map.merge(base, %{
         "outcome" => "failed",
         "dispatch" => "dispatched",
         "error_class" => "permanent"
       }), {:released, id(1_000)}},
      {Map.merge(base, %{
         "outcome" => "timed_out",
         "dispatch" => "not_dispatched",
         "error_class" => "retryable"
       }), :no_settlement},
      {Map.merge(base, %{
         "outcome" => "timed_out",
         "dispatch" => "dispatched",
         "error_class" => "unclassified"
       }), :no_settlement},
      {Map.merge(base, %{
         "outcome" => "timed_out",
         "dispatch" => "unknown",
         "error_class" => "unclassified"
       }), :no_settlement},
      {Map.merge(base, %{
         "outcome" => "unknown",
         "dispatch" => "unknown",
         "error_class" => "unavailable"
       }), :no_settlement}
    ]

    for {result, expected} <- rows do
      assert {:ok, _} = Elzoo.Envelope.validate_result(result)
      assert S.settlement_from_result(result) == {:ok, expected}

      case expected do
        :no_settlement ->
          assert unsettled(state) == [id(1_000)]

        {kind, settlement_id} = settlement ->
          assert {:ok, next, {:settled, ^kind, ^settlement_id}} = S.settle(state, settlement)
          assert unsettled(next) == []
      end
    end

    assert S.settlement_from_result(Map.delete(completed, "dispatch")) == {:error, :invalid_shape}

    assert S.settlement_from_result(Map.put(completed, "correlation_id", "not-an-id")) ==
             {:error, :invalid_correlation_id}

    assert S.settlement_from_result(Map.put(completed, "outcome", "done")) ==
             {:error, :invalid_outcome}
  end

  test "S13b composition: per-schedule delivery/idempotency histories, collision scenario, retirement" do
    histories = %{}
    {:ok, histories, :emit} = S.consumer_dedup(histories, id(1_000, 1, "digest"), 7)
    {:ok, histories, :suppress} = S.consumer_dedup(histories, id(1_000, 1, "digest"), 7)
    {:ok, histories, :suppress} = S.consumer_dedup(histories, id(1_000, 1, "digest"), 8)
    # a different schedule with the same generation and instant is not suppressed (isolation)
    {:ok, histories, :emit} = S.consumer_dedup(histories, id(1_000, 1, "sweep"), 7)
    {:ok, histories, :suppress} = S.consumer_dedup(histories, id(1_000, 1, "sweep"), 7)
    {:ok, histories, :suppress} = S.consumer_dedup(histories, id(1_000, 1, "digest"), 7)
    # a new generation is a new incarnation
    {:ok, histories, :emit} = S.consumer_dedup(histories, id(1_000, 2, "digest"), 7)
    {:ok, histories, :suppress} = S.consumer_dedup(histories, id(1_000, 2, "digest"), 7)
    {:ok, histories, :emit} = S.consumer_dedup(histories, id(2_000, 2, "digest"), 7)
    assert Map.keys(histories) |> Enum.sort() == ["digest", "sweep"]

    assert histories["digest"] == [
             {:Message, 0, 2, 2_000, 7},
             {:Message, 0, 2, 1_000, 7},
             {:Message, 0, 1, 1_000, 7}
           ]

    # retirement: history gone, later presentation emits again
    {:ok, histories} = S.forget_schedule(histories, "digest")
    refute Map.has_key?(histories, "digest")
    {:ok, histories, :emit} = S.consumer_dedup(histories, id(1_000, 1, "digest"), 7)
    {:ok, _, :suppress} = S.consumer_dedup(histories, id(1_000, 1, "sweep"), 9)
    assert S.consumer_dedup(histories, {:OccurrenceId, "", 1, 1}, 7) == {:error, :invalid_id}
    assert S.consumer_dedup(histories, id(1), 1.0) == {:error, :invalid_delivery}
    assert S.forget_schedule(histories, 1) == {:error, :invalid_schedule_id}
  end

  test "S13c composition: the delivery/time recipe as the clock port of the owner" do
    {:ok, state} = S.new(schedule(:skip), 0)
    {:ok, clock} = Agent.start_link(fn -> 1_000 end)

    {:ok, owner} =
      Owner.start_link(state,
        clock: fn -> Agent.get(clock, & &1) end,
        boundary: 900,
        slots: [500, 1_000, 2_000]
      )

    # tick 1: Process.send_after delivers, the shell reads the clock, the pure
    # transition receives the instant and the boundary as data
    assert {:ok, timer} = GenServer.call(owner, {:schedule_tick, 0})
    assert is_reference(timer)
    assert eventually(fn -> GenServer.call(owner, :log) != [] end)

    assert GenServer.call(owner, :log) == [
             {1_000, [{:skipped, 500, :offline_catch_up}, {:occurrence, id(1_000), :live}]}
           ]

    # tick 2 with a later clock reading
    Agent.update(clock, fn _ -> 2_000 end)
    assert {:ok, _} = GenServer.call(owner, {:schedule_tick, 0})
    assert eventually(fn -> length(GenServer.call(owner, :log)) == 2 end)

    assert Enum.at(GenServer.call(owner, :log), 1) ==
             {2_000,
              [{:already_recorded, 500}, {:already_recorded, 1_000}, {:skipped, 2_000, :overlap}]}

    # deterministic cancellation: a timer one hour away is still pending when
    # cancelled, Process.cancel_timer returns the remaining time, and no tick
    # message reaches the owner afterwards
    Agent.update(clock, fn _ -> 3_000 end)
    assert {:ok, pending} = GenServer.call(owner, {:schedule_tick, 3_600_000})
    assert is_integer(Process.read_timer(pending))
    assert {:ok, {:cancelled, remaining}} = GenServer.call(owner, :cancel_tick)
    assert is_integer(remaining) and remaining > 0
    assert Process.read_timer(pending) == false
    assert {:message_queue_len, 0} = Process.info(owner, :message_queue_len)
    assert length(GenServer.call(owner, :log)) == 2
    assert {:ok, :no_timer} = GenServer.call(owner, :cancel_tick)
    assert Process.alive?(owner)
  end

  test "S13d tick handled before cancel: the owner replies no_timer and survives" do
    {:ok, state} = S.new(schedule(:skip), 0)

    {:ok, owner} =
      Owner.start_link(state, clock: fn -> 1_000 end, boundary: 0, slots: [1_000])

    assert {:ok, timer} = GenServer.call(owner, {:schedule_tick, 0})
    # wait until the tick is handled, so the cancel deterministically comes after it
    assert eventually(fn -> GenServer.call(owner, :log) != [] end)
    assert Process.read_timer(timer) == false
    assert {:ok, :no_timer} = GenServer.call(owner, :cancel_tick)
    assert Process.alive?(owner)
    assert GenServer.call(owner, :log) == [{1_000, [{:occurrence, id(1_000), :live}]}]
    # a second pending timer is refused while one exists, then cancels cleanly
    assert {:ok, _} = GenServer.call(owner, {:schedule_tick, 3_600_000})
    assert {:error, :timer_pending} = GenServer.call(owner, {:schedule_tick, 0})
    assert {:ok, {:cancelled, _}} = GenServer.call(owner, :cancel_tick)
    assert length(GenServer.call(owner, :log)) == 1
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(5)
        eventually(fun, tries - 1)
    end
  end

  test "S14 seeded random trace against an independent model" do
    :rand.seed(:exsss, {27, 44, 2026})

    for policy <- [:skip, :replace, {:queue, 1}, {:queue, 3}] do
      {:ok, state} = S.new(schedule(policy), 0)
      bound = if match?({:queue, _}, policy), do: elem(policy, 1), else: 1
      model = %{watermark: 0, unsettled: [], next: 1}

      Enum.reduce(1..300, {state, model}, fn _, {state, model} ->
        if :rand.uniform(3) == 1 and model.unsettled != [] do
          slot = Enum.random(model.unsettled)
          kind = Enum.random([:acknowledged, :released])
          {:ok, next, {:settled, ^kind, _}} = S.settle(state, {kind, id(slot)})
          {next, %{model | unsettled: List.delete(model.unsettled, slot)}}
        else
          count = :rand.uniform(3)

          slots =
            Enum.map(0..(count - 1), &(model.next - :rand.uniform(2) + &1 * 10)) |> Enum.sort()

          now = Enum.max(slots) + :rand.uniform(5) - 1
          boundary = now - :rand.uniform(25) + 1
          {:ok, next, decisions} = S.admit_slots(state, slots, arrival(now, boundary))

          {expected, model} =
            Enum.map_reduce(slots, model, &model_step(&1, &2, policy, bound, boundary))

          assert decisions == expected
          assert Enum.sort(unsettled(next)) == Enum.sort(Enum.map(model.unsettled, &id/1))
          assert watermark(next) == model.watermark
          assert length(model.unsettled) <= bound
          {next, %{model | next: Enum.max(slots) + 1}}
        end
      end)
    end
  end

  defp model_step(slot, model, policy, bound, boundary) do
    cond do
      slot <= model.watermark ->
        {{:already_recorded, slot}, model}

      slot < boundary and policy in [:skip, :replace] ->
        {{:skipped, slot, :offline_catch_up}, %{model | watermark: slot}}

      match?({:queue, _}, policy) ->
        origin = if slot < boundary, do: :offline_catch_up, else: :live

        if length(model.unsettled) < bound,
          do:
            {{:occurrence, id(slot), origin},
             %{model | watermark: slot, unsettled: model.unsettled ++ [slot]}},
          else: {{:skipped, slot, :queue_full}, %{model | watermark: slot}}

      policy == :skip ->
        if model.unsettled == [],
          do: {{:occurrence, id(slot), :live}, %{model | watermark: slot, unsettled: [slot]}},
          else: {{:skipped, slot, :overlap}, %{model | watermark: slot}}

      policy == :replace ->
        case model.unsettled do
          [] -> {{:occurrence, id(slot), :live}, %{model | watermark: slot, unsettled: [slot]}}
          [old] -> {{:replaced, id(old), id(slot)}, %{model | watermark: slot, unsettled: [slot]}}
        end
    end
  end

  test "S15 Cure audit is clean and production mutations fail at the named laws" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(report, key) == [])

    assert report.absurd == 0

    controls = [
      {"OccurrenceId{schedule_id: schedule_id, generation: generation, scheduled_unix_ms: scheduled_unix_ms}",
       "OccurrenceId{schedule_id: schedule_id, generation: generation + 1, scheduled_unix_ms: scheduled_unix_ms}",
       "identify_generation"},
      {"OccurrenceId{schedule_id: schedule_id, generation: generation, scheduled_unix_ms: scheduled_unix_ms}",
       "OccurrenceId{schedule_id: schedule_id, generation: generation, scheduled_unix_ms: 0}",
       "identify_instant"},
      {"Occurrence{id: identify(schedule.schedule_id, schedule.generation, scheduled_unix_ms), payload: schedule.payload}",
       "Occurrence{id: identify(schedule.schedule_id, schedule.generation, scheduled_unix_ms + 1), payload: schedule.payload}",
       "live_identity_skip"},
      {"      Z() -> false\n      S(smaller) ->\n        match entries",
       "      Z() -> true\n      S(smaller) ->\n        match entries", "room_true_within"},
      {"[head | tail] -> SlotResult{state: advanced(state, scheduled_unix_ms, entries), decision: SkippedOverlap()}",
       "[head | tail] -> SlotResult{state: advanced(state, scheduled_unix_ms, [created(state.schedule, scheduled_unix_ms) | entries]), decision: SkippedOverlap()}",
       "place_skip_within"},
      {"True() -> SlotResult{state: state, decision: AlreadyRecorded(scheduled_unix_ms)}",
       "True() -> admit_due(state, scheduled_unix_ms, arrival, now_of(arrival) < scheduled_unix_ms)",
       "admit_recorded_skip_within"},
      {"      False() -> RedefinitionResult{state: state, decision: RejectedRedefinition(RedefinitionStaleGeneration())}",
       "      False() -> RedefinitionResult{state: ScheduleState{schedule: schedule, last_recorded_unix_ms: state.last_recorded_unix_ms, unsettled: []}, decision: RejectedRedefinition(RedefinitionStaleGeneration())}",
       "redefine_generation_stale"}
    ]

    for {{from, to, law}, index} <- Enum.with_index(controls) do
      assert length(String.split(@source, from)) == 2,
             "control #{index} must match the production source once"

      mutated =
        @source
        |> String.replace("mod Elzoo.ScheduleOccurrence", "mod Elzoo.Mutant#{index}")
        |> String.replace(from, to)

      assert mutated != @source

      assert {:error, {:codegen_error, {:source_context, _, context}}} =
               Cure.Compiler.compile_and_load(mutated, source_roots: @roots)

      assert law_lines(@source, law) |> Enum.member?(context.line),
             "control #{index} must fail inside law #{law}, failed at line #{context.line}"
    end
  end

  # Line span of a law: from its `fn name(` line to the line before the next blank line.
  defp law_lines(source, law) do
    lines = String.split(source, "\n")
    start = Enum.find_index(lines, &String.starts_with?(&1, "  fn #{law}("))
    finish = Enum.drop(lines, start) |> Enum.find_index(&(&1 == "")) |> Kernel.+(start)
    (start + 1)..finish
  end
end
