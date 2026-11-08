# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/effect_intent_test_helper.exs", __DIR__)

defmodule Elzoo.EffectIntentTest do
  use ExUnit.Case, async: false
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.{Binding, Model, Policy, StoreHost, TestBinding}
  alias Elzoo.DurableLog.{Memory, Store}

  setup do
    {:ok, binding} = Binding.load(TestBinding)
    store_pid = start_supervised!({Memory, fold: Model.fold(binding), limits: Model.limits()})
    store = Memory.store(store_pid)

    host_pid =
      start_supervised!(
        Supervisor.child_spec({Memory, fold: StoreHost.fold(), limits: StoreHost.limits()},
          id: :host_store
        )
      )

    host_store = Memory.store(host_pid)
    authority = start_supervised!(Supervisor.child_spec({Agent, fn -> :fresh end}, id: :authority))
    clock = start_supervised!(Supervisor.child_spec({Agent, fn -> 100 end}, id: :clock))
    supervisor = start_supervised!({Task.Supervisor, []})

    host = %{
      store: host_store,
      authorize: fn _, generation ->
        case Agent.get(authority, & &1) do
          :fresh -> :fresh
          :recover -> {:recovered, generation}
          _ -> :deny
        end
      end
    }

    context = %{
      parent: self(),
      send: fn _ -> {:error, :timeout, "timeout"} end,
      poll: fn _ -> {:pending, "trusted"} end
    }

    opts = [
      binding: TestBinding,
      identity: ["tenant", "account", "test", "refund", "request"],
      arguments: "arguments",
      deadline: 5000,
      clock: fn -> Agent.get(clock, & &1) end,
      store: store,
      host: {StoreHost, host},
      adapter_context: context,
      task_supervisor: supervisor,
      allow_volatile: true
    ]

    on_exit(fn -> Application.delete_env(:elzoo, :effect_intent_test_schema) end)

    %{
      binding: binding,
      store: store,
      host_store: host_store,
      authority: authority,
      clock: clock,
      opts: opts,
      host: host,
      context: context
    }
  end

  defp owner(opts), do: start_supervised!(Supervisor.child_spec({Intent, opts}, id: make_ref()))
  defp eventually(fun, n \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (receive do
         after
           10 -> eventually(fun, n - 1)
         end)
  end

  defp completed(req),
    do: %{
      "version" => 1,
      "message_id" => req.key,
      "correlation_id" => req.key,
      "attempt_id" => req.attempt_id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{"digest" => req.arguments_digest},
      "value_schema_id" => "completion",
      "value_schema_version" => 1
    }

  defp pure(binding, events, opts \\ []) do
    {:ok, c} =
      Policy.config(binding, Keyword.get(opts, :deadline, 5000), 100, Keyword.get(opts, :now, 100))

    Enum.reduce(events, Policy.initial(), fn event, s ->
      {:Decision, next, _} = Policy.decide(s, event, Policy.count(s), c)
      next
    end)
  end

  test "first dispatch requires both intended and dispatched checkpoints; timeout does not resend",
       c do
    pid = owner(c.opts)
    assert %{phase: {:Intended, :Fresh, 0}, revision: 1, active: true} = Intent.status(pid)
    stream = Model.stream(Intent.status(pid).key)
    assert {:ok, %{sequence: 1}} = Store.read(c.store, :latest_checkpoint, [stream, 1])
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, req}
    assert req.arguments == "arguments"
    assert {:ok, %{sequence: 2}} = Store.read(c.store, :latest_checkpoint, [stream, 1])
    eventually(fn -> Intent.status(pid).revision == 3 end)
    assert Intent.status(pid).phase == {:Dispatched, :Fresh, 1}
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
    assert {:error, :not_dispatchable} = Intent.advance(pid, :dispatch)
    refute_receive {:physical_send, _, _}, 20
  end

  test "G1 laundering regression refuses a third send after replay-safe then no-send", c do
    s = pure(c.binding, [:Admit, :Arm, :ProviderUnknown, :Rearm, :Arm, :NoSend])
    assert Policy.flags(s).replay_dependent
    {:ok, expired} = Policy.config(c.binding, 5000, 100, 1101)
    assert {:Decision, ^s, :Stop} = Policy.decide(s, :Rearm, 2, expired)
    # An already intended third attempt also refuses when the horizon expires.
    {:ok, live} = Policy.config(c.binding, 5000, 100, 200)
    {:Decision, i, :Stop} = Policy.decide(s, :Rearm, 2, live)
    assert {:Decision, ^i, :Stop} = Policy.decide(i, :Arm, 2, expired)
    assert Policy.flags(i).ever_possibly_sent
  end

  test "old completion across replay-safe history confirms, mixed no-send history freezes in Cure",
       c do
    s = pure(c.binding, [:Admit, :Arm, :ProviderUnknown, :Rearm, :Arm])
    {:ok, cfg} = Policy.config(c.binding, 5000, 100, 200)
    assert {:Decision, confirmed, :Stop} = Policy.decide(s, :Completed, 1, cfg)
    assert Policy.phase(confirmed) == {:Confirmed, 2}
    {:Decision, no_send, _} = Policy.decide(s, :NoSend, 2, cfg)
    assert {:Decision, frozen, :Stop} = Policy.decide(no_send, :Completed, 1, cfg)
    assert Policy.flags(frozen).quarantined
    assert Policy.flags(frozen).disarmed
    assert {:Decision, ^frozen, :Stop} = Policy.decide(frozen, :Rearm, 2, cfg)
  end

  test "owner settles completion once and refuses duplicate or mismatched observations", c do
    context = %{c.context | send: fn req -> completed(req) end}
    pid = owner(Keyword.put(c.opts, :adapter_context, context))
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, req}
    eventually(fn -> Intent.status(pid).phase == {:Confirmed, 1} end)
    assert {:ok, :retained} = Intent.observe(pid, completed(req))
    assert Intent.status(pid).phase == {:Confirmed, 1}

    assert {:error, :invalid_observation} =
             Intent.observe(pid, Map.delete(completed(req), "attempt_id"))

    assert {:error, :invalid_observation} =
             Intent.observe(pid, %{completed(req) | "attempt_id" => "other"})

    assert {:error, :not_dispatchable} = Intent.advance(pid, :dispatch)
  end

  test "every restart is read-only; exact host recovery grants status-bound activation", c do
    pid = owner(c.opts)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, _}
    eventually(fn -> Intent.status(pid).revision == 3 end)
    GenServer.stop(pid)
    restarted = owner(c.opts)
    assert Intent.status(restarted).active == false
    assert {:error, :read_only} = Intent.advance(restarted, :poll)
    GenServer.stop(restarted)
    Agent.update(c.authority, fn _ -> :recover end)
    active = owner(c.opts)
    assert Intent.status(active).active
    assert {:ok, :polling} = Intent.advance(active, :poll)
    assert_receive {:physical_poll, _, _}
    refute_receive {:physical_send, _, _}, 20
  end

  test "checkpoint failure after dispatched append never sends and recovered reservation only polls",
       c do
    pid = owner(c.opts)
    :ok = Memory.fault(c.store, :put_checkpoint, :unavailable)
    assert {:error, {:checkpoint, {:indeterminate, _}}} = Intent.advance(pid, :dispatch)
    refute_receive {:physical_send, _, _}, 20
    assert Intent.status(pid).phase == {:Dispatched, :Fresh, 1}
    assert Intent.status(pid).active == false
    GenServer.stop(pid)
    Agent.update(c.authority, fn _ -> :recover end)
    recovered = owner(c.opts)
    assert {:error, :not_dispatchable} = Intent.advance(recovered, :dispatch)
    assert {:ok, :polling} = Intent.advance(recovered, :poll)
    assert_receive {:physical_poll, _, _}
  end

  test "uncertain append halts even when absence is observed; delayed commit does not restore ownership",
       c do
    pid = owner(c.opts)
    :ok = Memory.fault(c.store, :append, {:pause, :dispatch})
    assert {:error, {:write, {:indeterminate, _}}} = Intent.advance(pid, :dispatch)
    assert Intent.status(pid).active == false
    refute_receive {:physical_send, _, _}, 20
    assert {:committed, 2} = Memory.release(c.store, :dispatch)
    assert {:error, :read_only} = Intent.advance(pid, :dispatch)
    GenServer.stop(pid)
    recovered = owner(c.opts)
    assert Intent.status(recovered).phase == {:Dispatched, :Fresh, 1}
    refute Intent.status(recovered).active
  end

  test "schema validation before reservation creates no attempt and only permitted revision clears disarm",
       c do
    pid = owner(Keyword.put(c.opts, :arguments, "bad"))
    assert {:error, :schema} = Intent.advance(pid, :dispatch)
    assert Intent.status(pid).attempts == 0
    assert Intent.status(pid).flags.disarmed
    assert {:ok, :Stop} = Intent.revise(pid, "good")
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, %{arguments: "good"}}
  end

  test "marker exists without intent: crash before admission can recover only with explicit host grant",
       c do
    :ok = Memory.fault(c.store, :append, :unavailable)
    pid = owner(c.opts)
    refute Intent.status(pid).active
    assert Intent.status(pid).phase == :absent
    GenServer.stop(pid)
    blocked = owner(c.opts)
    refute Intent.status(blocked).active
    GenServer.stop(blocked)
    Agent.update(c.authority, fn _ -> :recover end)
    activated = owner(c.opts)
    assert Intent.status(activated).phase == {:Intended, :Fresh, 0}
    assert Intent.status(activated).active
  end

  test "nonce generation revision and digest mismatch refuse host activation", c do
    for {field, value} <- [nonce: <<0::128>>, generation: 999, revision: 999, digest: <<0::256>>] do
      identity = List.replace_at(c.opts[:identity], 4, Atom.to_string(field))

      host =
        {Elzoo.EffectIntent.TestBadHost,
         Map.put(c.host, :change, fn g -> Map.put(g, field, value) end)}

      pid = owner(c.opts |> Keyword.put(:identity, identity) |> Keyword.put(:host, host))
      refute Intent.status(pid).active
      assert {:error, :read_only} = Intent.advance(pid, :dispatch)
    end

    refute_receive {:physical_send, _, _}, 20
  end

  test "native deadlines never create a rearm ground; default none and overflow", c do
    assert {:ok, :NoRecovery} = Binding.recovery_deadline(100, :none)
    assert {:ok, {:RecoveryAt, 100}} = Binding.recovery_deadline(100, 0)
    assert {:error, :deadline_overflow} = Binding.recovery_deadline(9_223_372_036_854_775_807, 1)
    s = pure(c.binding, [:Admit, :Arm], deadline: 150)
    {:ok, expiry} = Policy.config(c.binding, 150, 100, 250)
    assert {:Decision, stranded, :Reconcile} = Policy.decide(s, :Expired, 1, expiry)
    assert Policy.phase(stranded) == {:Stranded, 1}
    assert {:Decision, ^stranded, :Stop} = Policy.decide(stranded, :Rearm, 1, expiry)
  end

  test "all eight Envelope pairs take the intended path, including permanent possibly-sent results",
       c do
    pairs = [
      {"completed", "dispatched", nil, :confirmed},
      {"rejected", "not_dispatched", "permanent", :disarmed},
      {"failed", "dispatched", "permanent", :pending},
      {"timed_out", "not_dispatched", "retryable", :no_send},
      {"timed_out", "dispatched", "permanent", :pending},
      {"timed_out", "unknown", "retryable", :pending},
      {"unknown", "dispatched", "unclassified", :pending},
      {"unknown", "unknown", "unclassified", :pending}
    ]

    for {{outcome, dispatch, error, expected}, i} <- Enum.with_index(pairs) do
      context = %{
        c.context
        | send: fn _ ->
            if dispatch == "not_dispatched" do
              tag = if outcome == "rejected", do: :permanent, else: :no_send
              {:error, tag, :attested_no_bytes}
            else
              receive do
                :release -> {:error, :timeout, "timeout"}
              end
            end
          end
      }

      opts =
        c.opts
        |> Keyword.put(:identity, List.replace_at(c.opts[:identity], 4, "pair-#{i}"))
        |> Keyword.put(:adapter_context, context)

      pid = owner(opts)
      assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      assert_receive {:physical_send, _, req}

      row = %{
        "version" => 1,
        "message_id" => req.key,
        "correlation_id" => req.key,
        "attempt_id" => req.attempt_id,
        "outcome" => outcome,
        "dispatch" => dispatch
      }

      row =
        if error,
          do: Map.put(row, "error_class", error),
          else:
            Map.merge(
              row,
              Map.take(completed(req), ["value", "value_schema_id", "value_schema_version"])
            )

      if dispatch == "not_dispatched" do
        eventually(fn -> Intent.status(pid).phase == {:Definite, :AdapterNoSend, 1} end)
        assert {:refused, :retained} = Intent.observe(pid, row)
      else
        assert {:ok, _} = Intent.observe(pid, row)
      end

      status = Intent.status(pid)

      case expected do
        :confirmed -> assert status.phase == {:Confirmed, 1}
        :disarmed -> assert status.phase == {:Definite, :AdapterNoSend, 1} and status.flags.disarmed
        :no_send -> assert status.phase == {:Definite, :AdapterNoSend, 1}
        :pending -> assert status.phase == {:Dispatched, :Fresh, 1}
      end
    end
  end

  test "task death after dispatch is unknown and never creates a no-send ground", c do
    context = %{c.context | send: fn _ -> exit(:simulated_adapter_death) end}
    pid = owner(Keyword.put(c.opts, :adapter_context, context))
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, _}
    eventually(fn -> Intent.status(pid).revision == 3 end)
    assert Intent.status(pid).phase == {:Dispatched, :Fresh, 1}
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
  end

  test "initial checkpoint uncertainty and intended restart cannot silently activate", c do
    :ok = Memory.fault(c.store, :put_checkpoint, :unavailable)
    pid = owner(c.opts)
    refute Intent.status(pid).active
    assert Intent.status(pid).phase == {:Intended, :Fresh, 0}
    refute_receive {:physical_send, _, _}, 20
    GenServer.stop(pid)
    recovered = owner(c.opts)
    refute Intent.status(recovered).active
    assert {:error, :read_only} = Intent.advance(recovered, :dispatch)
  end

  test "no-replay unknown-to-provider strands and late completion is operator evidence", c do
    opts =
      c.opts
      |> Keyword.put(:binding, Elzoo.EffectIntent.TestNoReplayBinding)
      |> Keyword.put(:adapter_context, %{
        c.context
        | poll: fn _ -> {:unknown_to_provider, "trusted"} end
      })

    # The Store fold must use the same binding as the owner.
    {:ok, b} = Binding.load(Elzoo.EffectIntent.TestNoReplayBinding)

    memory =
      start_supervised!(
        Supervisor.child_spec({Memory, fold: Model.fold(b), limits: Model.limits()}, id: :no_replay)
      )

    pid = owner(Keyword.put(opts, :store, Memory.store(memory)))
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, req}
    eventually(fn -> Intent.status(pid).revision == 3 end)
    assert {:ok, :polling} = Intent.advance(pid, :poll)
    assert_receive {:physical_poll, _, _}
    eventually(fn -> Intent.status(pid).phase == {:Stranded, 1} end)
    assert {:ok, :retained} = Intent.observe(pid, completed(req))
    assert Intent.status(pid).phase == {:Stranded, 1}
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
  end

  test "late no-effect versus completion in both owner orders obeys settlement/contradiction rules",
       c do
    for first <- [:completion, :certificate] do
      parent = self()

      context = %{
        c.context
        | send: fn _ ->
            receive do
              :finish -> {:error, :timeout, "timeout"}
            end
          end,
          poll: fn _ ->
            send(parent, {:poll_waiting, self()})

            receive do
              :finish -> {:no_effect, "trusted"}
            end
          end
      }

      opts =
        c.opts
        |> Keyword.put(:identity, List.replace_at(c.opts[:identity], 4, Atom.to_string(first)))
        |> Keyword.put(:adapter_context, context)

      pid = owner(opts)
      assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      assert_receive {:physical_send, _, req}
      assert {:ok, :polling} = Intent.advance(pid, :poll)
      assert_receive {:physical_poll, _, _}
      assert_receive {:poll_waiting, poll_pid}

      if first == :completion do
        assert {:ok, :retained} = Intent.observe(pid, completed(req))
        send(poll_pid, :finish)
        eventually(fn -> Intent.status(pid).revision == 4 end)
        assert Intent.status(pid).phase == {:Confirmed, 1}
        refute Intent.status(pid).flags.quarantined
      else
        send(poll_pid, :finish)
        eventually(fn -> Intent.status(pid).phase == {:Definite, :ProviderNoEffect, 1} end)
        assert {:ok, :retained} = Intent.observe(pid, completed(req))
        assert Intent.status(pid).flags.quarantined
        assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
      end
    end
  end

  test "paused old task can send late only under the provider replay Need; the double deduplicates",
       c do
    provider =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> %{effects: %{}, calls: 0} end}, id: :provider)
      )

    apply_effect = fn req ->
      Agent.update(provider, fn state ->
        %{
          state
          | effects: Map.put_new(state.effects, req.key, req.arguments_digest),
            calls: state.calls + 1
        }
      end)

      completed(req)
    end

    old_context = %{
      c.context
      | send: fn req ->
          receive do
            :release -> apply_effect.(req)
          end
        end
    }

    old = owner(Keyword.put(c.opts, :adapter_context, old_context))
    assert {:ok, :dispatched} = Intent.advance(old, :dispatch)
    assert_receive {:physical_send, old_task, old_req}
    GenServer.stop(old)
    assert Process.alive?(old_task)
    Agent.update(c.authority, fn _ -> :recover end)

    new_context = %{
      c.context
      | send: apply_effect,
        poll: fn _ -> {:unknown_to_provider, "trusted"} end
    }

    newer = owner(Keyword.put(c.opts, :adapter_context, new_context))
    assert {:ok, :polling} = Intent.advance(newer, :poll)
    assert_receive {:physical_poll, _, _}
    eventually(fn -> Intent.status(newer).phase == {:Definite, :ProviderReplaySafe, 1} end)
    assert {:ok, :Stop} = Intent.advance(newer, :rearm)
    assert {:ok, :dispatched} = Intent.advance(newer, :dispatch)
    assert_receive {:physical_send, _, new_req}
    assert old_req.key == new_req.key
    eventually(fn -> Intent.status(newer).phase == {:Confirmed, 2} end)
    send(old_task, :release)
    eventually(fn -> Agent.get(provider, & &1.calls) == 2 end)
    assert map_size(Agent.get(provider, & &1.effects)) == 1
    assert {:ok, :retained} = Intent.observe(newer, completed(old_req))
  end

  test "transport hidden re-send negative control violates the physical-send count despite one reservation",
       c do
    context = %{
      c.context
      | send: fn req ->
          send(req.context.parent, {:physical_send, self(), req})
          {:error, :timeout, "hidden library retry"}
        end
    }

    pid = owner(Keyword.put(c.opts, :adapter_context, context))
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, req1}
    assert_receive {:physical_send, _, req2}
    assert req1.attempt_id == req2.attempt_id
    assert Intent.status(pid).attempts == 1
    # The conformance condition intentionally fails for this malicious Adapter.
    refute 2 == Intent.status(pid).attempts
  end

  test "undersized Store and silent volatile fallback are refused before activation", c do
    Process.flag(:trap_exit, true)

    assert {:error, :invalid_options_or_recovery} =
             Intent.start_link(Keyword.delete(c.opts, :allow_volatile))

    for key <- Map.keys(Model.limits()) do
      limits = Map.update!(Model.limits(), key, &(&1 - 1))

      pid =
        start_supervised!(
          Supervisor.child_spec({Memory, fold: Model.fold(c.binding), limits: limits},
            id: make_ref()
          )
        )

      assert {:error, :invalid_options_or_recovery} =
               Intent.start_link(Keyword.put(c.opts, :store, Memory.store(pid)))
    end

    assert {:ok, %{revision: 0}} =
             Store.read(c.host_store, :head, [StoreHost.stream(Model.key(c.opts[:identity]))])
  end

  test "send callback cannot mint poll-only replay or no-effect authority", c do
    for kind <- [:unknown_to_provider, :no_effect] do
      context = %{c.context | send: fn _ -> {kind, "trusted"} end}
      identity = List.replace_at(c.opts[:identity], 4, Atom.to_string(kind))

      pid =
        owner(c.opts |> Keyword.put(:adapter_context, context) |> Keyword.put(:identity, identity))

      assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      assert_receive {:physical_send, _, _}
      eventually(fn -> Intent.status(pid).revision == 3 end)
      assert Intent.status(pid).phase == {:Dispatched, :Fresh, 1}
      assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
    end
  end

  test "owner keeps replay horizon after a later no-send and refuses third physical send", c do
    context = %{
      c.context
      | send: fn req ->
          if req.attempt == 1, do: {:error, :timeout, :unknown}, else: {:error, :no_send, :none}
        end,
        poll: fn _ -> {:unknown_to_provider, "trusted"} end
    }

    pid = owner(Keyword.put(c.opts, :adapter_context, context))
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, _}
    eventually(fn -> Intent.status(pid).revision == 3 end)
    assert {:ok, :polling} = Intent.advance(pid, :poll)
    eventually(fn -> Intent.status(pid).phase == {:Definite, :ProviderReplaySafe, 1} end)
    assert {:ok, :Stop} = Intent.advance(pid, :rearm)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, _}
    eventually(fn -> Intent.status(pid).phase == {:Definite, :AdapterNoSend, 2} end)
    Agent.update(c.clock, fn _ -> 1101 end)
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
    assert {:error, :not_dispatchable} = Intent.advance(pid, :dispatch)
    assert Intent.status(pid).flags.replay_dependent
    refute_receive {:physical_send, _, _}, 20
  end

  test "failed initial admission stays readable and cannot act on an absent model", c do
    Application.put_env(:elzoo, :effect_intent_test_schema, nil)
    pid = owner(c.opts)
    assert %{phase: :absent, active: false, revision: 0} = Intent.status(pid)
    assert {:error, :read_only} = Intent.advance(pid, :dispatch)
    assert {:error, :read_only} = Intent.observe(pid, %{})
    refute_receive {:physical_send, _, _}, 20
  end

  @tag timeout: 120_000
  test "known-attempt refusals fill only optional capacity and reserved settlement/contradiction still commit",
       c do
    assert Policy.initial() == {:State, :Empty, false, false, false, false, 0, []}
    context = %{c.context | poll: fn _ -> {:no_effect, "trusted"} end}
    pid = owner(Keyword.put(c.opts, :adapter_context, context))
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, req}
    eventually(fn -> Intent.status(pid).revision == 3 end)
    invalid = put_in(completed(req), ["value", "digest"], <<0::256>>)

    for _ <- 1..1022 do
      assert {:refused, :retained} = Intent.observe(pid, invalid)
    end

    assert %{phase: {:Dispatched, :Fresh, 1}, evidence: 1022, active: true} = Intent.status(pid)
    assert {:not_retained, :capacity} = Intent.observe(pid, invalid)
    assert Intent.status(pid).active
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)

    assert {:ok, :polling} = Intent.advance(pid, :poll)
    assert_receive {:physical_poll, _, _}
    eventually(fn -> Intent.status(pid).phase == {:Definite, :ProviderNoEffect, 1} end)
    assert Intent.status(pid).evidence == 1023
    assert {:ok, :retained} = Intent.observe(pid, completed(req))
    assert Intent.status(pid).flags.quarantined
    assert Intent.status(pid).evidence == 1024
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
    GenServer.stop(pid)
    Agent.update(c.authority, fn _ -> :recover end)
    recovered = owner(c.opts)
    assert Intent.status(recovered).flags.quarantined
    assert Intent.status(recovered).evidence == 1024
    assert {:error, :not_rearmable} = Intent.advance(recovered, :rearm)
  end

  test "public observations cannot forge internal mapped or poll authority", c do
    pid = owner(c.opts)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, req}
    eventually(fn -> Intent.status(pid).revision == 3 end)

    no_send =
      completed(req)
      |> Map.drop(["value", "value_schema_id", "value_schema_version"])
      |> Map.merge(%{
        "outcome" => "timed_out",
        "dispatch" => "not_dispatched",
        "error_class" => "retryable"
      })

    for forged <- [
          {:from_adapter, 1, {:mapped, no_send, :forged}},
          {:from_adapter, 1, {:unknown_to_provider, "trusted"}},
          {:from_adapter, 1, {:observed, {:no_effect, "trusted"}}},
          {:mapped, no_send, :forged}
        ] do
      assert {:error, :invalid_observation} = Intent.observe(pid, forged)
      assert {:error, :invalid_observation} = GenServer.call(pid, {:observe, forged})
    end

    assert Intent.status(pid).revision == 3
    assert Intent.status(pid).phase == {:Dispatched, :Fresh, 1}
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
  end

  test "raw Adapter return cannot impersonate the owner's private mapped result", c do
    context = %{
      c.context
      | send: fn req ->
          no_send =
            completed(req)
            |> Map.drop(["value", "value_schema_id", "value_schema_version"])
            |> Map.merge(%{
              "outcome" => "timed_out",
              "dispatch" => "not_dispatched",
              "error_class" => "retryable"
            })

          {:mapped, no_send, :forged}
        end
    }

    pid = owner(Keyword.put(c.opts, :adapter_context, context))
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, _}
    eventually(fn -> Intent.status(pid).revision == 3 end)
    assert Intent.status(pid).phase == {:Dispatched, :Fresh, 1}
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
  end

  test "undeclared and malformed Adapter returns retain refusal but never settlement authority",
       c do
    values = [{:error, :undeclared, :detail}, :junk, %{}, {:observed, {:no_effect, "trusted"}}]

    for {value, i} <- Enum.with_index(values) do
      context = %{c.context | send: fn _ -> value end}

      opts =
        c.opts
        |> Keyword.put(:adapter_context, context)
        |> Keyword.put(:identity, List.replace_at(c.opts[:identity], 4, "invalid-#{i}"))

      pid = owner(opts)
      assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      assert_receive {:physical_send, _, _}
      eventually(fn -> Intent.status(pid).revision == 3 end)
      assert Intent.status(pid).phase == {:Dispatched, :Fresh, 1}
      assert Intent.status(pid).evidence == 1
      assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
    end
  end

  test "F1 saturated refusals cannot starve replay grounding or no-replay stranding", c do
    for {binding_module, expected, label} <- [
          {TestBinding, {:Definite, :ProviderReplaySafe, 1}, "replay"},
          {Elzoo.EffectIntent.TestNoReplayBinding, {:Stranded, 1}, "no-replay"}
        ] do
      {:ok, binding} = Binding.load(binding_module)

      memory =
        start_supervised!(
          Supervisor.child_spec({Memory, fold: Model.fold(binding), limits: Model.limits()},
            id: make_ref()
          )
        )

      context = %{c.context | poll: fn _ -> {:unknown_to_provider, "trusted"} end}

      opts =
        c.opts
        |> Keyword.put(:binding, binding_module)
        |> Keyword.put(:store, Memory.store(memory))
        |> Keyword.put(:identity, List.replace_at(c.opts[:identity], 4, label))
        |> Keyword.put(:adapter_context, context)

      pid = owner(opts)
      assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      assert_receive {:physical_send, _, req}
      eventually(fn -> Intent.status(pid).revision == 3 end)
      invalid = put_in(completed(req), ["value", "digest"], <<0::256>>)
      for _ <- 1..1022, do: assert({:refused, :retained} = Intent.observe(pid, invalid))
      assert {:not_retained, :capacity} = Intent.observe(pid, invalid)
      assert {:ok, :polling} = Intent.advance(pid, :poll)
      eventually(fn -> Intent.status(pid).phase == expected end)
      assert Intent.status(pid).evidence == 1023
      assert Intent.status(pid).active

      recovered =
        Elzoo.Checkpoint.recover(
          Memory.store(memory),
          Model.stream(req.key),
          Model.fold(binding),
          1,
          &Model.decode(&1, binding)
        )

      assert Map.has_key?(recovered.model.evidence, {1, :settlement})
      assert Policy.phase(recovered.model.policy) == expected
    end
  end

  test "F1 saturated refusals reserve a deadline strand and failed grounding halts", c do
    pid = owner(c.opts)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, req}
    eventually(fn -> Intent.status(pid).revision == 3 end)
    invalid = put_in(completed(req), ["value", "digest"], <<0::256>>)
    for _ <- 1..1022, do: assert({:refused, :retained} = Intent.observe(pid, invalid))
    Agent.update(c.clock, fn _ -> 5100 end)
    assert {:ok, :Reconcile} = Intent.advance(pid, :expire)
    assert Intent.status(pid).phase == {:Stranded, 1}
    assert Intent.status(pid).evidence == 1023
    revision = Intent.status(pid).revision
    assert {:ok, _} = Intent.advance(pid, :expire)
    assert Intent.status(pid).revision == revision

    Agent.update(c.clock, fn _ -> 100 end)
    context = %{c.context | poll: fn _ -> {:unknown_to_provider, "trusted"} end}

    opts =
      c.opts
      |> Keyword.put(:identity, List.replace_at(c.opts[:identity], 4, "failed-ground"))
      |> Keyword.put(:adapter_context, context)

    second = owner(opts)
    assert {:ok, :dispatched} = Intent.advance(second, :dispatch)
    assert_receive {:physical_send, _, _}
    eventually(fn -> Intent.status(second).revision == 3 end)
    :ok = Memory.fault(c.store, :append, :unavailable)
    assert {:ok, :polling} = Intent.advance(second, :poll)
    eventually(fn -> not Intent.status(second).active end)
    assert Intent.status(second).phase == {:Dispatched, :Fresh, 1}
    assert {:error, :read_only} = Intent.advance(second, :rearm)
  end

  defp wait_intent_tasks(pid, remaining \\ 1000)
  defp wait_intent_tasks(pid, 0), do: assert(map_size(:sys.get_state(pid).tasks) == 0)

  defp wait_intent_tasks(pid, remaining) do
    if map_size(:sys.get_state(pid).tasks) == 0 do
      :ok
    else
      Process.sleep(1)
      wait_intent_tasks(pid, remaining - 1)
    end
  end

  @tag timeout: 120_000
  test "F1 4090 pending polls preserve replay, another reservation and recovery expiry", c do
    response =
      start_supervised!(Supervisor.child_spec({Agent, fn -> :pending end}, id: :poll_response))

    context = %{c.context | poll: fn _ -> {Agent.get(response, & &1), "trusted"} end}
    pid = owner(Keyword.put(c.opts, :adapter_context, context))
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, req}
    eventually(fn -> Intent.status(pid).revision == 3 end)
    for _ <- 1..100, do: assert({:ok, _} = Intent.advance(pid, :expire))
    assert Intent.status(pid).revision == 3

    for _ <- 1..4090 do
      assert {:ok, :polling} = Intent.advance(pid, :poll)
      assert_receive {:physical_poll, _, _}
      wait_intent_tasks(pid)
    end

    assert Intent.status(pid).revision < 2000

    snapshot =
      Elzoo.Checkpoint.recover(
        c.store,
        Model.stream(req.key),
        Model.fold(c.binding),
        1,
        &Model.decode(&1, c.binding)
      )

    assert snapshot.model.pending + snapshot.model.unavailable == Model.routine_budget()

    timeout =
      completed(req)
      |> Map.drop(["value", "value_schema_id", "value_schema_version"])
      |> Map.merge(%{
        "outcome" => "timed_out",
        "dispatch" => "unknown",
        "error_class" => "retryable"
      })

    assert {:not_retained, :routine_budget} = Intent.observe(pid, timeout)
    Agent.update(response, fn _ -> :unknown_to_provider end)
    assert {:ok, :polling} = Intent.advance(pid, :poll)
    eventually(fn -> Intent.status(pid).phase == {:Definite, :ProviderReplaySafe, 1} end)
    assert {:ok, :Stop} = Intent.advance(pid, :rearm)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, second}
    assert second.key == req.key
    wait_intent_tasks(pid)
    Agent.update(c.clock, fn _ -> 5100 end)
    assert {:ok, :Reconcile} = Intent.advance(pid, :expire)
    assert Intent.status(pid).phase == {:Stranded, 2}
    GenServer.stop(pid)
    recovered = owner(Keyword.put(c.opts, :adapter_context, context))
    assert Intent.status(recovered).phase == {:Stranded, 2}
    refute Intent.status(recovered).active
  end

  test "F2 public no-send during an in-flight no-replay send cannot settle or dispatch again", c do
    {:ok, binding} = Binding.load(Elzoo.EffectIntent.TestNoReplayBinding)

    memory =
      start_supervised!(
        Supervisor.child_spec({Memory, fold: Model.fold(binding), limits: Model.limits()},
          id: :f2_no_replay
        )
      )

    context = %{
      c.context
      | send: fn _ ->
          receive do
            :attested_no_send -> {:error, :no_send, :attested_no_bytes}
          end
        end
    }

    opts =
      c.opts
      |> Keyword.put(:binding, Elzoo.EffectIntent.TestNoReplayBinding)
      |> Keyword.put(:store, Memory.store(memory))
      |> Keyword.put(:adapter_context, context)

    pid = owner(opts)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, send_task, req}
    assert Process.alive?(send_task)

    no_send =
      completed(req)
      |> Map.drop(["value", "value_schema_id", "value_schema_version"])
      |> Map.merge(%{
        "outcome" => "timed_out",
        "dispatch" => "not_dispatched",
        "error_class" => "retryable"
      })

    # Preserve the formerly accepted public case as an explicit refusal control.
    assert {:refused, :retained} = Intent.observe(pid, no_send)
    assert Intent.status(pid).phase == {:Dispatched, :Fresh, 1}
    assert Intent.status(pid).evidence == 1
    assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
    assert {:error, :not_dispatchable} = Intent.advance(pid, :dispatch)
    assert Process.alive?(send_task)
    refute_receive {:physical_send, _, _}, 20

    # Only the declared, attested typed return from that send grants no-send.
    send(send_task, :attested_no_send)
    eventually(fn -> Intent.status(pid).phase == {:Definite, :AdapterNoSend, 1} end)
    wait_intent_tasks(pid)
    refute Process.alive?(send_task)
    assert {:ok, :Stop} = Intent.advance(pid, :rearm)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, second_task, second}
    assert second.key == req.key
    assert second.arguments_digest == req.arguments_digest
    assert second.attempt == 2
    refute second.attempt_id == req.attempt_id
    send(second_task, :attested_no_send)
    eventually(fn -> Intent.status(pid).phase == {:Definite, :AdapterNoSend, 2} end)
  end

  test "F2 raw send and poll no-send Envelopes never confer typed send authority", c do
    no_send = fn req ->
      completed(req)
      |> Map.drop(["value", "value_schema_id", "value_schema_version"])
      |> Map.merge(%{
        "outcome" => "timed_out",
        "dispatch" => "not_dispatched",
        "error_class" => "retryable"
      })
    end

    for source <- [:send, :poll] do
      context = Map.put(c.context, source, no_send)

      opts =
        c.opts
        |> Keyword.put(:adapter_context, context)
        |> Keyword.put(:identity, List.replace_at(c.opts[:identity], 4, "f2-#{source}"))

      pid = owner(opts)
      assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      assert_receive {:physical_send, _, _}
      wait_intent_tasks(pid)

      if source == :poll do
        assert {:ok, :polling} = Intent.advance(pid, :poll)
        assert_receive {:physical_poll, _, _}
        wait_intent_tasks(pid)
      end

      assert Intent.status(pid).phase == {:Dispatched, :Fresh, 1}
      assert Intent.status(pid).evidence == 1
      assert {:error, :not_rearmable} = Intent.advance(pid, :rearm)
      assert {:error, :not_dispatchable} = Intent.advance(pid, :dispatch)
      refute_receive {:physical_send, _, _}, 20
    end
  end
end
