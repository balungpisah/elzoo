# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineExpiryReportTest do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableUnit, DynamicUnits, RunEngine}
  alias Elzoo.RunEngine.TestPattern

  # One pinned engine identity: engine record IDs hash it (gate:, out:), and the
  # fixture's own identity is its random schema prefix.
  @identity "elzoo-run-engine-expiry-report"

  # The default-off trace of the recorded scenario, recorded on the base commit
  # 3e412170 before the option existed (three equal runs there).
  @golden_sha256 "36c17202b1427e9e6008a54914f521746b73c5c1c7f3766f4de47640150a9ba4"
  @golden_bytes 19_644

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  setup_all do
    pid = database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for p <- [registry, units], do: Process.unlink(p)
    on_exit(fn -> for p <- [registry, units, pid], Process.alive?(p), do: Supervisor.stop(p) end)
    :ok
  end

  describe "default_off_is_unchanged" do
    test "the recorded scenario without the option has the trace of the base" do
      trace = recorded_scenario([])
      bin = :erlang.term_to_binary(trace, [:deterministic, {:minor_version, 2}])
      sha = Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

      assert {sha, byte_size(bin)} == {@golden_sha256, @golden_bytes}
    end

    test "the configure record differs only by the option, and a changed option is no recovery" do
      # The same start on two fixtures of the same pinned identity, without and with
      # the option.
      {c0, bindings0} = reports_setup([:wait], %{}, %{})
      engine0 = start(c0, bindings: bindings0)
      [{_, %{kind: :configure, control: without}} | _] = unit_inputs(c0)
      refute Map.has_key?(without, :expiry_reports)

      # Started with the option, a Run configured without it is no recovery.
      GenServer.stop(engine0)

      assert {:error, :incompatible_recovery} =
               start_link(c0, bindings: bindings0, expiry_reports: :owner)

      assert :ok = DynamicUnits.stop(c0.directory, identity(c0))

      {c1, bindings1} = reports_setup([:wait], %{}, %{})
      engine1 = start(c1, bindings: bindings1, expiry_reports: :owner)
      [{_, %{kind: :configure, control: with_option}} | _] = unit_inputs(c1)
      assert with_option.expiry_reports == :owner
      assert with_option.fingerprint != without.fingerprint

      assert Map.drop(with_option, [:expiry_reports, :fingerprint]) ==
               Map.delete(without, :fingerprint)

      # And the reverse.
      GenServer.stop(engine1)
      assert {:error, :incompatible_recovery} = start_link(c1, bindings: bindings1)
    end

    test "any other value or a second key is refused before a Unit starts" do
      {c, bindings} = reports_setup([:wait], %{}, %{})

      for options <- [
            [expiry_reports: :nested],
            [expiry_reports: true],
            [expiry_reports: nil],
            [expiry_reports: :owner, expiry_reports: :owner]
          ] do
        assert {:error, :invalid_options_or_recovery} =
                 RunEngine.start_link(c.opts ++ [bindings: bindings] ++ options)

        assert DynamicUnits.find(c.directory, identity(c)) == :not_found
      end

      # Valid with protocol_version 1 and 2.
      _engine = start(c, bindings: bindings, protocol_version: 1, expiry_reports: :owner)
      assert unit_state(c).control.expiry_reports == :owner
    end
  end

  describe "nested_turn_reads_its_expiries" do
    test "a nested callable is given its three expired tool slots in order and finishes" do
      %{c: c, engine: engine} = nested_turn()
      tools = [{2, 0}, {2, 1}, {2, 2}]
      inputs = pattern_inputs()

      reports =
        for {id, key} <- Enum.zip(["t1", "t2", "t3"], tools), do: expired(id, key, 40_000)

      assert [%{"kind" => "start"} | ^reports] = inputs_of(inputs, "nested")

      # The root is given its start and its parent outcome, never the tool slots.
      [%{"kind" => "start"}, parent] = inputs_of(inputs, "root")
      assert parent["action_id"] == "nested" and parent["outcome"] == "completed"
      assert parent["payload"] == %{"seen" => List.last(reports)["payload"]}

      state = unit_state(c)
      # The finish request of the third report is charged one count.
      assert state.control.count == 3
      assert state.control.receipts[3].input_id == resume_id({2, 2})
      assert state.control.receipts[3].callable == "1:0"
      # The parent is completed with no actual: the tool costs are final unknown.
      assert %{phase: :settled, outcome: "completed"} = state.slots[{1, 0}]
      assert state.slots[{1, 0}][:actual] == nil
      # Each tool slot's Budget entry is held with no actual: nothing commits or
      # releases it, and the Budget's own expiry at the deadline stops counting it.
      {:BudgetState, _, _, _, _, 0, _, entries} = state.control.budgets["1:0"].state

      for {request, index} = key <- tools do
        assert state.slots[key][:actual] == nil and state.slots[key].reservation.estimate == 1
        ref = {:String, ~c"#{request}:#{index}"}
        assert [{:EntryRow, ^ref, {:Expired, 1}}] = for({:EntryRow, ^ref, _} = e <- entries, do: e)
      end

      assert resume_records(c) == Enum.map(tools, &{resume_id(&1), &1})
      assert Enum.all?(tools, &(view(engine).slots[&1].outcome == "expired"))

      # The three settlements are in the wake's record, by :protocol with no reason;
      # the report records give no entry.
      {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())
      wake_entry = Enum.find(entries, &(&1.type == :input and &1.input_id == "w"))

      settlements =
        for e <- entries, e.type == :settlement, e.occurrence in tools, do: e

      assert length(settlements) == 3

      for e <- settlements do
        assert e.sequence == wake_entry.sequence
        assert e.by == :protocol and e.reason == nil and e.outcome == "expired"
      end

      resume_sequences = resume_sequences(c)
      refute Enum.any?(entries, &(&1.sequence in resume_sequences))
    end
  end

  describe "several_expiries_in_one_wake" do
    test "each report reaches only its own callable, in occurrence order across callables" do
      %{c: c, engine: engine, keys: keys} = several()
      inputs = pattern_inputs()

      expected = [
        {"root", expired("ask", keys["ask"], 40_000)},
        {"C", expired("t1", keys["t1"], 40_000)},
        {"C", expired("t2", keys["t2"], 40_000)},
        {"D", expired("lw", keys["lw"], 40_000)}
      ]

      assert Enum.reject(inputs, fn {_, i} -> i["kind"] == "start" end) == expected
      assert keys["ask"] < keys["t1"] and keys["t2"] < keys["lw"]

      # The request of C's first report is admitted, and its slot progresses only after
      # the last report: its gate record follows the last report record.
      more = wait_for(engine, &(slot_by(&1, "more")[:phase] == :running))
      assert slot_by(more, "more").kind == "tool_call"
      {more_request, _} = key_of(more, "more")
      records = unit_inputs(c)
      last_report = last_index(records, &match?(%{kind: :resume_input}, &1))

      gate =
        Enum.find_index(records, fn {_, r} ->
          match?(%{kind: :gate, request: ^more_request}, r)
        end)

      assert last_report < gate
      assert length(resume_records(c)) == 4
    end

    test "a root with one expired slot is given its report, not the wake, and then the next wake" do
      {c, bindings} =
        reports_setup([request([action("ask", "ask_person")]), :wait, :wait], %{}, %{})

      engine = start(c, bindings: bindings, expiry_reports: :owner)
      assert {:ok, :applied} = send_input(engine)
      at(c, 40_000)
      assert {:ok, _} = RunEngine.input(engine, "w1", wake(), verified())
      assert [%{"kind" => "start"}, report] = inputs_of(pattern_inputs(), "root")
      assert report == expired("ask", {1, 0}, 40_000)

      at(c, 41_000)
      assert {:ok, _} = RunEngine.input(engine, "w2", wake(), verified())
      assert [%{"kind" => "wake", "at_ms" => 41_000}] = inputs_of(pattern_inputs(), "root")
    end
  end

  describe "closed_owner_gets_nothing" do
    test "a wake that expires a tool slot and its parent together reports only the parent" do
      {c, bindings} =
        reports_setup(
          [request([action("nested", "nested_callable")]), :wait],
          %{
            "nested" => [request([action("t1", "tool_call")]), :wait]
          },
          %{}
        )

      engine = start(c, bindings: bindings, expiry_reports: :owner)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, _, _}, 5_000
      wait_for(engine, &(&1.slots[{2, 0}][:phase] == :running))
      at(c, 40_000)
      assert {:ok, _} = RunEngine.input(engine, "w", wake(), verified())
      inputs = pattern_inputs()
      assert [%{"kind" => "start"}] = inputs_of(inputs, "nested")
      assert [%{"kind" => "start"}, report] = inputs_of(inputs, "root")
      assert report == expired("nested", {1, 0}, 40_000)
      assert resume_records(c) == [{resume_id({1, 0}), {1, 0}}]
      assert view(engine).slots[{2, 0}].outcome == "expired"
    end

    test "reports held while paused are dropped when their owner closes" do
      {c, bindings} =
        reports_setup(
          [request([action("nested", "nested_callable")]), :wait],
          %{"nested" => [request([action("t1", "tool_call"), action("t2", "tool_call")]), :wait]},
          %{"nested" => 45_000}
        )

      engine = start(c, bindings: bindings, expiry_reports: :owner)
      assert {:ok, :applied} = send_input(engine)
      for _ <- 1..2, do: assert_receive({:effect_started, _, _}, 5_000)
      wait_for(engine, &(&1.slots[{2, 1}][:phase] == :running))
      assert {:ok, :applied} = pause(engine)
      at(c, 40_000)
      assert {:ok, _} = RunEngine.input(engine, "w1", wake(), verified())
      assert held(c) == [{2, 0}, {2, 1}]
      at(c, 45_000)
      assert {:ok, _} = RunEngine.input(engine, "w2", wake(), verified())
      assert unit_state(c).control.callables["1:0"].closed
      assert held(c) == [{1, 0}]
      assert {:ok, :applied} = continue(engine)

      inputs = pattern_inputs()
      assert [%{"kind" => "start"}] = inputs_of(inputs, "nested")
      assert [%{"kind" => "start"}, report] = inputs_of(inputs, "root")
      assert report == expired("nested", {1, 0}, 45_000)
      assert resume_records(c) == [{resume_id({1, 0}), {1, 0}}]
      assert held(c) == []
    end

    test "a change of Attempt drops every held report and writes no report record" do
      {c, bindings} =
        reports_setup(
          [request([action("a1", "ask_person"), action("a2", "ask_person")]), :wait],
          %{},
          %{}
        )

      engine = start(c, bindings: bindings, expiry_reports: :owner)
      assert {:ok, :applied} = send_input(engine)
      assert {:ok, :applied} = pause(engine)
      at(c, 40_000)
      assert {:ok, _} = RunEngine.input(engine, "w", wake(), verified())
      assert held(c) == [{1, 0}, {1, 1}]

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "attempt-change",
                 %{kind: :begin_attempt, attempt_id: "second"},
                 verified()
               )

      assert view(engine).attempt_id == "second"
      assert held(c) == []
      assert resume_records(c) == []
      refute Enum.any?(inputs_of(pattern_inputs(), "root"), &(&1["outcome"] == "expired"))
    end
  end

  describe "ending_drops_reports" do
    test "an expiry in the step of a cancel holds reports that are never given" do
      cancel = %{"type" => "input", "version" => 1, "kind" => "cancel", "attempt_id" => "attempt"}

      ending_drops(:cancelled, fn c, engine ->
        # The cancel's own step holds both reports beside the pending stop.
        state = unit_state(c)
        record = protocol_record("end", Map.put(cancel, "at_ms", 40_000))
        {:Transition, held, :none} = RunEngine.step(state, record)
        assert held.control.stop_pending == :cancelled
        assert held.slots[{1, 0}].pending_input.order == 1
        assert held.slots[{1, 1}].pending_input.order == 2
        at(c, 40_000)
        RunEngine.input(engine, "end", cancel, verified())
      end)
    end

    test "reports held when the Run deadline stops the Run are never given" do
      ending_drops(:out_of_time, fn c, engine ->
        assert {:ok, :applied} = pause(engine, 70_000)
        at(c, 40_000)
        assert {:ok, _} = RunEngine.input(engine, "w", wake(), verified())
        assert held(c) == [{1, 0}, {1, 1}]
        at(c, 60_000)
        RunEngine.input(engine, "end", wake(), verified())
      end)
    end

    test "an input at the Run deadline settles no slot by expiry, so it holds no report" do
      # BotRunLifecycle takes every input at the Run deadline as Expired, so the expiry
      # pass leaves each slot open (late) and the end of the Run settles it run_closed.
      ending_drops(
        :out_of_time,
        fn c, engine ->
          at(c, 60_000)
          RunEngine.input(engine, "end", wake(), verified())
        end,
        "unknown"
      )
    end
  end

  describe "bound_edges" do
    test "the first excess of a report closes generation and the next report is never given" do
      script = [
        request(for id <- ["t1", "t2", "t3"], do: action(id, "tool_call")),
        request([action("x1", "ask_person")]),
        request([action("x2", "ask_person")]),
        :wait
      ]

      %{c: c, engine: engine} = nested_turn(script, request_cap: 3)
      assert [%{"kind" => "start"}, r1, r2] = inputs_of(pattern_inputs(), "nested")
      assert r1 == expired("t1", {2, 0}, 40_000) and r2 == expired("t2", {2, 1}, 40_000)
      state = unit_state(c)
      assert state.control.count == 4
      assert state.control.receipts[3].input_id == resume_id({2, 0})
      assert state.control.receipts[3].disposition != :over_cap

      assert state.control.receipts[4] |> Map.take([:input_id, :disposition]) ==
               %{input_id: resume_id({2, 1}), disposition: :over_cap}

      assert state.control.generation_closed
      assert slot_by(view(engine), "x1").kind == "ask_person"
      assert slot_by(view(engine), "x2") == nil
      assert view(engine).slots[{1, 0}].phase == :settled
      assert view(engine).slots[{1, 0}].outcome != "completed"
      assert resume_records(c) == [{resume_id({2, 0}), {2, 0}}, {resume_id({2, 1}), {2, 1}}]
      assert held(c) == []
    end

    test "under budget_rule :pause a report's first excess pauses the Run and the next report is never given" do
      # The root owns the three slots, so no parent deny closes the owner: only the
      # close of generation drops the third report, also after continue.
      asks = request(for id <- ["a1", "a2", "a3"], do: action(id, "ask_person"))

      script = [
        asks,
        request([action("x1", "ask_person")]),
        request([action("x2", "ask_person")]),
        :wait
      ]

      {c, bindings} =
        reports_setup(script, %{}, %{"x1" => 50_000, "x2" => 50_000},
          request_cap: 2,
          budget_rule: :pause
        )

      engine = start(c, bindings: bindings, expiry_reports: :owner)
      assert {:ok, :applied} = send_input(engine)
      at(c, 40_000)
      assert {:ok, _} = RunEngine.input(engine, "w", wake(), verified())

      assert [%{"kind" => "start"}, r1, r2] = inputs_of(pattern_inputs(), "root")
      assert r1 == expired("a1", {1, 0}, 40_000) and r2 == expired("a2", {1, 1}, 40_000)
      state = unit_state(c)
      assert state.control.count == 3

      assert Map.take(state.control.receipts[3], [:input_id, :disposition]) ==
               %{input_id: resume_id({1, 1}), disposition: :over_cap}

      # The pause takes the deadline of the expiring wake (verified/1: 50,000).
      assert state.control.generation_closed
      assert state.control.lifecycle.phase == :paused
      assert state.control.lifecycle.pause_deadline == 50_000
      assert held(c) == []

      assert {:ok, :applied} = continue(engine)
      refute_receive {:pattern_input, "root", _}, 300
      assert resume_records(c) == [{resume_id({1, 0}), {1, 0}}, {resume_id({1, 1}), {1, 1}}]
      assert slot_by(view(engine), "x2") == nil
    end

    test "under budget_rule :pause an expiry whose input's pause deadline has passed holds no report" do
      # The local work's outcome carries the pause deadline of its dispatch (50,000);
      # it is lost at 51,000, after its own deadline (45,000), so the expiry pass of
      # that outcome settles the slot. A report with that deadline could not pause.
      script = [request([action("slow")]), request([action("more")]), :wait]

      {c, bindings} =
        reports_setup(script, %{}, %{"slow" => 45_000}, request_cap: 1, budget_rule: :pause)

      engine = start(c, bindings: bindings, expiry_reports: :owner)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:local_started, task}, 5_000
      at(c, 51_000)
      Process.exit(task, :kill)

      v = wait_for(engine, &(&1.slots[{1, 0}][:phase] == :settled))
      assert v.slots[{1, 0}].outcome == "expired"
      assert [%{"kind" => "start"}] = inputs_of(pattern_inputs(), "root")
      assert resume_records(c) == []
      assert held(c) == []

      assert {:ok, _} = RunEngine.input(engine, "w", wake(), verified(%{pause_deadline: 70_000}))
      state = unit_state(c)
      assert state.control.generation_closed
      assert state.control.lifecycle.phase == :paused
      assert state.control.lifecycle.pause_deadline == 70_000
    end

    test "a wake with the count at the cap expires slots and gives no report" do
      %{c: c, engine: engine} = nested_turn(nil, request_cap: 2)
      assert [%{"kind" => "start"}] = inputs_of(pattern_inputs(), "nested")
      assert view(engine).generation_closed
      assert Enum.all?([{2, 0}, {2, 1}, {2, 2}], &(view(engine).slots[&1].outcome == "expired"))
      assert resume_records(c) == []
      assert held(c) == []
    end

    test "a report given at 64 bytes of control headroom fits within its reserve" do
      %{state: before, wake: wake} = ask_state()
      {:Transition, expired, :none} = RunEngine.step(before, wake)
      assert expired.slots[{1, 0}].pending_input.record.id == resume_id({1, 0})
      padded = pad_invocations(expired, 64)

      assert {:Transition, given, :none} =
               RunEngine.step(padded, %{version: 1, kind: :resume_input, occurrence: {1, 0}})

      refute Map.has_key?(given.slots[{1, 0}], :pending_input)
      assert Map.has_key?(given.control.invocations, resume_id({1, 0}))
      assert control_headroom(given) >= 0

      assert [report] = inputs_of(pattern_inputs(), "root")
      assert report == expired("ask", {1, 0}, 40_000)
    end

    test "a slot map within a held report's bytes of its bound settles the slot with no report" do
      %{state: before, wake: wake} = ask_state()
      {:Transition, reported, :none} = RunEngine.step(before, wake)
      pending = reported.slots[{1, 0}].pending_input
      bare = update_in(reported.slots[{1, 0}], &Map.delete(&1, :pending_input))
      report_bytes = bytes(reported.slots) - bytes(bare.slots)
      crafted = fill_slots(before, 8_388_608 - report_bytes + 1 - bytes(bare.slots))

      assert {:Transition, next, :none} = RunEngine.step(crafted, wake)
      assert %{phase: :settled, outcome: "expired"} = next.slots[{1, 0}]
      refute Map.has_key?(next.slots[{1, 0}], :pending_input)
      assert bytes(next.slots) <= 8_388_608
      assert bytes(put_in(next.slots[{1, 0}][:pending_input], pending)) > 8_388_608
    end
  end

  describe "paused_reports_wait" do
    test "reports held while paused are given after continue, before its reply, before a retained input" do
      {c, bindings} =
        reports_setup(
          [
            request([
              action("a1", "ask_person"),
              action("a2", "ask_person"),
              action("t", "tool_call")
            ]),
            :wait,
            :wait,
            :wait,
            :wait
          ],
          %{},
          %{"t" => 50_000}
        )

      engine = start(c, bindings: bindings, expiry_reports: :owner)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, _, _}, 5_000
      wait_for(engine, &(&1.slots[{1, 2}][:phase] == :running))
      assert [%{"kind" => "start"}] = inputs_of(pattern_inputs(), "root")
      assert {:ok, :applied} = pause(engine)
      at(c, 40_000)

      assert {:ok, _} =
               RunEngine.input(
                 engine,
                 "t-result",
                 result("t"),
                 verified(%{occurrence: {1, 2}, actual: 1, dispatch: "dispatched"})
               )

      refute_received {:pattern_input, _, _}

      orders =
        for {key, slot} <- unit_state(c).slots,
            slot[:pending_input],
            do: {slot.pending_input.order, key}

      assert Enum.sort(orders) == [{1, {1, 0}}, {2, {1, 1}}, {3, {1, 2}}]

      assert {:ok, :applied} = continue(engine)
      assert_received {:pattern_input, "root", first}
      assert_received {:pattern_input, "root", second}
      assert_received {:pattern_input, "root", third}
      assert first == expired("a1", {1, 0}, 40_000)
      assert second == expired("a2", {1, 1}, 40_000)
      assert %{"action_id" => "t", "outcome" => "completed", "at_ms" => 40_000} = third
      assert view(engine).phase == :active

      at(c, 41_000)
      assert {:ok, _} = RunEngine.input(engine, "w", wake(), verified())
      assert [%{"kind" => "wake", "at_ms" => 41_000}] = inputs_of(pattern_inputs(), "root")
    end
  end

  describe "replay_is_equal (expiry reports)" do
    test "two restarts after the nested turn give an equal state" do
      %{c: c, engine: engine, bindings: bindings} = nested_turn()
      _ = pattern_inputs()
      replay_is_equal(c, engine, bindings: bindings, expiry_reports: :owner)
    end

    test "two restarts after several expiries in one wake give an equal state" do
      %{c: c, engine: engine, bindings: bindings} = several()
      # The result of "more" settles it first: a restart with its Effect in flight
      # would make it unknown, which is not a report.
      assert_receive {:effect_started, provider, _}, 5_000
      wait_for(engine, &(slot_by(&1, "more")[:phase] == :running))
      send(provider, {:result, %{}})
      key = key_of(view(engine), "more")
      verified = verified(%{occurrence: key, actual: 1, dispatch: "dispatched"})
      assert {:ok, :applied} = RunEngine.input(engine, "result-more", result("more"), verified)
      assert slot_by(view(engine), "more").outcome == "completed"
      _ = pattern_inputs()
      replay_is_equal(c, engine, bindings: bindings, expiry_reports: :owner)
    end
  end

  describe "recovery_gives_the_same_reports" do
    test "a death after the expiring input committed gives the same reports at the next start" do
      # The comparator: the same scenario without the death.
      %{c: c0, engine: engine0} = two_asks()
      assert {:ok, _} = RunEngine.input(engine0, "w", wake(), verified())
      expected_inputs = pattern_inputs()
      expected_records = unit_inputs(c0)
      expected_state = unit_state(c0)
      {"w", committed} = List.keyfind(expected_records, "w", 0)
      GenServer.stop(engine0)
      assert :ok = DynamicUnits.stop(c0.directory, identity(c0))

      %{c: c, engine: engine, bindings: bindings} = two_asks()

      record =
        protocol_record("w", Map.put(wake(), "at_ms", 40_000), context: %{pause_deadline: 50_000})

      assert record == committed
      {:ok, unit} = DynamicUnits.find(c.directory, identity(c))
      assert {:ok, :applied} = DurableUnit.step(unit, "w", record)
      GenServer.stop(engine)
      assert held(c) == [{1, 1}, {2, 0}]
      at(c, 41_000)

      _engine = start(c, bindings: bindings, expiry_reports: :owner)
      assert pattern_inputs() == expected_inputs
      assert unit_inputs(c) == expected_records
      assert unit_state(c) == expected_state

      assert resume_records(c) == [{resume_id({1, 1}), {1, 1}}, {resume_id({2, 0}), {2, 0}}]
    end
  end

  describe "report_id_is_the_resume_id" do
    test "a host input with a given report's ID is a conflict; one with the expire ID is ordinary" do
      {c, bindings} =
        reports_setup([request([action("ask", "ask_person")]), :wait, :wait], %{}, %{})

      engine = start(c, bindings: bindings, expiry_reports: :owner)
      assert {:ok, :applied} = send_input(engine)
      at(c, 40_000)
      assert {:ok, _} = RunEngine.input(engine, "w", wake(), verified())
      assert [_, _] = inputs_of(pattern_inputs(), "root")
      count = length(unit_inputs(c))

      assert {:error, :input_id_conflict} =
               RunEngine.input(engine, resume_id({1, 0}), wake(), verified())

      assert length(unit_inputs(c)) == count
      at(c, 41_000)
      assert {:ok, _} = RunEngine.input(engine, "expire:1:0", wake(), verified())
      assert length(unit_inputs(c)) == count + 1
      assert [%{"kind" => "wake", "at_ms" => 41_000}] = inputs_of(pattern_inputs(), "root")
      assert view(engine).phase == :active
    end
  end

  describe "native_v2_wait_report" do
    test "a wait_event report held while paused and given after continue leaves the readers equal to the fold" do
      {c, bindings} =
        reports_setup([request_v2([action("wait", "wait_event")]), :wait], %{}, %{},
          protocol_version: 2
        )

      engine = start(c, bindings: bindings, protocol_version: 2, expiry_reports: :owner)
      assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
      [wait] = for {k, s} <- unit_state(c).slots, s.kind == "wait_event", do: k
      assert {:ok, :applied} = pause(engine)
      at(c, 40_000)
      wake_v2 = %{"type" => "input", "version" => 2, "kind" => "wake"}
      assert {:ok, _} = RunEngine.input(engine, "w", wake_v2, verified())
      assert held(c) == [wait]
      assert {:ok, :applied} = continue(engine)

      assert [%{"kind" => "start"}, report] = inputs_of(pattern_inputs(), "root")
      assert report == expired("wait", wait, 40_000, 2)
      assert view(engine).phase == :active
      assert resume_records(c) == [{resume_id(wait), wait}]

      assert {:ok, %{waits: [w]}} = RunEngine.event_waits(engine, scope(), limits())
      assert {w.status, w.outcome, w.accepted_event} == {:settled, "expired", nil}
      assert {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())
      assert [%{by: :protocol, reason: nil}] = for(e <- entries, e.type == :settlement, do: e)
    end

    test "an expired positive wait_event is reported to the root with its settlement unchanged" do
      {c, bindings} =
        reports_setup([request_v2([action("wait", "wait_event")]), :wait], %{}, %{},
          protocol_version: 2
        )

      opts = [bindings: bindings, protocol_version: 2, expiry_reports: :owner]
      engine = start(c, opts)
      assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
      [wait] = for {k, s} <- unit_state(c).slots, s.kind == "wait_event", do: k
      assert unit_state(c).slots[wait].reservation != nil
      at(c, 40_000)
      wake_v2 = %{"type" => "input", "version" => 2, "kind" => "wake"}
      assert {:ok, _} = RunEngine.input(engine, "w", wake_v2, verified())

      assert [%{"kind" => "start"}, report] = inputs_of(pattern_inputs(), "root")
      assert report == expired("wait", wait, 40_000, 2)

      state = unit_state(c)
      assert %{phase: :settled, outcome: "expired", actual: 0} = state.slots[wait]

      assert budget(state, "root") |> Map.take([:committed, :reserved]) == %{
               committed: 0,
               reserved: 0
             }

      assert {:ok, %{waits: [w]}} = RunEngine.event_waits(engine, scope(), limits())
      assert {w.status, w.outcome, w.accepted_event} == {:settled, "expired", nil}
      assert {:ok, _} = RunEngine.transcript(engine, scope(), limits())
      assert {:pending, :not_completed} = RunEngine.result(engine, scope(), limits())

      engine = restart(c, engine, opts)
      first = unit_state(c)
      _engine = restart(c, engine, opts)
      assert unit_state(c) == first
      assert first == state
    end
  end

  # The recorded scenario: the root asks a nested callable C (deadline 55,000) and a
  # person (deadline 30,000); C asks three tool calls (deadline 40,000) and waits.
  # A wake at 30,000 expires the root ask; the Run pauses; a wake at 40,000 expires
  # C's three tool slots while paused; continue; one restart; a wake at 55,000
  # expires the parent and is given to the root; a wake at the Run deadline ends the Run.
  defp recorded_scenario(overrides) do
    root = [request([action("nested", "nested_callable"), action("ask", "ask_person")])]

    tools = request(for id <- ["t1", "t2", "t3"], do: action(id, "tool_call"))

    {c, bindings} =
      nested_setup(%{"nested" => [tools]},
        identity: @identity,
        pattern: {TestPattern, :scripted, %{name: "root", script: root}}
      )

    bindings = deadlines(bindings, %{"nested" => 55_000, "ask" => 30_000})
    engine = start(c, [bindings: bindings] ++ overrides)
    assert {:ok, :applied} = send_input(engine)
    for _ <- 1..3, do: assert_receive({:effect_started, _, _}, 5_000)

    wait_for(engine, fn v ->
      Enum.all?([{2, 0}, {2, 1}, {2, 2}], &(v.slots[&1].phase == :running)) and
        v.slots[{1, 1}].phase == :waiting
    end)

    at(c, 30_000)
    assert {:ok, _} = RunEngine.input(engine, "w1", wake(), verified())
    assert view(engine).slots[{1, 1}].outcome == "expired"
    assert {:ok, :applied} = pause(engine)
    at(c, 40_000)
    assert {:ok, _} = RunEngine.input(engine, "w2", wake(), verified())
    assert Enum.all?([{2, 0}, {2, 1}, {2, 2}], &(view(engine).slots[&1].outcome == "expired"))
    assert {:ok, :applied} = continue(engine)
    engine = restart(c, engine, [bindings: bindings] ++ overrides)
    at(c, 55_000)
    assert {:ok, _} = RunEngine.input(engine, "w3", wake(), verified())
    assert view(engine).slots[{1, 0}].outcome == "expired"
    at(c, 60_000)
    assert {:ok, _} = RunEngine.input(engine, "w4", wake(), verified())
    assert wait_for(engine, &(&1.phase == :terminal)).outcome == :out_of_time

    {unit_inputs(c), unit_state(c), pattern_inputs()}
  end

  # Gives the action of each listed ID the listed deadline.
  defp deadlines(bindings, by_id) do
    Map.new(bindings, fn {kind, binding} ->
      {kind,
       %{
         binding
         | facts: fn a ->
             facts = binding.facts.(a)

             case {by_id[a["id"]], facts[:intent]} do
               {nil, _} ->
                 facts

               {deadline, nil} ->
                 %{facts | deadline_ms: deadline}

               {deadline, intent} ->
                 %{facts | deadline_ms: deadline, intent: %{intent | deadline_ms: deadline}}
             end
           end
       }}
    end)
  end

  defp at(c, ms), do: Agent.update(c.clock, fn _ -> ms end)

  defp pause(engine, deadline \\ 50_000),
    do: RunEngine.control(engine, "pause", %{kind: :pause, pause_deadline: deadline}, verified())

  defp continue(engine, id \\ "continue"),
    do:
      RunEngine.control(
        engine,
        id,
        %{kind: :continue, person_id: "person", run_deadline: 60_000},
        verified(%{verified_person: "person"})
      )

  defp identity(c), do: Keyword.fetch!(c.opts, :identity)

  defp restart(c, engine, overrides) do
    GenServer.stop(engine)
    assert :ok = DynamicUnits.stop(c.directory, identity(c))
    Agent.update(c.host_mode, fn _ -> :recover end)
    start(c, overrides)
  end

  defp unit_state(c) do
    {:ok, unit} = DynamicUnits.find(c.directory, identity(c))
    DurableUnit.snapshot(unit)
  end

  # The committed Unit inputs, in commit order: {input ID, record}.
  defp unit_inputs(c) do
    {:ok, rows, _} = Elzoo.DurableLog.read(c.store, identity(c), 1, 1_000)
    for %{kind: "input"} = row <- rows, do: elem(:erlang.binary_to_term(row.payload, [:safe]), 1)
  end

  # Every pattern input sent so far, in order: {callable name, input}.
  defp pattern_inputs(acc \\ []) do
    receive do
      {:pattern_input, name, input} -> pattern_inputs([{name, input} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # The root and each child run TestPattern.waiting, which sends each input it is
  # given to the test process; `children` maps each nested action ID to its script and
  # `by_id` gives listed actions their deadline. Local work blocks until told.
  defp reports_setup(root, children, by_id, overrides \\ []) do
    if Process.whereis(:run_engine_observer) != self(),
      do: Process.register(self(), :run_engine_observer)

    c =
      fixture(
        [identity: @identity, pattern: {TestPattern, :waiting, %{name: "root", script: root}}] ++
          overrides
      )

    reader = %{evidence_store: c.evidence_store, retention_count: 1_024}
    c = %{c | opts: Keyword.put(c.opts, :result_reader, reader)}
    base = c.opts[:bindings]["nested_callable"]
    parent = self()

    nested = %{
      base
      | facts: fn a -> %{base.facts.(a) | estimate: 10} end,
        nested: fn a ->
          %{
            base.nested.(a)
            | mfa: {TestPattern, :waiting},
              initial_state: %{name: a["id"], script: Map.fetch!(children, a["id"])}
          }
        end
    }

    bindings =
      c.opts[:bindings]
      |> Map.put("nested_callable", nested)
      |> Map.update!(
        "local_work",
        &Map.put(&1, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)
      )
      |> deadlines(by_id)

    {c, bindings}
  end

  defp start_link(c, overrides), do: RunEngine.start_link(Keyword.merge(c.opts, overrides))

  # Root asks one nested callable "nested" (deadline 50,000); the child asks three tool
  # calls t1..t3 (deadline 40,000) and runs `script` after; a wake at 40,000 expires
  # the three tool slots.
  defp nested_turn(script \\ nil, overrides \\ []) do
    tools = request(for id <- ["t1", "t2", "t3"], do: action(id, "tool_call"))
    script = script || [tools, :wait, :wait, {:finish_with_seen, "done"}]

    {c, bindings} =
      reports_setup(
        [request([action("nested", "nested_callable")])],
        %{"nested" => script},
        %{"nested" => 50_000, "done" => 50_000, "x1" => 50_000, "x2" => 50_000},
        overrides
      )

    engine = start(c, bindings: bindings, expiry_reports: :owner)
    assert {:ok, :applied} = send_input(engine)
    for _ <- 1..3, do: assert_receive({:effect_started, _, _}, 5_000)

    wait_for(
      engine,
      &Enum.all?([{2, 0}, {2, 1}, {2, 2}], fn k -> &1.slots[k][:phase] == :running end)
    )

    at(c, 40_000)
    assert {:ok, _} = RunEngine.input(engine, "w", wake(), verified())
    %{c: c, engine: engine, bindings: bindings}
  end

  # Root asks children C and D (deadline 50,000) and a person (deadline 40,000); C asks
  # two tool calls and opens "more" on its first report; D asks local work. A wake at
  # 40,000 expires the root ask, C's two tool slots and D's local work.
  defp several do
    {c, bindings} =
      reports_setup(
        [
          request([
            action("C", "nested_callable"),
            action("D", "nested_callable"),
            action("ask", "ask_person")
          ]),
          :wait
        ],
        %{
          "C" => [
            request([action("t1", "tool_call"), action("t2", "tool_call")]),
            request([action("more", "tool_call")]),
            :wait
          ],
          "D" => [request([action("lw", "local_work")]), :wait]
        },
        %{"C" => 50_000, "D" => 50_000, "more" => 50_000}
      )

    engine = start(c, bindings: bindings, expiry_reports: :owner)
    assert {:ok, :applied} = send_input(engine)
    for _ <- 1..2, do: assert_receive({:effect_started, _, _}, 5_000)
    assert_receive {:local_started, _}, 5_000
    ids = ["ask", "t1", "t2", "lw"]

    v =
      wait_for(engine, fn v ->
        Enum.all?(ids, &(slot_by(v, &1)[:phase] in [:running, :waiting]))
      end)

    keys = Map.new(ids, &{&1, key_of(v, &1)})
    at(c, 40_000)
    assert {:ok, _} = RunEngine.input(engine, "w", wake(), verified())
    %{c: c, engine: engine, bindings: bindings, keys: keys}
  end

  # Root asks a nested callable (deadline 50,000) and a person; the child asks a
  # person; both asks have deadline 40,000. The clock is at 40,000.
  defp two_asks do
    {c, bindings} =
      reports_setup(
        [request([action("nested", "nested_callable"), action("a", "ask_person")]), :wait],
        %{"nested" => [request([action("ca", "ask_person")]), :wait]},
        %{"nested" => 50_000}
      )

    engine = start(c, bindings: bindings, expiry_reports: :owner)
    assert {:ok, :applied} = send_input(engine)

    wait_for(
      engine,
      &(&1.slots[{2, 0}][:phase] == :waiting and &1.slots[{1, 1}][:phase] == :waiting)
    )

    at(c, 40_000)
    %{c: c, engine: engine, bindings: bindings}
  end

  # The state of a root with one waiting ask (deadline 40,000), and a wake at it.
  defp ask_state do
    {c, bindings} = reports_setup([request([action("ask", "ask_person")]), :wait], %{}, %{})
    engine = start(c, bindings: bindings, expiry_reports: :owner)
    assert {:ok, :applied} = send_input(engine)
    assert [%{"kind" => "start"}] = inputs_of(pattern_inputs(), "root")
    state = unit_state(c)
    GenServer.stop(engine)
    %{state: state, wake: protocol_record("w", Map.put(wake(), "at_ms", 40_000))}
  end

  # Settled filler slots that make the slot map `extra` bytes larger.
  defp fill_slots(state, extra) do
    filler = fn i, len ->
      {{300 + i, 0},
       %{
         action_id: "filler-#{i}",
         kind: "local_work",
         callable: "root",
         attempt_id: "attempt",
         phase: :settled,
         outcome: "completed",
         pad: :binary.copy("f", len)
       }}
    end

    entry = fn {key, slot} -> bytes(key) - 1 + bytes(slot) - 1 end
    count = div(extra, 120_000) + 1

    sizes =
      for i <- 1..count do
        share = if i < count, do: 120_000, else: extra - 120_000 * (count - 1)
        {i, share}
      end

    {sizes, _} =
      case List.last(sizes) do
        {i, share} when share < 1_000 and count > 1 ->
          {List.replace_at(sizes, 0, {1, 120_000 - 1_000})
           |> List.replace_at(-1, {i, share + 1_000}), nil}

        _ ->
          {sizes, nil}
      end

    slots =
      for {i, share} <- sizes, into: state.slots do
        filler.(i, share - entry.(filler.(i, 0)))
      end

    crafted = %{state | slots: slots}
    ^extra = bytes(crafted.slots) - bytes(state.slots)
    crafted
  end

  defp ending_drops(outcome, ending, settled \\ "expired") do
    {c, bindings} =
      reports_setup(
        [request([action("a1", "ask_person"), action("a2", "ask_person")]), :wait],
        %{},
        %{}
      )

    engine = start(c, bindings: bindings, expiry_reports: :owner)
    assert {:ok, :applied} = send_input(engine)
    count = unit_state(c).control.count
    assert {:ok, _} = ending.(c, engine)
    view = wait_for(engine, &(&1.phase == :terminal))
    assert view.outcome == outcome
    assert view.slots[{1, 0}].outcome == settled and view.slots[{1, 1}].outcome == settled
    assert [%{"kind" => "start"}] = inputs_of(pattern_inputs(), "root")
    assert resume_records(c) == []
    assert held(c) == []
    assert unit_state(c).control.count == count
    assert map_size(unit_state(c).control.receipts) == count

    # A new Run configures on the Unit afterwards, with the option of its own start.
    GenServer.stop(engine)
    {:ok, ended} = Elzoo.RunApprovalRelease.status(c.run, "run")

    assert {:ok, revision, _} =
             Elzoo.RunApprovalRelease.command(c.run, %{
               kind: :create,
               run_id: "period-two",
               operation_id: "operation-two",
               provider_refs: %{},
               expected_revision: ended.revision
             })

    assert {:ok, _, _} =
             Elzoo.RunApprovalRelease.command(c.run, %{
               kind: :begin_attempt,
               run_id: "period-two",
               attempt_id: "third",
               expected_revision: revision
             })

    engine = start(c, bindings: bindings, run_id: "period-two", run_deadline: 120_000)
    assert view(engine).run_id == "period-two"
    assert view(engine).slots == %{}
    refute Map.has_key?(unit_state(c).control, :expiry_reports)
  end

  defp replay_is_equal(c, engine, overrides) do
    before = %{view: Map.delete(view(engine), :classification), state: unit_state(c)}
    records = length(unit_inputs(c))

    _ =
      Enum.reduce(1..2, engine, fn _, engine ->
        engine = restart(c, engine, overrides)
        state = unit_state(c)
        assert Map.delete(view(engine), :classification) == before.view
        assert state.slots == before.state.slots
        assert state.control.budgets == before.state.control.budgets
        assert state.control.callables == before.state.control.callables
        assert state.control.receipts == before.state.control.receipts
        assert state.control.count == before.state.control.count
        assert length(unit_inputs(c)) == records
        engine
      end)

    refute_receive {:pattern_input, _, _}, 300
    refute_receive {:effect_started, _, _}, 100
  end

  # The engine's expiry input for the action `id` of slot `{request, index}`.
  defp expired(id, {request, index}, at, version \\ 1),
    do: %{
      "type" => "input",
      "version" => version,
      "kind" => "action_outcome",
      "action_id" => id,
      "outcome" => "expired",
      "schema_id" => "elzoo.run-engine.refusal",
      "schema_version" => 1,
      "payload" => %{
        "reason" => "expired",
        "gate_id" => "gate",
        "gate_version" => 1,
        "request" => request,
        "index" => index
      },
      "at_ms" => at
    }

  defp resume_id(key, run_id \\ "run"),
    do:
      "resume:" <>
        Base.encode16(
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary({run_id, key}, [:deterministic, {:minor_version, 2}])
          ),
          case: :lower
        )

  defp resume_records(c),
    do: for({id, %{kind: :resume_input} = r} <- unit_inputs(c), do: {id, r.occurrence})

  # The Unit sequence of each report record.
  defp resume_sequences(c) do
    {:ok, rows, _} = Elzoo.DurableLog.read(c.store, identity(c), 1, 1_000)

    for %{kind: "input"} = row <- rows,
        match?({1, {_, %{kind: :resume_input}}}, :erlang.binary_to_term(row.payload, [:safe])),
        do: row.sequence
  end

  defp held(c),
    do: for({key, slot} <- Enum.sort(unit_state(c).slots), slot[:pending_input], do: key)

  defp inputs_of(inputs, name), do: for({^name, input} <- inputs, do: input)

  defp budget(state, id) do
    {:Transition, _, {:some, {:status, status}}} =
      Elzoo.Budget.step(state.control.budgets[id].state, {2_000, :status})

    status
  end

  defp slot_by(view, id),
    do: Enum.find_value(view.slots, fn {_, s} -> if s.action_id == id, do: s end)

  defp key_of(view, id),
    do: Enum.find_value(view.slots, fn {key, s} -> if s.action_id == id, do: key end)

  defp last_index(records, match?) do
    records
    |> Enum.with_index()
    |> Enum.filter(fn {{_, r}, _} -> match?.(r) end)
    |> List.last()
    |> elem(1)
  end

  defp bytes(term),
    do: byte_size(:erlang.term_to_binary(term, [:deterministic, {:minor_version, 2}]))

  defp scope, do: %{tenant: "tenant", principal: "principal", run_id: "run"}
  defp limits, do: %{max_records: 65_536, max_bytes: 536_870_912}
end
