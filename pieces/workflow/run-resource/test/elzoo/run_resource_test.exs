# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RunResource.TestProvider do
  def failure_tags, do: [:timeout, :no_send]
  def schema, do: "resource-v1"

  def validate(bytes, "resource-v1"),
    do: if(match?({:ok, _}, Jason.decode(bytes)), do: :ok, else: :error)

  def poll(_), do: {:pending, "trusted"}
  def authenticate({:pending, "trusted"}, _), do: :ok
  def authenticate(result, req), do: if(result["correlation_id"] == req.key, do: :ok, else: :error)

  def validate_result(result, req),
    do: if(result["value"]["digest"] == req.arguments_digest, do: :ok, else: :error)

  def send_effect(req) do
    send(req.context.parent, {:provider_call, self(), req})

    receive do
      {:finish, observation} ->
        args = Jason.decode!(req.arguments)

        executed =
          Agent.get_and_update(req.context.provider, fn state ->
            case args["operation"] do
              "resource_close" ->
                {true, Map.put(state, args["ref"], :closed)}

              "resource_open" ->
                {state[args["ref"]] != :closed, Map.put_new(state, args["ref"], :open)}

              "resource_use" ->
                {state[args["ref"]] == :open, state}
            end
          end)

        result =
          if executed do
            %{
              "version" => 1,
              "message_id" => req.key,
              "correlation_id" => req.key,
              "attempt_id" => req.attempt_id,
              "outcome" => "completed",
              "dispatch" => "dispatched",
              "value" => %{"digest" => req.arguments_digest},
              "value_schema_id" => "resource-result",
              "value_schema_version" => 1
            }
          else
            {:error, :no_send, :physically_fenced}
          end

        send(req.context.parent, {:provider_evidence, req, result, observation})
        result

      :unknown ->
        {:error, :timeout, :lost_result}
    end
  end
end

defmodule Elzoo.RunResource.TestBinding do
  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.RunResource.TestProvider,
    id: "resource",
    provider_account: "test-account",
    operation: "resource",
    clock: "host-unix-ms",
    failures: %{
      timeout: {"timed_out", "unknown", "retryable"},
      no_send: {"rejected", "not_dispatched", "permanent"}
    },
    no_send_attestations: [:no_send],
    replay: :none
end

defmodule Elzoo.RunResourceTest do
  use ExUnit.Case, async: false
  alias Elzoo.{RunResource, PatternStep, Lease, EffectIntent, Budget, DurableLog}
  alias Elzoo.DurableLog.{Memory, Store}
  alias Elzoo.Lease.{Clock, Record}
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.RunResource.TestBinding

  defp fixture(overrides \\ %{}) do
    fold = %{
      initial: nil,
      versions: [1],
      destinations: [],
      kinds: Map.merge(%{"run_resource_state" => :state_bearing}, Lease.kinds()),
      reduce: fn _, _, _, payload -> payload end
    }

    limits = %{max_record_bytes: 4_000_000, max_batch_size: 4, max_checkpoint_bytes: 8_000_000}
    {:ok, memory} = Memory.start_link(fold: fold, limits: limits)
    {:ok, lease_clock} = Clock.manual(0)
    store = Memory.store(memory)
    {:ok, inject} = Agent.start_link(fn -> 0 end)

    {:ok, lease} =
      Lease.new(
        store: store,
        clock: {:manual, lease_clock},
        test_hook: fn phase, _ ->
          if phase == :before_write and
               Agent.get_and_update(inject, fn n -> {n == 1, max(0, n - 1)} end),
             do: Memory.fault(store, :append, :reply_loss)
        end
      )

    {:held, held} = Lease.claim(lease, "resource/" <> unique(), "owner", 60_000)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, provider} = Agent.start_link(fn -> %{} end)

    {:ok, effects} =
      Memory.start_link(fold: EffectIntent.fold(TestBinding), limits: EffectIntent.limits())

    {:ok, hosts} = Memory.start_link(fold: StoreHost.fold(), limits: StoreHost.limits())
    {:ok, tasks} = Task.Supervisor.start_link()

    resource =
      Map.merge(
        %{
          run_id: "run",
          name: "browser",
          deadline_ms: 1_000_000,
          rate_per_minute: 3,
          max_waiting: 1,
          budget: %{
            budget_id: "budget",
            unit: "credits",
            cost_ref: "resource-cost",
            generation: {"inc", 1}
          },
          close_intent: intent("cleanup", "resource_close", 2_000_000)
        },
        overrides
      )

    options = %{
      lease: lease,
      held: held,
      clock: fn -> Agent.get(clock, & &1) end,
      resource: resource
    }

    {:ok, owner} = RunResource.start_link(options)

    on_exit(fn ->
      for pid <- [owner, tasks, hosts, effects, provider, clock, lease.backend, lease_clock, memory],
          is_pid(pid),
          Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{
      owner: owner,
      inject: inject,
      options: options,
      lease: lease,
      store: store,
      lease_clock: lease_clock,
      clock: clock,
      provider: provider,
      effects: Memory.store(effects),
      hosts: Memory.store(hosts),
      tasks: tasks
    }
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  defp intent(id, operation, deadline \\ 900_000) do
    %{
      identity: ["tenant", "test-account", "resource", "resource", operation <> "/" <> id],
      arguments: Jason.encode!(%{"operation" => operation, "ref" => "stable-open"}),
      binding: "resource-v1",
      binding_digest: TestBinding.__effect_intent_binding__().digest,
      deadline_ms: deadline
    }
  end

  defp action(f, id, kind, context \\ %{run_id: "run", scope: :owner, resource_names: []}) do
    map = %{
      "id" => id,
      "kind" => kind,
      "schema_id" => "elzoo.run-resource.action",
      "schema_version" => 1,
      "payload" => %{"run_id" => "run", "resource_name" => "browser", "data" => %{}}
    }

    %{
      id: id,
      at_ms: time(f),
      body: {:action, map, context, if(kind == "resource_close", do: nil, else: intent(id, kind))}
    }
  end

  defp time(f), do: Agent.get(f.clock, & &1)
  defp at(f, time), do: Agent.update(f.clock, fn _ -> time end)
  defp cmd(f, id, body), do: RunResource.command(f.owner, %{id: id, at_ms: time(f), body: body})

  defp snapshot(f) do
    assert {:ok, snapshot} = RunResource.read(f.owner, 0)
    snapshot
  end

  defp inputs(f), do: Enum.flat_map(snapshot(f).entries, & &1.inputs)
  defp effects(f), do: Enum.flat_map(snapshot(f).entries, & &1.effects)

  defp outcomes(f, id),
    do: Enum.filter(inputs(f), &(&1["kind"] == "action_outcome" and &1["action_id"] == id))

  defp observed(f, id, intent, observation),
    do: cmd(f, id, {:observed, intent.identity, observation})

  defp effect(f, descriptor, activation \\ :fresh) do
    authorize =
      case activation do
        :fresh -> fn _, _ -> :fresh end
        :reconciled -> fn _, generation -> {:recovered, generation} end
        :read_only -> fn _, _ -> :deny end
      end

    {:ok, owner} =
      EffectIntent.start_link(
        binding: TestBinding,
        identity: descriptor.identity,
        arguments: descriptor.arguments,
        deadline: descriptor.deadline_ms,
        clock: f.options.clock,
        store: f.effects,
        task_supervisor: f.tasks,
        adapter_context: %{parent: self(), provider: f.provider},
        allow_volatile: true,
        host: {StoreHost, %{store: f.hosts, authorize: authorize}}
      )

    owner
  end

  defp dispatch(f, id, descriptor, owner), do: cmd(f, id, {:dispatch, descriptor.identity, owner})

  defp finish(f, descriptor, owner, worker, observation, id) do
    send(worker, {:finish, observation})
    assert_receive {:provider_evidence, req, result, ^observation}
    assert req.arguments == descriptor.arguments
    assert {:ok, _} = EffectIntent.observe(owner, result)
    assert {:ok, _} = observed(f, id, descriptor, observation)
  end

  defp open(f) do
    command = action(f, "open", "resource_open")
    assert {:ok, %{disposition: :accepted}} = RunResource.command(f.owner, command)
    descriptor = intent("open", "resource_open")
    owner = effect(f, descriptor)
    assert {:ok, %{disposition: :accepted}} = dispatch(f, "send-open", descriptor, owner)
    assert_receive {:provider_call, worker, _}
    finish(f, descriptor, owner, worker, {:completed, %{opened_at_ms: time(f)}}, "opened")
    assert snapshot(f).state.phase == :open
    f
  end

  defp restart(f) do
    if Process.alive?(f.owner), do: GenServer.stop(f.owner)
    {:held, held} = Lease.hold(f.lease, f.options.held.live.key, "owner")
    {:ok, owner} = RunResource.start_link(%{f.options | held: held})
    %{f | owner: owner}
  end

  test "serial_use_and_bounded_wait" do
    f = fixture() |> open()
    a = action(f, "A", "resource_use")
    assert {:ok, %{disposition: :accepted}} = receipt = RunResource.command(f.owner, a)
    assert RunResource.command(f.owner, a) == receipt
    assert {:refused, :id_conflict} = RunResource.command(f.owner, %{a | at_ms: 1})

    assert {:ok, %{disposition: :queued}} =
             RunResource.command(f.owner, action(f, "B", "resource_use"))

    assert {:refused, :queue_full} = RunResource.command(f.owner, action(f, "C", "resource_use"))
    assert snapshot(f).state.waiting_action_ids == ["B"]
    owner = effect(f, intent("A", "resource_use"))
    assert {:ok, _} = dispatch(f, "send-A", intent("A", "resource_use"), owner)
    assert_receive {:provider_call, worker, _}
    # A resource caller timeout does not cancel A or release its use slot.
    :sys.suspend(f.owner)
    task = Task.async(fn -> cmd(f, "late-tick", :tick) end)
    assert {:unknown, %{command_id: "late-tick"}} = Task.await(task, 6000)
    :sys.resume(f.owner)
    assert snapshot(f).state.active_action_id == "A"
    assert {:ok, _} = cmd(f, "pause", :pause)
    finish(f, intent("A", "resource_use"), owner, worker, {:completed, %{"value" => 7}}, "A-done")
    assert snapshot(f).state.active_action_id == nil
    assert snapshot(f).state.waiting_action_ids == ["B"]
    b_owner = effect(f, intent("B", "resource_use"))
    assert {:refused, :paused} = dispatch(f, "paused-B", intent("B", "resource_use"), b_owner)
    assert {:ok, _} = cmd(f, "continue", :continue)
    assert snapshot(f).state.active_action_id == "B"
    assert {:ok, _} = dispatch(f, "send-B", intent("B", "resource_use"), b_owner)
    assert_receive {:provider_call, b_worker, _}
    assert {:ok, _} = observed(f, "B-unknown", intent("B", "resource_use"), {:unknown, nil})

    assert {:ok, %{disposition: :queued}} =
             RunResource.command(f.owner, action(f, "D", "resource_use"))

    assert snapshot(f).state.active_action_id == "B"
    finish(f, intent("B", "resource_use"), b_owner, b_worker, {:completed, [9]}, "B-late-done")
    assert [%{"outcome" => "unknown"}] = outcomes(f, "B")
    assert snapshot(f).state.active_action_id == "D"
    d_owner = effect(f, intent("D", "resource_use"))
    assert {:ok, _} = RunResource.command(f.owner, action(f, "close", "resource_close"))
    assert {:refused, :closing} = dispatch(f, "obsolete-D", intent("D", "resource_use"), d_owner)

    assert {:ok, %{disposition: :late}} =
             dispatch(f, "send-B-again", intent("B", "resource_use"), b_owner)

    refute_receive {:provider_call, _, _}
    zero = fixture(%{max_waiting: 0}) |> open()
    assert {:ok, _} = RunResource.command(zero.owner, action(zero, "zero-A", "resource_use"))

    assert {:refused, :queue_full} =
             RunResource.command(zero.owner, action(zero, "zero-B", "resource_use"))

    other = fixture() |> open()
    assert {:ok, _} = RunResource.command(other.owner, action(other, "independent", "resource_use"))
    assert snapshot(other).state.active_action_id == "independent"
  end

  test "same_run_typed_name_grant" do
    f = fixture() |> open()

    for names <- [[], ["Browser"], ["other"]] do
      context = %{run_id: "run", scope: :nested, resource_names: names}
      command = action(f, "denied-" <> unique(), "resource_use", context)
      assert {:refused, :missing_name_grant} = RunResource.command(f.owner, command)
    end

    child = %{run_id: "child", scope: :nested, resource_names: ["browser"]}

    assert {:refused, :wrong_run} =
             RunResource.command(f.owner, action(f, "child", "resource_use", child))

    forged =
      action(f, "forged", "resource_use", %{run_id: "run", scope: :nested, resource_names: []})

    {:action, map, context, i} = forged.body
    map = put_in(map, ["payload", "data"], %{"resource_names" => ["browser"]})

    assert {:refused, :missing_name_grant} =
             RunResource.command(f.owner, %{forged | body: {:action, map, context, i}})

    refute Enum.any?(effects(f), &(Jason.decode!(&1.arguments)["operation"] == "resource_use"))
    refute_receive {:provider_call, _, _}
    grant = %{run_id: "run", scope: :nested, resource_names: ["browser"]}
    assert {:ok, _} = RunResource.command(f.owner, action(f, "nested", "resource_use", grant))
    i = intent("nested", "resource_use")
    owner = effect(f, i)
    assert {:ok, _} = dispatch(f, "send-nested", i, owner)
    assert_receive {:provider_call, worker, _}
    finish(f, i, owner, worker, {:completed, ["nested-result"]}, "nested-done")
    assert [%{"outcome" => "completed"}] = outcomes(f, "nested")
  end

  test "open_unknown_never_reopens" do
    f = fixture()
    i = intent("open", "resource_open")
    read_only = effect(f, i, :read_only)
    command = action(f, "open", "resource_open")
    assert {:ok, _} = first = RunResource.command(f.owner, command)
    assert {:refused, :read_only} = dispatch(f, "denied-send", i, read_only)
    refute_receive {:provider_call, _, _}
    owner = effect(f, i)
    assert {:ok, _} = dispatch(f, "send-open", i, owner)
    assert_receive {:provider_call, worker, _}
    send(worker, :unknown)
    assert {:ok, _} = observed(f, "lost-open", i, {:unknown, nil})
    assert [%{"outcome" => "unknown", "at_ms" => 0} = outcome] = outcomes(f, "open")
    {:action, map, _, _} = command.body
    {:ok, request} = PatternStep.decode(%{"type" => "request", "version" => 1, "actions" => [map]})
    {:ok, checked} = PatternStep.decode(outcome)
    {:applied, tracker} = PatternStep.accept(PatternStep.open(request), checked)
    {:ok, late} = PatternStep.decode(%{outcome | "outcome" => "late"})
    assert {:late, ^tracker} = PatternStep.accept(tracker, late)
    assert RunResource.command(f.owner, command) == first
    assert {:ok, _} = observed(f, "late-open", i, {:completed, %{opened_at_ms: 0}})
    assert snapshot(f).state.phase == :closing
    assert length(outcomes(f, "open")) == 1
    recovered = restart(f)
    assert snapshot(recovered).state.phase == :closing
    assert Enum.all?(effects(recovered), &(&1.identity == f.options.resource.close_intent.identity))
    assert RunResource.command(recovered.owner, command) == first
    refute_receive {:provider_call, _, _}
  end

  test "run_end_close_and_late_event" do
    for outcome <- [%{"opaque" => ["unfamiliar", 7]}, ["another", false]] do
      f = fixture() |> open()
      assert {:ok, _} = cmd(f, "event", {:event, "provider-event", %{"value" => 9}})
      assert {:ok, _} = RunResource.command(f.owner, action(f, "A", "resource_use"))
      assert {:ok, _} = RunResource.command(f.owner, action(f, "B", "resource_use"))
      input = end_input("run", time(f), outcome)
      assert {:ok, _} = receipt = cmd(f, "end", {:input, input})
      assert cmd(f, "end", {:input, input}) == receipt
      assert {:refused, :closing} = RunResource.command(f.owner, action(f, "new", "resource_use"))
      assert [%{"outcome" => "refused"}] = outcomes(f, "B")
      assert {:ok, %{disposition: :late}} = cmd(f, "late-event", {:event, "late-event", 9})
      assert {:ok, _} = RunResource.command(f.owner, action(f, "close-1", "resource_close"))
      assert {:ok, _} = RunResource.command(f.owner, action(f, "close-2", "resource_close"))
      cleanup = f.options.resource.close_intent
      assert Enum.count(effects(f), &(&1.identity == cleanup.identity)) == 1
      ro = effect(f, cleanup, :read_only)
      assert {:refused, :read_only} = dispatch(f, "read-only-close", cleanup, ro)
      assert snapshot(f).state.phase == :closing
      granted = effect(f, cleanup)
      assert {:ok, _} = dispatch(f, "send-close", cleanup, granted)
      assert_receive {:provider_call, worker, _}
      assert {:ok, _} = observed(f, "unknown-close", cleanup, {:unknown, nil})
      assert snapshot(f).state.phase == :closing
      at(f, 1)

      finish(
        f,
        cleanup,
        granted,
        worker,
        {:completed, %{opened_at_ms: 0, closed_at_ms: 1}},
        "closed"
      )

      assert snapshot(f).state.phase == :closed
      assert [%{"outcome" => "resource_lost"}] = outcomes(f, "A")
      assert length(outcomes(f, "close-1")) == 1

      assert {:ok, _} =
               observed(
                 f,
                 "closed-again",
                 cleanup,
                 {:completed, %{opened_at_ms: 0, closed_at_ms: 1}}
               )

      assert length(outcomes(f, "close-1")) == 1
      for input <- inputs(f), do: assert(match?({:ok, _}, PatternStep.decode(input)))

      assert Enum.count(
               inputs(f),
               &(&1["kind"] == "resource_event" and &1["payload"]["reason"] == "provider_event")
             ) == 1

      assert {:ok, _} = RunResource.command(f.owner, action(f, "close-after", "resource_close"))
      assert [%{"outcome" => "completed"}] = outcomes(f, "close-after")
    end
  end

  test "orphan_cleanup_requires_host_grant" do
    malformed = fixture()
    GenServer.stop(malformed.owner)
    key = malformed.options.held.live.key

    record =
      log_rows(malformed.store, key) |> List.last() |> Map.fetch!(:payload) |> Jason.decode!()

    {:held, held} = Lease.hold(malformed.lease, key, "owner")

    {:held, held} =
      Lease.write(malformed.lease, held, [
        {"run_resource_state", 1, Jason.encode!(Map.put(record, "entry", nil))}
      ])

    Process.flag(:trap_exit, true)

    assert {:error, :incompatible_recovery} =
             RunResource.start_link(%{malformed.options | held: held})

    for mutation <- [:none, :sequence, :input, :receipt, :state, :intent, :command] do
      retained = fixture() |> open()
      GenServer.stop(retained.owner)
      key = retained.options.held.live.key

      record =
        log_rows(retained.store, key) |> List.last() |> Map.fetch!(:payload) |> Jason.decode!()

      {:held, held} = Lease.hold(retained.lease, key, "owner")
      record = put_in(record, ["entry", "seq"], held.live.revision + 1)
      receipt_key = Jason.encode!(record["entry"]["command_id"])
      intent_key = Jason.encode!(intent("open", "resource_open").identity)

      record =
        case mutation do
          :none ->
            record

          :sequence ->
            put_in(record, ["entry", "seq"], held.live.revision)

          :input ->
            put_in(record, ["entry", "inputs"], [%{"type" => "input"}])

          :receipt ->
            update_in(record, ["state", "receipts", receipt_key], &Map.delete(&1, "receipt"))

          :state ->
            put_in(record, ["state", "opened"], "not-a-time")

          :intent ->
            update_in(
              record,
              ["state", "intents", intent_key, "descriptor"],
              &Map.delete(&1, "arguments")
            )

          :command ->
            put_in(record, ["state", "receipts", receipt_key, "command"], [0, ["action"]])
        end

      {:held, held} =
        Lease.write(retained.lease, held, [{"run_resource_state", 1, Jason.encode!(record)}])

      result = RunResource.start_link(%{retained.options | held: held})

      if mutation == :none do
        assert {:ok, owner} = result
        assert {:ok, %{state: %{phase: :closing}}} = RunResource.read(owner, 0)
        GenServer.stop(owner)
      else
        assert {:error, :incompatible_recovery} = result
      end
    end

    f = fixture() |> open()
    a = intent("A", "resource_use")
    assert {:ok, _} = RunResource.command(f.owner, action(f, "A", "resource_use"))
    a_owner = effect(f, a)
    assert {:ok, _} = dispatch(f, "send-A", a, a_owner)
    assert_receive {:provider_call, old_worker, _}
    recovered = restart(f)
    recovered = restart(recovered)
    assert snapshot(recovered).state.phase == :closing
    assert Enum.count(inputs(recovered), &(&1["payload"]["reason"] == "lost")) == 1
    assert [%{"outcome" => "resource_lost"}] = outcomes(recovered, "A")
    assert Enum.all?(effects(recovered), &(&1.identity == f.options.resource.close_intent.identity))
    cleanup = f.options.resource.close_intent
    ro = effect(recovered, cleanup, :read_only)
    assert {:refused, :read_only} = dispatch(recovered, "cleanup-ro", cleanup, ro)
    granted = effect(recovered, cleanup)
    assert {:ok, _} = dispatch(recovered, "cleanup-send", cleanup, granted)
    assert_receive {:provider_call, worker, _}

    finish(
      recovered,
      cleanup,
      granted,
      worker,
      {:completed, %{opened_at_ms: 0, closed_at_ms: 0}},
      "closed"
    )

    send(old_worker, {:finish, {:completed, %{}}})
    assert_receive {:provider_evidence, _, {:error, :no_send, :physically_fenced}, _}
    # Recovered EffectIntent dispatch reservations never schedule another local send.
    GenServer.stop(a_owner)
    a_recovered = effect(recovered, a, :reconciled)
    assert {:error, :not_dispatchable} = EffectIntent.advance(a_recovered, :dispatch)
    refute_receive {:provider_call, _, _}

    fold = %{
      initial: nil,
      versions: [1],
      kinds: %{"delivery" => :state_bearing},
      reduce: fn _, _, _, p -> p end
    }

    {:ok, host_memory} = Memory.start_link(fold: fold, limits: f.lease.limits)
    host_store = Memory.store(host_memory)
    first = consume(host_store, recovered)
    # Simulate host crash after destination commit, before the source cursor acknowledgement.
    restored = consume(host_store, recovered)
    assert restored == first
    assert length(restored.inputs) == length(inputs(recovered))
    assert length(restored.budget_commands) == 1
    {_, {:status, %{reserved: 0, committed: 0}}} = budget_step(restored.budget, 1, :status)
    assert Enum.all?(log_rows(host_store, "run-log"), &(&1.kind == "delivery"))

    fenced = fixture()

    {:held, _} =
      Lease.seize(
        fenced.lease,
        fenced.options.held.live.key,
        "replacement",
        60_000,
        :operator_takeover
      )

    assert {:error, :ownership_lost} = cmd(fenced, "fenced", :tick)

    uncertain = fixture() |> open()
    # Inject at the guarded resource write, after renewal, through Lease's existing test seam.
    Agent.update(uncertain.inject, fn _ -> 2 end)
    result = cmd(uncertain, "uncertain", :tick)
    assert {:unknown, %{command_id: "uncertain"}} = result
    # Confirm the exact unknown row through the existing Lease confirmation API.
    rows = log_rows(uncertain.store, uncertain.options.held.live.key)
    row = List.last(rows)
    info = %{stream: row.stream, expected: row.sequence - 1, nonce: row.nonce, records: [row]}
    assert {:committed, _} = Lease.confirm(uncertain.lease, info)
    uncertain = restart(uncertain)
    assert {:ok, %{disposition: :applied}} = cmd(uncertain, "uncertain", :tick)
    assert snapshot(uncertain).state.phase == :closing

    Process.flag(:trap_exit, true)

    assert {:error, :incompatible_recovery} =
             RunResource.start_link(%{
               uncertain.options
               | resource: %{uncertain.options.resource | rate_per_minute: 4}
             })
  end

  test "pause_stay_close_and_deadline" do
    for recovered? <- [false, true] do
      timer = fixture(%{deadline_ms: 10_000})
      timer = if recovered?, do: timer |> open() |> restart(), else: timer
      at(timer, 10_000)
      send(timer.owner, :deadline)
      assert snapshot(timer).state.phase == if(recovered?, do: :closing, else: :closed)
      assert Enum.count(inputs(timer), &(&1["payload"]["reason"] == "expired")) == 1
    end

    fresh_timer = fixture(%{deadline_ms: 10_000})
    {:ok, before_timer} = Store.read(fresh_timer.store, :head, [fresh_timer.options.held.live.key])
    :ok = Clock.advance(fresh_timer.lease_clock, 30_000_000)
    send(fresh_timer.owner, :renew)
    assert snapshot(fresh_timer).state.phase == :new
    {:ok, after_timer} = Store.read(fresh_timer.store, :head, [fresh_timer.options.held.live.key])
    assert after_timer.revision > before_timer.revision

    recovered_timer = fixture(%{deadline_ms: 10_000}) |> open() |> restart()

    {:ok, before_timer} =
      Store.read(recovered_timer.store, :head, [recovered_timer.options.held.live.key])

    send(recovered_timer.owner, :renew)
    assert snapshot(recovered_timer).state.phase == :closing

    {:ok, after_timer} =
      Store.read(recovered_timer.store, :head, [recovered_timer.options.held.live.key])

    assert after_timer.revision > before_timer.revision

    for policy <- [:default, :stay] do
      overrides = if policy == :default, do: %{}, else: %{pause_policy: policy}
      f = fixture(Map.put(overrides, :deadline_ms, 10_000)) |> open()
      assert {:ok, _} = cmd(f, "pause", :pause)
      at(f, 9999)
      assert {:ok, _} = cmd(f, "before", :tick)
      assert snapshot(f).state.phase == :open
      assert snapshot(f).state.accrued_ms == 9999
      # No timer delivery is needed for admission to notice expiry; command time is older.
      at(f, 10_000)
      old = %{action(f, "stale-use", "resource_use") | at_ms: 1}
      assert {:refused, :closing} = RunResource.command(f.owner, old)
      send(f.owner, :deadline)
      send(f.owner, :deadline)
      assert {:ok, _} = cmd(f, "after", :tick)
      assert Enum.count(inputs(f), &(&1["payload"]["reason"] == "expired")) == 1
      assert snapshot(f).state.accrued_ms == 10_000
      assert {:ok, _} = cmd(f, "continue", :continue)
      assert snapshot(f).state.phase == :closing
    end

    close = fixture(%{pause_policy: :close}) |> open()
    assert {:ok, _} = cmd(close, "pause", :pause)
    assert snapshot(close).state.phase == :closing
    assert {:ok, _} = cmd(close, "continue", :continue)
    assert snapshot(close).state.phase == :closing
    # A renewal message samples the Store clock and retains a fresh fence.
    expired = fixture()
    :ok = Clock.advance(expired.lease_clock, 60_000_000)
    assert {:error, :ownership_lost} = cmd(expired, "lease-expired", :tick)

    for kind <- ["pause", "tick"] do
      assert {:error, :invalid_shape} =
               PatternStep.decode(%{
                 "type" => "input",
                 "version" => 1,
                 "kind" => kind,
                 "at_ms" => 0
               })
    end

    {example, _} = Code.eval_file(Path.expand("../../examples/close.exs", __DIR__))
    fresh = fixture()
    assert {:ok, _} = example.(fresh.owner, "run", 0)
    assert snapshot(fresh).state.phase == :closed
  end

  test "paused_usage_survives_empty_budget" do
    for {duration, expected} <- [{0, :release}, {1, 3}, {59_999, 3}, {60_000, 3}, {60_001, 6}] do
      {:ok, initial} = Budget.initial("budget", "inc", 3, "credits")

      {reserved, {:reserved, %{generation: generation}}} =
        budget_step(
          initial,
          1,
          {:reserve, %{cap: 3, unit: "credits", cost_ref: "resource-cost", estimate: 1, expiry: 2}}
        )

      {empty, {:reserved, _}} =
        budget_step(
          reserved,
          1,
          {:reserve, %{cap: 3, unit: "credits", cost_ref: "elsewhere", estimate: 2, expiry: 2}}
        )

      {empty, {:settled, _}} =
        budget_step(
          empty,
          1,
          {:settle, %{cost_ref: "elsewhere", generation: generation, actual: 2}}
        )

      {empty, {:status, %{remaining: 0}}} = budget_step(empty, 1, :status)

      f =
        fixture(%{
          budget: %{
            budget_id: "budget",
            unit: "credits",
            cost_ref: "resource-cost",
            generation: generation
          }
        })
        |> open()

      assert {:ok, _} = cmd(f, "pause", :pause)

      if duration >= 10_000 do
        at(f, 10_000)
        assert {:ok, _} = cmd(f, "first-interval", :tick)
      end

      at(f, duration)
      assert {:ok, _} = cmd(f, "second-interval", :tick)
      assert snapshot(f).state.phase == :open
      assert snapshot(f).state.accrued_ms == duration
      at(f, duration + 100_000)
      assert {:ok, _} = RunResource.command(f.owner, action(f, "close", "resource_close"))
      cleanup = f.options.resource.close_intent

      assert {:ok, _} =
               observed(
                 f,
                 "final",
                 cleanup,
                 {:completed, %{opened_at_ms: 0, closed_at_ms: duration}}
               )

      commands = snapshot(f).entries |> Enum.map(& &1.budget_command) |> Enum.reject(&is_nil/1)
      assert [command] = commands

      if expected == :release do
        assert {:release, %{cost_ref: "resource-cost", generation: ^generation}} = command
      else
        assert {:settle, %{actual: ^expected, generation: ^generation}} = command
      end

      # Restore retained pure Budget state, not a new Budget.Owner incarnation.
      retained = empty |> :erlang.term_to_binary() |> :erlang.binary_to_term([:safe])
      {settled, result} = budget_step(retained, max(3, duration), command)
      {repeated, repeated_result} = budget_step(settled, max(3, duration), command)
      assert repeated == settled and repeated_result == result
      {_, {:status, status}} = budget_step(repeated, max(3, duration), :status)
      assert status.committed == 2 + if(expected == :release, do: 0, else: expected)

      assert {:ok, _} =
               observed(
                 f,
                 "final-repeat",
                 cleanup,
                 {:completed, %{opened_at_ms: 0, closed_at_ms: duration}}
               )

      assert Enum.count(snapshot(f).entries, &(&1.budget_command != nil)) == 1
    end

    unknown = fixture()
    assert {:ok, _} = RunResource.command(unknown.owner, action(unknown, "open", "resource_open"))
    assert {:ok, _} = observed(unknown, "unknown", intent("open", "resource_open"), {:unknown, nil})
    assert snapshot(unknown).state.final_actual == nil
    assert Enum.all?(snapshot(unknown).entries, &is_nil(&1.budget_command))
  end

  defp end_input(run, at, outcome) do
    {:ok, checked} =
      PatternStep.decode(%{
        "type" => "input",
        "version" => 1,
        "kind" => "run_ended",
        "at_ms" => at,
        "schema_id" => "elzoo.run-resource.run-ended",
        "schema_version" => 1,
        "payload" => %{"run_id" => run, "outcome" => outcome}
      })

    checked
  end

  defp budget_step(state, at, input) do
    {:Transition, next, {:some, result}} = Budget.step(state, {at, input})
    {next, result}
  end

  defp log_rows(store, key) do
    {:ok, head} = Store.read(store, :head, [key])
    {:ok, rows, _} = DurableLog.read(store, key, 1, max(1, head.revision))
    rows
  end

  defp consume(store, resource) do
    retained =
      case log_rows(store, "run-log") do
        [] ->
          {:ok, budget} = Budget.initial("budget", "inc", 10, "credits")

          {budget, {:reserved, _}} =
            budget_step(
              budget,
              1,
              {:reserve,
               %{cap: 10, unit: "credits", cost_ref: "resource-cost", estimate: 1, expiry: 100}}
            )

          %{cursor: 0, inputs: [], budget_commands: [], budget: budget}

        rows ->
          :erlang.binary_to_term(List.last(rows).payload, [:safe])
      end

    {:ok, delivery} = RunResource.read(resource.owner, retained.cursor)

    Enum.reduce(delivery.entries, retained, fn entry, retained ->
      # Destination updates and cursor share one retained Run-log append.
      next = %{
        cursor: entry.seq,
        inputs: retained.inputs ++ entry.inputs,
        budget:
          if(entry.budget_command,
            do: elem(budget_step(retained.budget, 1, entry.budget_command), 0),
            else: retained.budget
          ),
        budget_commands:
          retained.budget_commands ++ if(entry.budget_command, do: [entry.budget_command], else: [])
      }

      {module, _} = store
      {:ok, current} = Store.read(store, :head, ["run-log"])

      {:ok, rows, _} =
        Record.records(
          "run-log",
          current.revision,
          [{"delivery", 1, :erlang.term_to_binary(next)}],
          elem(store, 1).fold,
          elem(store, 1).limits
        )

      {:committed, _} = module.append(store, "run-log", current.revision, rows, [])
      next
    end)
  end
end
