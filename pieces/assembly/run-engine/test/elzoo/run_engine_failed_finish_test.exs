# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineFailedFinishTest.CompleteForwarder do
  # A seam between the engine and its Run owner: every call goes to the owner, except
  # what `mode` decides, once. `:kill` kills the engine at its `:complete` command,
  # before the owner sees it (a crash after the evidence row); `{:rewrite, fun}` sends
  # `fun.(command)` to the owner instead; `{:begin_after_evidence, store, attempt}`
  # begins `attempt` on the owner at the first status read after an evidence row is in
  # `store`, which is the read just before the engine's `:complete` command.
  use GenServer

  def init(arg), do: {:ok, arg}

  def handle_call({:command, %{kind: :complete}}, {caller, _}, {run, :kill}) do
    Process.exit(caller, :kill)
    {:noreply, {run, :spent}}
  end

  def handle_call({:command, %{kind: :complete} = command}, _from, {run, {:rewrite, fun}}),
    do: {:reply, GenServer.call(run, {:command, fun.(command)}, 60_000), {run, :spent}}

  def handle_call(
        {:status, _} = status,
        _from,
        {run, {:begin_after_evidence, store, attempt}} = state
      ) do
    case Elzoo.DurableLog.read(store, "evidence", 1, 1) do
      {:ok, [_], _} ->
        {:ok, view} = GenServer.call(run, status, 60_000)

        begin = %{
          kind: :begin_attempt,
          run_id: view.id,
          attempt_id: attempt,
          expected_revision: view.revision
        }

        {:ok, _, _} = GenServer.call(run, {:command, begin}, 60_000)
        {:reply, GenServer.call(run, status, 60_000), {run, :spent}}

      _ ->
        {:reply, GenServer.call(run, status, 60_000), state}
    end
  end

  def handle_call(message, _from, {run, _} = state),
    do: {:reply, GenServer.call(run, message, 60_000), state}
end

defmodule Elzoo.RunEngineFailedFinishTest do
  # ELZ-420: a root finish that names no action (`"action_id": null`, no `action_id`
  # key, or a payload that is not an object) ends its Run `:failed`, and result/3 reads
  # the finish payload back from the journaled failure.
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper, except: [result: 1, result: 2]
  alias Elzoo.{DurableLog, DurableUnit, DynamicUnits, PayloadSchema, RunEngine}
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.RunEngine.TestPattern
  alias Elzoo.RunEngineFailedFinishTest.CompleteForwarder

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

  # Finish schemas that admit each form: `action_id` null, no `action_id` key (the
  # schema forbids one), a text payload and a number payload.
  @schemas %{
    "stopped-null" => %{
      "type" => "object",
      "required" => ["status", "action_id"],
      "properties" => %{"status" => %{"const" => "stopped"}, "action_id" => %{"type" => "null"}},
      "additionalProperties" => false
    },
    "stopped-absent" => %{
      "type" => "object",
      "required" => ["status"],
      "properties" => %{"status" => %{"const" => "stopped"}, "reason" => %{"type" => "string"}},
      "additionalProperties" => false
    },
    "stopped-text" => %{"type" => "string"},
    "stopped-number" => %{"type" => "number"}
  }

  @null %{"status" => "stopped", "action_id" => nil}

  describe "null_source_fails_the_run" do
    test "a root finish with action_id null ends the Run failed and result/3 gives its payload" do
      parent = self()
      finish = finish_action("finish", @null, "stopped-null")
      # A completed action exists: a finish that names no action must not take it.
      c = with_schemas(fixture(pattern: pattern([request([action("work")]), request([finish])])))
      # Each clock read is 1 ms later, so each record has a time of its own.
      clock = fn -> Agent.get_and_update(c.clock, &{&1, &1 + 1}) end

      gate = %{
        c.opts[:gate]
        | call: fn _, _ ->
            send(parent, :gate_called)
            :allow
          end
      }

      engine = start(c, clock: clock, gate: gate, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &(&1.outcome == :failed))

      failed = assert_failed(c, engine, finish)
      refute Map.has_key?(view(engine), :payload)

      # The terminal entry follows the settlement, from the later terminal view.
      types = Enum.map(failed.entries, & &1.type)

      settled_at =
        Enum.find_index(failed.entries, &(&1.type == :settlement and &1.occurrence == failed.key))

      assert Enum.find_index(types, &(&1 == :terminal)) > settled_at
      assert [%{at_ms: terminal_at}] = Enum.filter(failed.entries, &(&1.type == :terminal))
      assert terminal_at > failed.at

      # Its Budget entry settled at 0: only the work's actual is committed.
      assert [%{actual: work_actual}] =
               Enum.filter(failed.entries, &(&1.type == :settlement and &1.action_id == "work"))

      assert budget(c) == %{committed: work_actual, reserved: 0}

      # The reads call no gate, clock, pattern or schema check and change nothing.
      wait_for(engine, fn _ ->
        match?({:ok, []}, Elzoo.Outbox.pending(c.store, c.prefix, 64)) and
          match?({:ok, []}, Elzoo.Outbox.pending(c.evidence_store, "evidence", 64))
      end)

      flush(:gate_called)
      before = {rows(c), unit_state(c), evidence_rows(c), Agent.get(c.clock, & &1)}

      without_calls(engine, fn ->
        assert {:failed, failed.expected} == RunEngine.result(engine, scope(), limits())
        assert {:failed, failed.expected} == RunEngine.result(engine, scope(), limits())
      end)

      refute_received :gate_called
      assert {rows(c), unit_state(c), evidence_rows(c), Agent.get(c.clock, & &1)} == before
    end

    test "a root finish with no action_id key ends the Run failed" do
      payload = %{"status" => "stopped", "reason" => "turn_limit"}
      finish = finish_action("finish", payload, "stopped-absent")
      c = with_schemas(fixture(pattern: pattern([request([finish])])))
      engine = start(c, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &(&1.outcome == :failed))
      assert_failed(c, engine, finish)
      assert budget(c) == %{committed: 0, reserved: 0}
    end

    test "a root finish whose payload is not an object ends the Run failed, also after a restart" do
      finish = finish_action("finish", "the model stopped", "stopped-text")
      c = with_schemas(fixture(pattern: pattern([request([finish])])))
      engine = start(c, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &(&1.outcome == :failed))
      failed = assert_failed(c, engine, finish)
      assert failed.expected.payload == "the model stopped"

      engine = restart(c, engine, result_reader: reader(c))
      assert %{phase: :terminal, outcome: :failed} = view(engine)
      assert {:failed, failed.expected} == RunEngine.result(engine, scope(), limits())
    end

    test "a nested finish whose payload is not an object still reaches its parent, and the Run does not fail" do
      {c, bindings} = nested_setup(%{"nested" => [request([finish_action("child-done", "plain")])]})
      engine = start(c, bindings: bindings, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)

      assert_receive {:pattern_input, "root", %{"action_id" => "nested", "payload" => "plain"}},
                     2_000

      view = view(engine)
      assert %{phase: :settled, outcome: "completed"} = view.slots[{1, 0}]
      assert view.outcome == nil and view.phase != :terminal
      assert {:ok, %{outcome: nil}} = Run.status(c.run, "run")
      assert evidence_rows(c) == []

      {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())
      assert [%{payload: "plain"}] = Enum.filter(entries, &(&1.type == :nested_finish))
    end
  end

  describe "named_source_is_unchanged" do
    test "after gate and admission a root finish naming a wrong action ID is refused completion_evidence" do
      finish = finish_action("finish", %{"action_id" => "missing"})
      c = fixture(pattern: pattern([request([action("work")]), request([finish])]))
      engine = start(c, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &match?({_, %{phase: :settled}}, slot_of(&1, "finish")))
      assert_refused_and_open(c, engine, "finish")
    end

    test "a root finish naming an existing source that is not completed is refused completion_evidence" do
      # A settled source that is not completed: the gate denies it.
      gate = %{
        id: "gate",
        version: 1,
        call: fn {_, %{"actions" => [%{"id" => id}]}}, _ ->
          if id == "denied", do: {:deny, "policy"}, else: :allow
        end
      }

      finish = finish_action("finish", %{"action_id" => "denied"})
      c = fixture(pattern: pattern([request([action("denied")]), request([finish])]))
      engine = start(c, gate: gate, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &match?({_, %{phase: :settled}}, slot_of(&1, "finish")))
      assert {_, %{phase: :settled, outcome: "refused"}} = slot_of(view(engine), "denied")
      assert_refused_and_open(c, engine, "finish")

      # A source that is still open: the ask waits while its finish is dispatched.
      ask = finish_action("finish", %{"action_id" => "ask"})
      c = fixture(pattern: pattern([request([action("ask", "ask_person"), ask])]))
      engine = start(c, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &match?({_, %{phase: :settled}}, slot_of(&1, "finish")))
      assert {_, %{phase: :waiting}} = slot_of(view(engine), "ask")
      assert_refused_and_open(c, engine, "finish")
    end
  end

  describe "failed_run_owner_commands" do
    test "on the failed Run a different complete is a terminal conflict and an exact duplicate is unchanged" do
      {c, engine} = failed_run(finish_action("finish", @null, "stopped-null"))
      {:ok, owner} = Run.status(c.run, "run")
      {:failed, record} = RunEngine.result(engine, scope(), limits())

      base = %{
        kind: :complete,
        run_id: "run",
        attempt_id: "attempt",
        expected_revision: owner.revision
      }

      for different <- [
            %{outcome: :completed, reason: "engine", evidence_ref: owner.evidence_ref},
            %{outcome: :failed, reason: "engine", evidence_ref: owner.evidence_ref},
            %{outcome: :failed, reason: "pattern", evidence_ref: nil},
            %{outcome: :cancelled, reason: "pattern", evidence_ref: owner.evidence_ref}
          ] do
        assert {:refused, :terminal_conflict} = Run.command(c.run, Map.merge(base, different))
      end

      exact = %{outcome: :failed, reason: "pattern", evidence_ref: owner.evidence_ref}
      assert {:unchanged, :duplicate, revision} = Run.command(c.run, Map.merge(base, exact))
      assert revision == owner.revision
      assert Run.status(c.run, "run") == {:ok, owner}
      assert {:failed, record} == RunEngine.result(engine, scope(), limits())
    end
  end

  describe "plain_owner_failure" do
    test "an owner failure with reason pattern and an evidence row, and no root failure in the history, is terminal failed" do
      c = fixture()
      engine = start(c, result_reader: reader(c))

      event = %{
        run_id: "run",
        attempt_id: "attempt",
        operation_id: "operation",
        action_id: "finish"
      }

      {:committed, sequence} =
        DurableLog.Writer.append(c.evidence, [{"completion", 1, binary(event)}])

      {:ok, owner} = Run.status(c.run, "run")

      assert {:ok, _, _} =
               Run.command(c.run, %{
                 kind: :complete,
                 run_id: "run",
                 attempt_id: "attempt",
                 outcome: :failed,
                 reason: "pattern",
                 evidence_ref: %{stream: "evidence", sequence: sequence},
                 expected_revision: owner.revision
               })

      assert {:terminal, :failed} = RunEngine.result(engine, scope(), limits())

      # Once the engine has taken the terminal view, its history is terminal failed with
      # no root failure in it: still a plain owner failure.
      assert {:ok, :applied} = RunEngine.input(engine, "after-end", wake(), verified())
      assert %{phase: :terminal, outcome: :failed} = view(engine)
      assert {:terminal, :failed} = RunEngine.result(engine, scope(), limits())
    end

    test "an owner failure in an Attempt that the host began on the owner alone reads history until the engine takes it" do
      c = fixture()
      engine = start(c, result_reader: reader(c))
      {:ok, owner} = Run.status(c.run, "run")

      assert {:ok, revision, _} =
               Run.command(c.run, %{
                 kind: :begin_attempt,
                 run_id: "run",
                 attempt_id: "second",
                 expected_revision: owner.revision
               })

      assert {:ok, _, _} =
               Run.command(c.run, %{
                 kind: :complete,
                 run_id: "run",
                 attempt_id: "second",
                 outcome: :failed,
                 reason: "engine",
                 evidence_ref: nil,
                 expected_revision: revision
               })

      # The Unit is still at the first Attempt: absence cannot be shown for this owner.
      assert {:error, :history} = RunEngine.result(engine, scope(), limits())

      assert {:ok, :applied} =
               RunEngine.input(engine, "after-end", wake(), verified(%{attempt_id: "second"}))

      assert %{phase: :terminal, outcome: :failed, attempt_id: "second"} = view(engine)
      assert {:terminal, :failed} = RunEngine.result(engine, scope(), limits())
    end
  end

  describe "failed_result_fails_closed" do
    test "a damaged or mismatched evidence row of a journaled failure fails closed" do
      memory = memory_evidence_store()

      {c, engine} =
        failed_run(finish_action("finish", @null, "stopped-null"), [],
          result_reader: %{evidence_store: memory, retention_count: 1_024}
        )

      {:ok, owner} = Run.status(c.run, "run")

      {:ok, [row], _} =
        DurableLog.read(c.evidence_store, "evidence", owner.evidence_ref.sequence, 1)

      assert {:committed, 1} = DurableLog.Memory.append(memory, "evidence", 0, [row], [])
      assert {:failed, _} = RunEngine.result(engine, scope(), limits())
      key = {"evidence", row.sequence}
      event = :erlang.binary_to_term(row.payload, [:safe])

      for changed <- [
            %{event | run_id: "other-run"},
            %{event | attempt_id: "other-attempt"},
            %{event | operation_id: "other-operation"},
            %{event | action_id: "other-action"},
            Map.put(event, :extra, "x")
          ] do
        valid = %{row | payload: binary(changed)}
        valid = %{valid | digest: DurableLog.digest(valid)}

        assert :ok =
                 DurableLog.Memory.corrupt(
                   memory,
                   :records,
                   key,
                   Map.take(valid, [:payload, :digest])
                 )

        assert {:error, :completion_mismatch} = RunEngine.result(engine, scope(), limits())
      end

      restore = Map.take(row, [:payload, :digest])
      assert :ok = DurableLog.Memory.corrupt(memory, :records, key, %{restore | digest: <<0::256>>})
      assert {:error, :history} = RunEngine.result(engine, scope(), limits())

      # The row in another stream with its digest made valid: only the stream check sees it.
      moved = %{row | stream: "other"}
      moved = %{moved | digest: DurableLog.digest(moved)}

      changes = %{stream: "other", payload: row.payload, digest: moved.digest}
      assert :ok = DurableLog.Memory.corrupt(memory, :records, key, changes)

      assert {:error, :history} = RunEngine.result(engine, scope(), limits())

      assert :ok =
               DurableLog.Memory.corrupt(
                 memory,
                 :records,
                 key,
                 Map.put(restore, :stream, "evidence")
               )

      assert {:failed, _} = RunEngine.result(engine, scope(), limits())
    end

    test "an owner whose evidence is another stream's row, another action's row or none fails closed" do
      event = %{
        run_id: "run",
        attempt_id: "attempt",
        operation_id: "operation",
        action_id: "finish"
      }

      # A valid row with the same four fields in another stream of the same Store.
      other_stream = fn c ->
        {:ok, writer} =
          DurableLog.Writer.start_link(
            store: c.evidence_store,
            stream: "other-evidence",
            fold: evidence_fold(),
            limits: evidence_limits()
          )

        {:committed, sequence} =
          DurableLog.Writer.append(writer, [{"completion", 1, binary(event)}])

        GenServer.stop(writer)
        %{stream: "other-evidence", sequence: sequence}
      end

      # A valid row of this Run, Attempt and operation that names another action.
      other_action = fn c ->
        row = binary(%{event | action_id: "other-action"})
        {:committed, sequence} = DurableLog.Writer.append(c.evidence, [{"completion", 1, row}])
        %{stream: "evidence", sequence: sequence}
      end

      for named <- [other_stream, other_action, fn _ -> nil end] do
        c =
          with_schemas(
            fixture(pattern: pattern([request([finish_action("finish", @null, "stopped-null")])]))
          )

        ref = named.(c)
        owner = forwarder(c, {:rewrite, &%{&1 | evidence_ref: ref}})
        engine = start(c, run_owner: owner, result_reader: reader(c))
        assert {:ok, :applied} = send_input(engine)
        wait_for(engine, &(&1.outcome == :failed))

        assert {:ok, %{outcome: :failed, reason: "pattern", evidence_ref: ^ref}} =
                 Run.status(c.run, "run")

        assert {:error, :completion_mismatch} = RunEngine.result(engine, scope(), limits())
      end
    end

    test "damage, a read limit or an unavailable Store never gives a plain failure" do
      # An owner failure with no root failure in the history.
      c = fixture(unit_store: memory_unit_store())
      engine = start(c, result_reader: reader(c))
      {:ok, owner} = Run.status(c.run, "run")

      assert {:ok, _, _} =
               Run.command(c.run, %{
                 kind: :complete,
                 run_id: "run",
                 attempt_id: "attempt",
                 outcome: :failed,
                 reason: "engine",
                 evidence_ref: nil,
                 expected_revision: owner.revision
               })

      assert_damage_fails_closed(c, engine, [], {:terminal, :failed})

      # A journaled failure.
      {c, engine} =
        failed_run(finish_action("finish", @null, "stopped-null"), unit_store: memory_unit_store())

      {:ok, owner} = Run.status(c.run, "run")

      {:ok, evidence, _} =
        DurableLog.read(c.evidence_store, "evidence", owner.evidence_ref.sequence, 1)

      {:failed, _} = failed = RunEngine.result(engine, scope(), limits())
      assert_damage_fails_closed(c, engine, evidence, failed)
    end

    test "a failure record changed to name a completed action is damaged history, in v1 and v2" do
      for version <- [1, 2] do
        v2? = version == 2
        frame = if v2?, do: &request_v2/1, else: &request/1
        finish = finish_action("finish", @null, "stopped-null")
        requests = [frame.([action("work")]), frame.([finish])]
        version_opts = if v2?, do: [protocol_version: 2], else: []

        c =
          fixture(
            [unit_store: memory_unit_store(version), pattern: pattern(requests)] ++ version_opts
          )
          |> with_schemas()

        engine = start(c, result_reader: reader(c))
        input = if v2?, do: start_input_v2(), else: start_input()
        assert {:ok, :applied} = RunEngine.input(engine, "start", input, verified())
        wait_for(engine, &(&1.outcome == :failed))
        assert {:failed, _} = result(engine)

        # The :finish record with no source now names the completed `work`, its row
        # digest made valid; the recorded step into the failure is left as it was.
        {work, _} = slot_of(view(engine), "work")
        {row, id, record} = failure_input_row(c)
        corrupt_row(c, row, {1, {id, %{record | source: work}}})
        assert {:error, :history} = result(engine)
      end
    end

    test "a request frame whose finish payload is 1.0 where the admitted finish has 1 is damaged history" do
      finish = finish_action("finish", 1, "stopped-number")

      c =
        fixture(unit_store: memory_unit_store(1), pattern: pattern([request([finish])]))
        |> with_schemas()

      engine = start(c, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &(&1.outcome == :failed))
      assert {:failed, %{payload: 1}} = result(engine)

      # The state before the failure record holds the request frame of the finish: its
      # payload 1 becomes 1.0 there, the row digest made valid. The admitted finish and
      # the fold keep 1.
      {failure_row, _, %{occurrence: {ordinal, _}}} = failure_input_row(c)
      [before_row] = Enum.filter(rows(c), &(&1.sequence == failure_row.sequence - 1))
      assert before_row.kind == "result"
      {1, {id, state}} = decode(before_row)
      frame = state.requests[ordinal]
      changed = String.replace(frame, ~s("payload":1,), ~s("payload":1.0,))
      assert changed != frame
      corrupt_row(c, before_row, {1, {id, put_in(state.requests[ordinal], changed)}})
      assert {:error, :history} = result(engine)
    end
  end

  describe "crash_before_the_owner_command" do
    test "a restart after the failure and its evidence row commits one terminal owner row and reads the row it names" do
      finish = finish_action("finish", @null, "stopped-null")
      c = with_schemas(fixture(pattern: pattern([request([finish])])))
      engine = start(c, run_owner: forwarder(c, :kill), result_reader: reader(c))
      monitor = Process.monitor(engine)
      catch_exit(send_input(engine))
      assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000

      # The failure and its evidence row are committed; the owner has seen no command.
      assert {:ok, %{outcome: nil}} = Run.status(c.run, "run")
      control = unit_state(c).control
      assert %{stop_pending: :failed, generation_closed: true, completion: key} = control
      assert [orphan] = evidence_rows(c)
      assert terminal_rows(c) == []

      engine = start(c, result_reader: reader(c))
      assert %{phase: :terminal, outcome: :failed} = wait_for(engine, &(&1.outcome == :failed))
      {:ok, owner} = Run.status(c.run, "run")

      # The retry appended an equal row; the owner names that one, in its one terminal row.
      assert [^orphan, named] = evidence_rows(c)
      assert decode(named) == decode(orphan)
      ref = %{stream: "evidence", sequence: named.sequence}
      assert owner.evidence_ref == ref and named.sequence == orphan.sequence + 1
      assert [{:terminal, "run", :failed, "pattern", ^ref, _}] = terminal_rows(c)
      assert [_] = failure_records(c)
      assert {:failed, %{evidence_ref: ^ref, action_id: "finish", payload: @null}} = result(engine)

      # The result is read from the row the owner names: an altered orphan changes
      # nothing, an altered named row is a mismatch. Restarts change no record.
      before = {rows(c), evidence_rows(c), terminal_rows(c), Run.status(c.run, "run")}
      engine = restart(c, engine, result_reader: copy_reader([altered(orphan), named]))
      assert {:failed, %{evidence_ref: ^ref}} = result(engine)
      engine = restart(c, engine, result_reader: copy_reader([orphan, altered(named)]))
      assert {:error, :completion_mismatch} = result(engine)
      engine = restart(c, engine, result_reader: reader(c))
      assert {:failed, %{evidence_ref: ^ref}} = result(engine)
      assert {rows(c), evidence_rows(c), terminal_rows(c), Run.status(c.run, "run")} == before
      assert unit_state(c).control.completion == key
    end

    test "a new Attempt begun on the owner between the evidence row and the restart is not failed" do
      finish = finish_action("finish", @null, "stopped-null")
      c = with_schemas(fixture(pattern: pattern([request([finish]), request([action("work")])])))
      engine = start(c, run_owner: forwarder(c, :kill), result_reader: reader(c))
      monitor = Process.monitor(engine)
      catch_exit(send_input(engine))
      assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
      assert %{stop_pending: :failed} = unit_state(c).control
      assert [orphan] = evidence_rows(c)
      assert decode(orphan).attempt_id == "attempt"
      begin_attempt(c, "second")

      # The restart takes the new Attempt: the failure of the older one is dropped, with
      # no owner command and no new evidence row, and the new Attempt generates.
      engine = start(c, result_reader: reader(c))
      assert_second_attempt_open(c, engine, [orphan])
      assert [_] = failure_records(c)

      # A later plain failure of the new Attempt reads as one: the older failure is not read.
      {:ok, owner} = Run.status(c.run, "run")

      assert {:ok, _, _} =
               Run.command(c.run, %{
                 kind: :complete,
                 run_id: "run",
                 attempt_id: "second",
                 outcome: :failed,
                 reason: "engine",
                 evidence_ref: nil,
                 expected_revision: owner.revision
               })

      assert {:terminal, :failed} = result(engine)
    end

    test "a new Attempt begun on the owner between the evidence row and the owner command answers it stale" do
      finish = finish_action("finish", @null, "stopped-null")
      c = with_schemas(fixture(pattern: pattern([request([finish]), request([action("work")])])))
      owner = forwarder(c, {:begin_after_evidence, c.evidence_store, "second"})
      engine = start(c, run_owner: owner, result_reader: reader(c))

      # The command carries the Attempt of the finish, so the owner answers it stale; the
      # engine takes the new Run view, which drops the failure, before the input replies.
      assert {:ok, :applied} = send_input(engine)
      assert [row] = evidence_rows(c)
      assert decode(row).attempt_id == "attempt"
      assert_second_attempt_open(c, engine, [row])
    end
  end

  describe "native_v2_failed_finish" do
    test "a v2 Run failed by a root finish recovers, passes the v2 replay validation and its transcript reads" do
      finish = finish_action("finish", @null, "stopped-null")
      c = with_schemas(fixture(protocol_version: 2, pattern: pattern([request_v2([finish])])))
      engine = start(c)
      assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
      wait_for(engine, &(&1.outcome == :failed))
      failed = assert_failed(c, engine, finish)
      assert {:ok, %{waits: []}} = RunEngine.event_waits(engine, scope(), limits())

      before = rows(c)
      engine = restart(c, engine, [])
      assert %{phase: :terminal, outcome: :failed} = view(engine)
      assert {:failed, failed.expected} == result(engine)
      assert {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())
      assert entries == failed.entries
      assert {:ok, %{waits: []}} = RunEngine.event_waits(engine, scope(), limits())
      assert rows(c) == before
    end
  end

  # The common checks of a Run that a root finish failed: status, owner, evidence row,
  # result, journal and transcript.
  defp assert_failed(c, engine, finish) do
    view = view(engine)
    assert %{phase: :terminal, outcome: :failed, stop_pending: nil} = view

    assert {key, %{kind: "finish", phase: :settled, outcome: "completed"}} =
             slot_of(view, finish["id"])

    {:ok, owner} = Run.status(c.run, "run")
    assert %{outcome: :failed, reason: "pattern", evidence_ref: %{stream: "evidence"} = ref} = owner
    assert [row] = Enum.filter(evidence_rows(c), &(&1.sequence == ref.sequence))
    assert {row.kind, row.schema_version} == {"completion", 1}

    assert decode(row) == %{
             run_id: "run",
             attempt_id: "attempt",
             operation_id: "operation",
             action_id: finish["id"]
           }

    expected = %{
      run_id: "run",
      attempt_id: "attempt",
      operation_id: "operation",
      action_id: finish["id"],
      schema_id: finish["schema_id"],
      schema_version: 1,
      payload: finish["payload"],
      evidence_ref: ref
    }

    assert {:failed, expected} == result(engine)

    # One failure record (a :finish record with no source), and no refusal.
    assert [%{occurrence: ^key, at_ms: at}] = failure_records(c)

    refute Enum.any?(
             records(c),
             &match?(%{kind: :continuation, facts: %{refusal: "completion_evidence"}}, &1)
           )

    # The finish settles by that record, at its time, with actual 0; then the Run ends.
    {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())

    assert [%{outcome: "completed", by: :finish, reason: nil, actual: 0, at_ms: ^at, path: []}] =
             Enum.filter(entries, &(&1.type == :settlement and &1.occurrence == key))

    assert [%{outcome: :failed}] = Enum.filter(entries, &(&1.type == :terminal))
    %{key: key, at: at, expected: expected, entries: entries}
  end

  defp assert_refused_and_open(c, engine, action_id) do
    view = view(engine)
    assert view.outcome == nil and view.phase != :terminal and view.stop_pending == nil
    assert {key, %{phase: :settled, outcome: "refused"}} = slot_of(view, action_id)
    {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())
    of = fn type -> Enum.filter(entries, &(&1.type == type and &1[:occurrence] == key)) end

    # The gate allowed it, it was admitted and authorized, and then refused.
    assert [%{verdict: :allow}] = of.(:gate)
    assert [%{kind: "finish"}] = of.(:action)
    assert [%{verdict: :allow}] = of.(:authorization)

    assert [%{outcome: "refused", by: :protocol, reason: "completion_evidence", actual: 0}] =
             of.(:settlement)

    refute Enum.any?(entries, &(&1.type == :terminal))
    assert failure_records(c) == []
    assert {:ok, %{outcome: nil}} = Run.status(c.run, "run")
    assert evidence_rows(c) == []
    assert {:pending, :not_completed} = result(engine)

    # A later input leaves the Run open.
    assert {:ok, :applied} = RunEngine.input(engine, "later", wake(), verified())
    assert %{outcome: nil} = view = view(engine)
    assert view.phase != :terminal
  end

  # Exact limits read; one record or one byte less is read_limit; a damaged, pruned or
  # unpaired history is history; an unavailable Store is unavailable. `answer` is the
  # reply of the intact history.
  defp assert_damage_fails_closed(c, engine, evidence, answer) do
    retained = rows(c) ++ evidence
    bytes = Enum.sum(Enum.map(retained, &:erlang.iolist_size(DurableLog.canonical_bytes(&1))))
    exact = %{max_records: length(retained), max_bytes: bytes}
    assert answer == RunEngine.result(engine, scope(), exact)

    assert {:error, :read_limit} =
             RunEngine.result(engine, scope(), %{exact | max_records: length(retained) - 1})

    assert {:error, :read_limit} =
             RunEngine.result(engine, scope(), %{exact | max_bytes: bytes - 1})

    memory = DurableLog.Memory
    row = hd(rows(c))
    key = {c.prefix, row.sequence}
    assert :ok = memory.corrupt(c.store, :records, key, %{digest: <<0::256>>})
    assert {:error, :history} = result(engine)
    assert :ok = memory.corrupt(c.store, :records, key, %{digest: row.digest})
    assert answer == result(engine)

    low_water = memory.inspect_state(c.store).heads[c.prefix].low_water
    assert :ok = memory.corrupt(c.store, :heads, c.prefix, %{low_water: 1})
    assert {:error, :history} = result(engine)
    assert :ok = memory.corrupt(c.store, :heads, c.prefix, %{low_water: low_water})

    assert :ok = memory.fault(c.store, :read, :unavailable)
    assert {:error, :unavailable} = result(engine)
    assert answer == result(engine)

    {:ok, writer} =
      DurableLog.Writer.start_link(
        store: c.store,
        stream: c.prefix,
        fold: DurableUnit.fold(c.unit_opts),
        limits: DurableUnit.limits(c.unit_opts)
      )

    tail = binary({1, {"unpaired-tail", %{version: 1, kind: :unknown_history}}})
    assert {:committed, _} = DurableLog.Writer.append(writer, [{"input", 1, tail}])
    GenServer.stop(writer)
    assert {:error, :history} = result(engine)
  end

  # The root runs `work` (or nothing) and then the given finish; the Run ends :failed.
  defp failed_run(finish, fixture_opts \\ [], start_opts \\ []) do
    c =
      fixture(
        Keyword.put(fixture_opts, :pattern, pattern([request([action("work")]), request([finish])]))
      )
      |> with_schemas()

    engine = start(c, Keyword.merge([result_reader: reader(c)], start_opts))
    assert {:ok, :applied} = send_input(engine)
    wait_for(engine, &(&1.outcome == :failed))
    {c, engine}
  end

  defp pattern(requests), do: {TestPattern, :step, %{requests: requests}}

  # The finish schemas join the fixture's own, for every start of the Run.
  defp with_schemas(c) do
    schemas =
      Map.new(@schemas, fn {id, schema} ->
        port = %{"id" => id, "direction" => "input", "schema_id" => id, "schema_version" => 1}
        {:ok, compiled} = PayloadSchema.build(port, schema)
        digest = :crypto.hash(:sha256, Jason.encode!(schema))
        {{id, 1}, %{port: port, compiled: compiled, digest: digest}}
      end)

    %{c | opts: Keyword.update!(c.opts, :schemas, &Map.merge(&1, schemas))}
  end

  defp forwarder(c, mode),
    do:
      start_supervised!(%{
        id: make_ref(),
        start: {GenServer, :start_link, [CompleteForwarder, {c.run, mode}]}
      })

  defp restart(c, engine, overrides) do
    GenServer.stop(engine)
    assert :ok = DynamicUnits.stop(c.directory, c.prefix)
    start(c, overrides)
  end

  # The host begins `attempt` on the Run owner alone, with no engine command.
  defp begin_attempt(c, attempt) do
    {:ok, owner} = Run.status(c.run, "run")

    assert {:ok, _, _} =
             Run.command(c.run, %{
               kind: :begin_attempt,
               run_id: "run",
               attempt_id: attempt,
               expected_revision: owner.revision
             })
  end

  # The Run of the test pattern is open in Attempt "second" with no failure pending,
  # the owner has no terminal record and the evidence rows are `evidence`; then a wake
  # of the new Attempt reaches the root, whose next request (`work`) completes.
  defp assert_second_attempt_open(c, engine, evidence) do
    assert {:ok, %{outcome: nil, current_attempt: "second"}} = Run.status(c.run, "run")
    assert terminal_rows(c) == []
    assert evidence_rows(c) == evidence
    view = view(engine)

    assert %{attempt_id: "second", outcome: nil, stop_pending: nil, generation_closed: false} =
             view

    assert view.phase != :terminal and view.reconciliation == nil
    assert %{stop_pending: nil, completion: nil} = unit_state(c).control
    assert {:pending, :not_completed} = result(engine)
    reply = RunEngine.input(engine, "second-wake", wake(), verified(%{attempt_id: "second"}))
    assert {:ok, :applied} = reply
    wait_for(engine, &match?({_, %{phase: :settled, outcome: "completed"}}, slot_of(&1, "work")))
    assert {:ok, %{outcome: nil}} = Run.status(c.run, "run")
  end

  defp unit_state(c) do
    {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
    DurableUnit.snapshot(unit)
  end

  defp budget(c) do
    root = unit_state(c).control.budgets["root"]
    at = Agent.get(c.clock, & &1)
    {:Transition, _, {:some, {:status, status}}} = Elzoo.Budget.step(root.state, {at, :status})
    Map.take(status, [:committed, :reserved])
  end

  # The engine records of the Unit journal, in commit order.
  defp records(c) do
    for %{kind: "input", payload: payload} <- rows(c),
        {1, {_id, record}} <- [:erlang.binary_to_term(payload, [:safe])],
        do: record
  end

  defp failure_records(c), do: Enum.filter(records(c), &match?(%{kind: :finish, source: nil}, &1))

  defp evidence_rows(c) do
    {:ok, rows, _head} = DurableLog.read(c.evidence_store, "evidence", 1, 1_000)
    rows
  end

  # The owner's terminal records of this Run.
  defp terminal_rows(c) do
    {:ok, rows, _head} = DurableLog.read(c.run_store, "runs", 1, 1_000)

    for %{kind: "run", payload: payload} <- rows,
        {:terminal, "run", _, _, _, _} = event <- [:erlang.binary_to_term(payload, [:safe])],
        do: event
  end

  defp decode(row), do: :erlang.binary_to_term(row.payload, [:safe])

  # The Unit row that holds the :finish record with no source, its input ID and record.
  defp failure_input_row(c) do
    [found] =
      for %{kind: "input", payload: payload} = row <- rows(c),
          {1, {id, %{kind: :finish, source: nil} = record}} <- [
            :erlang.binary_to_term(payload, [:safe])
          ],
          do: {row, id, record}

    found
  end

  # A Unit row of the in-memory Store with `term` as its payload, its digest made valid.
  defp corrupt_row(c, row, term) do
    changed = %{row | payload: binary(term)}
    changed = %{changed | digest: DurableLog.digest(changed)}
    changes = Map.take(changed, [:payload, :digest])
    assert :ok = DurableLog.Memory.corrupt(c.store, :records, {row.stream, row.sequence}, changes)
  end

  # The row with another action ID, its digest made valid again.
  defp altered(row) do
    altered = %{row | payload: binary(%{decode(row) | action_id: "other-action"})}
    %{altered | digest: DurableLog.digest(altered)}
  end

  # A reader whose evidence Store holds exactly these rows.
  defp copy_reader(rows) do
    memory = memory_evidence_store()

    for row <- rows,
        do:
          assert(
            {:committed, _} =
              DurableLog.Memory.append(memory, "evidence", row.sequence - 1, [row], [])
          )

    %{evidence_store: memory, retention_count: 1_024}
  end

  defp memory_unit_store(version \\ 1) do
    options = [
      operator: {RunEngine, :step, %{version: version, control: nil, slots: %{}, requests: %{}}},
      retention_count: 1_024,
      max_record_bytes: 16_777_216,
      max_checkpoint_bytes: 33_554_432
    ]

    pid =
      start_supervised!(%{
        id: make_ref(),
        start:
          {DurableLog.Memory, :start_link,
           [[fold: DurableUnit.fold(options), limits: DurableUnit.limits(options)]]}
      })

    DurableLog.Memory.store(pid)
  end

  defp memory_evidence_store do
    pid =
      start_supervised!(%{
        id: make_ref(),
        start:
          {DurableLog.Memory, :start_link, [[fold: evidence_fold(), limits: evidence_limits()]]}
      })

    DurableLog.Memory.store(pid)
  end

  defp evidence_fold,
    do: %{
      initial: nil,
      kinds: %{"completion" => :state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn _, _, _, bytes -> bytes end
    }

  defp evidence_limits,
    do: %{max_record_bytes: 131_072, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}

  # Runs `fun` while tracing the engine's calls of a pattern step or a schema check.
  defp without_calls(engine, fun) do
    traced = [{PayloadSchema, :check, 3}, {TestPattern, :step, 2}]
    Enum.each(traced, &:erlang.trace_pattern(&1, true, [:global]))
    :erlang.trace(engine, true, [:call])

    try do
      fun.()
      ref = :erlang.trace_delivered(engine)
      assert_receive {:trace_delivered, ^engine, ^ref}, 1_000
      refute_received {:trace, ^engine, :call, _}
    after
      :erlang.trace(engine, false, [:call])
      Enum.each(traced, &:erlang.trace_pattern(&1, false, [:global]))
    end
  end

  defp flush(message) do
    receive do
      ^message -> flush(message)
    after
      0 -> :ok
    end
  end

  defp slot_of(view, action_id),
    do: Enum.find(view.slots, fn {_, slot} -> slot.action_id == action_id end)

  defp binary(term), do: :erlang.term_to_binary(term, [:deterministic, {:minor_version, 2}])
  defp result(engine), do: RunEngine.result(engine, scope(), limits())
  defp reader(c), do: %{evidence_store: c.evidence_store, retention_count: 1_024}
  defp scope, do: %{tenant: "tenant", principal: "principal", run_id: "run"}
  defp limits, do: %{max_records: 65_536, max_bytes: 536_870_912}
end
