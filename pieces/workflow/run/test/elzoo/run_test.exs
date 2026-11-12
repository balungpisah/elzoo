# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_test_helper.exs", __DIR__)
Code.require_file("../../examples/run.exs", __DIR__)

defmodule Elzoo.RunTest do
  use ExUnit.Case, async: false
  import Elzoo.Run.TestHelper
  alias Elzoo.{Run, Approval, Lease}
  alias Elzoo.DurableLog.{Store, PostgresHarness}

  setup do
    c = Elzoo.Run.TestHelper.setup()
    on_exit(fn -> Elzoo.Run.TestHelper.cleanup(c) end)
    c
  end

  test "Restart/identity: explicit execution retry, stale commands and durable completion", c do
    p = owner(c)
    create(p, c)
    first = snapshot(p)
    p = restart(c, p)
    assert snapshot(p) == first
    assert {:ok, _, "attempt-2"} = command(p, :begin_attempt, %{attempt_id: "attempt-2"})
    assert snapshot(p).operation_id == first.operation_id
    assert snapshot(p).provider_refs == first.provider_refs
    rev = snapshot(p).revision

    for kind <- [:cancel, :complete] do
      fields =
        if kind == :complete, do: %{outcome: :completed, reason: nil, evidence_ref: nil}, else: %{}

      assert {:unchanged, :stale, ^rev} =
               command(p, kind, Map.merge(fields, %{attempt_id: "attempt-1", expected_revision: 0}))
    end

    assert {:unchanged, :stale, ^rev} =
             command(p, :begin_attempt, %{attempt_id: "attempt-1", expected_revision: 0})

    assert {:unchanged, :stale, ^rev} =
             command(p, :cancel, %{attempt_id: "unknown-attempt", expected_revision: 0})

    assert {:unchanged, :stale, ^rev} =
             command(p, :effect_result, %{
               attempt_id: "attempt-1",
               action_id: "old-action",
               intent_key: "old-intent",
               evidence_ref: nil,
               expected_revision: 0
             })

    assert {:ok, %{revision: ^rev}} = Store.read(c.store, :head, ["runs"])

    assert {:refused, :conflict} =
             command(p, :cancel, %{attempt_id: "attempt-2", expected_revision: 0})

    assert {:refused, :invalid_command} =
             command(p, :cancel, %{attempt_id: "attempt-2", extra: "secret"})

    assert {:refused, :completion_evidence} =
             command(p, :complete, %{
               attempt_id: "attempt-2",
               outcome: :completed,
               reason: nil,
               evidence_ref: nil
             })

    ref =
      committed_evidence(c, %{
        run_id: "run",
        operation_id: "operation",
        attempt_id: "attempt-2",
        action_id: "work"
      })

    completion = %{attempt_id: "attempt-2", outcome: :completed, reason: nil, evidence_ref: ref}
    assert {:ok, _, :completed} = command(p, :complete, completion)
    rev = snapshot(p).revision

    assert {:unchanged, :duplicate, ^rev} =
             command(p, :complete, Map.put(completion, :expected_revision, 0))

    assert {:ok, %{revision: ^rev}} = Store.read(c.store, :head, ["runs"])
    assert {:refused, :terminal_conflict} = command(p, :complete, %{completion | outcome: :failed})
    assert snapshot(restart(c, p)).outcome == :completed
    assert Run.classify_attempt(nil, nil) == :stale
    assert Run.classify_attempt("valid", "valid") == :current
    assert Run.classify_attempt("old", "new") == :stale
  end

  test "Restart/identity: indeterminate cancellation stops ownership until confirmation", c do
    p = owner(c)
    create(p, c)
    ref = Process.monitor(p)
    fault(c, :append, "runs", snapshot(p).revision, :reply_loss)
    assert {:indeterminate, receipt} = command(p, :cancel, %{attempt_id: "attempt-1"})
    assert_receive {:DOWN, ^ref, :process, ^p, {:shutdown, {:indeterminate, _}}}
    assert {:committed, _} = Lease.confirm(c.lease, receipt)
    p = owner(c, Keyword.put(c.opts, :reconcile, receipt))
    assert snapshot(p).outcome == :cancelled
    assert {:unchanged, :terminal, _} = command(p, :begin_attempt, %{attempt_id: "attempt-2"})

    # A pending real Store write is unknown, not absent/no-write permission.
    create(p, c, "other")
    uncertain = PostgresHarness.attach(c.repo, c.prefix, Run.fold(), Run.limits(), c.controller)
    {:ok, lease} = Lease.new(store: uncertain, clock: :store)
    p = restart(c, p, Keyword.merge(c.opts, store: uncertain, lease: lease))
    :ok = PostgresHarness.hook(uncertain, :inject, [:append, {:pause, :cancel}])
    assert {:indeterminate, pending} = command(p, :cancel, %{attempt_id: "attempt-1"}, "other")
    assert {:unknown, _} = Lease.confirm(lease, pending)
    {:held, held} = Lease.hold(lease, "runs", "owner")
    Process.flag(:trap_exit, true)

    assert {:error, :unreconciled_or_invalid_startup} =
             Run.start_link(
               Keyword.merge(c.opts, store: uncertain, lease: lease, held: held, reconcile: pending)
             )

    assert {:committed, _} = PostgresHarness.hook(uncertain, :release, [:cancel])
    assert {:committed, _} = Lease.confirm(lease, pending)
  end

  test "Children: reciprocal atomic attachment, DOWN is not success, lost wakeup replay", c do
    p = owner(c)
    create(p, c)
    create(p, c, "child")

    child =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    rev = snapshot(p).revision
    attach = %{attempt_id: "attempt-1", child_run_id: "child", child_pid: child}
    assert {:ok, next, "child"} = command(p, :attach_child, attach)
    assert next == rev + 1
    assert snapshot(p, "child").parent == %{run_id: "run", attempt_id: "attempt-1"}
    assert snapshot(p).children["child"].settled == nil

    assert {:unchanged, :duplicate, ^next} =
             command(p, :attach_child, Map.put(attach, :expected_revision, 0))

    send(child, :stop)
    eventually(fn -> snapshot(p).children["child"].dead end)
    assert snapshot(p, "child").outcome == nil

    assert {:refused, :child_completion} =
             command(p, :child_result, %{
               attempt_id: "attempt-1",
               child_run_id: "child",
               child_completion_revision: next
             })

    assert {:ok, completion, :failed} =
             command(
               p,
               :complete,
               %{
                 attempt_id: "attempt-1",
                 outcome: :failed,
                 reason: "child_failed",
                 evidence_ref: nil
               },
               "child"
             )

    assert snapshot(p).children["child"].pending == completion
    p = restart(c, p)
    assert snapshot(p).children["child"].settled == completion
    rev = snapshot(p).revision

    assert {:unchanged, :duplicate, ^rev} =
             command(p, :child_result, %{
               attempt_id: "attempt-1",
               child_run_id: "child",
               child_completion_revision: completion
             })

    create(p, c, "old-parent-child")

    assert {:ok, _, _} =
             command(p, :attach_child, %{
               attempt_id: "attempt-1",
               child_run_id: "old-parent-child",
               child_pid: nil
             })

    assert {:ok, _, _} = command(p, :begin_attempt, %{attempt_id: "attempt-2"})

    assert {:ok, old_completion, _} =
             command(
               p,
               :complete,
               %{attempt_id: "attempt-1", outcome: :failed, reason: nil, evidence_ref: nil},
               "old-parent-child"
             )

    assert {:unchanged, :stale, _} =
             command(p, :child_result, %{
               attempt_id: "attempt-1",
               child_run_id: "old-parent-child",
               child_completion_revision: old_completion
             })

    p = restart(c, p)
    assert snapshot(p).children["old-parent-child"].settled == nil
    assert snapshot(p).children["old-parent-child"].pending == old_completion
  end

  test "Children: unknown spawn/cancel keeps the stable intent and never replaces it", c do
    p = owner(c)
    create(p, c)
    {key, ctx} = request(p)
    approve(p, key)
    spawn_intent = %{intent() | arguments: "spawn-child"}

    assert {:ok, _, %{classification: :dispatched, intent_key: stable}} =
             dispatch(p, key, ctx, spawn_intent)

    assert_receive {:send_started, task, req}
    send(task, :send)
    assert_receive {:physical_send, ^req}
    recover(c)
    p = restart(c, p)

    assert {:ok, _, %{classification: :unknown, intent_key: ^stable}} =
             dispatch(p, key, ctx, spawn_intent)

    assert {:refused, :intent_mismatch} =
             dispatch(p, key, ctx, %{spawn_intent | arguments: "replacement-child"})

    assert {:ok, _, :cancelled} = command(p, :cancel, %{attempt_id: "attempt-1"})
    assert snapshot(p).children == %{}
    assert snapshot(p).effects["action"].intent_key == stable
    refute_receive {:send_started, _, _}, 10
  end

  for scope <- [:once, :run, :root] do
    @scope scope
    test "Open approval: #{@scope} restart without evidence never invents consent", c do
      p = owner(c)
      create(p, c)
      {key, ctx} = request(p, @scope)
      before = history(c)
      p = restart(c, p)
      assert history(c) == before

      assert {:ok, _, %{classification: :waiting_approval, reason: :no_retained_consent}} =
               dispatch(p, key, ctx)

      assert Approval.inspect_state(approval_state(c)).releases == []
      refute_receive {:send_started, _, _}, 10
    end

    test "Before release commit: stored #{@scope} evidence releases after restart", c do
      p = owner(c)
      create(p, c)
      {key, ctx} = request(p, @scope)
      approve(p, key, @scope)
      p = restart(c, p)
      assert {:ok, _, %{classification: :dispatched}} = dispatch(p, key, ctx)
      assert_receive {:send_started, task, req}
      assert req.arguments == "canonical"
      send(task, :send)
      assert_receive {:physical_send, ^req}
      release_before_intent!(c)
    end
  end

  for {name, ctx} <- [expired: %{now: 20_000, max_age: 50_000}, evidence_too_old: %{now: 11_000}] do
    @reason name
    @override ctx
    test "Before release commit: stored fresh evidence refuses #{@reason}", c do
      p = owner(c)
      create(p, c)
      {key, ctx} = request(p)
      approve(p, key)
      p = restart(c, p)
      assert {:refused, @reason} = dispatch(p, key, Map.merge(ctx, @override))
      refute_receive {:send_started, _, _}, 10
      assert Approval.inspect_state(approval_state(c)).releases == []
    end
  end

  test "Before release commit: uncertain release is reconciled before admission", c do
    p = owner(c)
    create(p, c)
    {key, ctx} = request(p)
    approve(p, key)
    # First append binds the intent; the following append is the release barrier.
    fault(c, :append, "runs", snapshot(p).revision + 1, :reply_loss)
    assert {:indeterminate, receipt} = dispatch(p, key, ctx)
    refute_receive {:send_started, _, _}, 10
    assert {:committed, _} = Lease.confirm(c.lease, receipt)
    p = owner(c, Keyword.put(c.opts, :reconcile, receipt))
    assert {:ok, _, %{classification: :dispatched}} = dispatch(p, key, ctx)
    assert_receive {:send_started, _, _}
    assert length(Approval.inspect_state(approval_state(c)).releases) == 1
    release_before_intent!(c)
  end

  test "Release before intent: durable release, stable identity and exactly one first send", c do
    p = owner(c)
    create(p, c)
    {key, ctx} = request(p)
    approve(p, key)
    fault(c, :append, intent_stream(), 0, :unavailable)
    assert {:ok, _, %{classification: :reconciliation_required}} = dispatch(p, key, ctx)
    refute_receive {:send_started, _, _}, 10
    assert length(Approval.inspect_state(approval_state(c)).releases) == 1
    recover(c)
    p = restart(c, p)

    assert {:refused, :intent_mismatch} =
             dispatch(p, key, ctx, %{
               intent()
               | identity: ["tenant", "account", "adapter", "send", "replacement"]
             })

    assert {:refused, :intent_mismatch} = dispatch(p, key, ctx, %{intent() | arguments: "drift"})
    assert {:ok, _, %{classification: :dispatched, intent_key: intent_key}} = dispatch(p, key, ctx)
    assert_receive {:send_started, task, req}
    assert req.key == intent_key and req.arguments == "canonical"
    assert {:ok, _, %{classification: :unknown}} = dispatch(p, key, ctx)
    refute_receive {:send_started, _, _}, 10
    send(task, :send)
    assert_receive {:physical_send, ^req}
    release_before_intent!(c)
  end

  test "Zero attempts: admission crash, read-only replacement and fenced first dispatch", c do
    p = owner(c)
    create(p, c)
    {key, ctx} = request(p)
    approve(p, key)
    fault(c, :append, intent_stream(), 1, :unavailable)
    assert {:ok, _, %{classification: :unknown}} = dispatch(p, key, ctx)
    refute_receive {:send_started, _, _}, 10
    p = restart(c, p)
    assert {:ok, _, %{classification: :reconciliation_required}} = dispatch(p, key, ctx)
    recover(c)
    p = restart(c, p)
    assert {:ok, _, %{classification: :dispatched}} = dispatch(p, key, ctx)
    assert_receive {:send_started, _, req}
    assert req.attempt == 1
    assert {:ok, _, %{classification: :unknown}} = dispatch(p, key, ctx)
    refute_receive {:send_started, _, _}, 10
  end

  for {name, args, now} <- [{:expired, "canonical", 10_000}, {:schema, "bad", 2000}] do
    @reason name
    @args args
    @now now
    test "Zero attempts: #{@reason} is durable not-sent without reservation", c do
      Agent.update(c.control, &Map.put(&1, :now, @now))
      p = owner(c)
      create(p, c)
      {key, ctx} = request(p)
      approve(p, key)

      assert {:ok, _, %{classification: :not_sent, reason: @reason}} =
               dispatch(p, key, ctx, %{intent() | arguments: @args})

      refute_receive {:send_started, _, _}, 10
      recover(c)
      p = restart(c, p)

      assert {:ok, _, %{classification: :not_sent}} =
               dispatch(p, key, ctx, %{intent() | arguments: @args})

      refute_receive {:send_started, _, _}, 10
    end
  end

  test "Reserved/send windows: crash before launch never permits replacement or retry", c do
    p = owner(c)
    create(p, c)
    {key, ctx} = request(p)
    approve(p, key)
    # Real reservation commits before the checkpoint/launch barrier loses its reply.
    fault(c, :put_checkpoint, intent_stream(), 2, :reply_loss)
    assert {:ok, _, %{classification: :unknown}} = dispatch(p, key, ctx)
    refute_receive {:send_started, _, _}, 10
    recover(c)
    p = restart(c, p)
    assert {:ok, _, %{classification: :unknown, reason: :reserved}} = dispatch(p, key, ctx)
    assert {:ok, _, :cancelled} = command(p, :cancel, %{attempt_id: "attempt-1"})
    assert snapshot(p).effects["action"].classification == :unknown
    refute_receive {:send_started, _, _}, 10
  end

  test "Reserved/send windows: delayed old send after cancellation/death stays unknown", c do
    p = owner(c)
    create(p, c)
    {key, ctx} = request(p)
    approve(p, key)
    assert {:ok, _, %{classification: :dispatched}} = dispatch(p, key, ctx)
    assert_receive {:send_started, task, req}
    assert {:ok, _, :cancelled} = command(p, :cancel, %{attempt_id: "attempt-1"})
    GenServer.stop(p)
    send(task, :send)
    assert_receive {:physical_send, ^req}
    recover(c)
    p = owner(c)
    assert snapshot(p).outcome == :cancelled
    assert snapshot(p).effects["action"].classification == :unknown
    assert {:unchanged, :terminal, _} = dispatch(p, key, ctx)
    refute_receive {:send_started, _, _}, 10

    ref =
      committed_evidence(c, %{
        run_id: "run",
        attempt_id: "attempt-1",
        action_id: "action",
        intent_key: req.key,
        classification: :settled
      })

    assert {:ok, _, %{classification: :settled}} =
             command(p, :effect_result, %{
               attempt_id: "attempt-1",
               action_id: "action",
               intent_key: req.key,
               evidence_ref: ref
             })

    assert snapshot(p).outcome == :cancelled
    assert snapshot(restart(c, p)).effects["action"].classification == :settled
  end

  test "Reserved/send windows: sent before outcome retention stays unknown after time expiry", c do
    p = owner(c)
    create(p, c)
    {key, ctx} = request(p)
    approve(p, key)
    assert {:ok, _, %{classification: :dispatched}} = dispatch(p, key, ctx)
    assert_receive {:send_started, task, req}
    fault(c, :append, intent_stream(), 2, :unavailable)
    send(task, :send)
    assert_receive {:physical_send, ^req}
    # A barrier on status waits for the ready owner's attempted retention.
    eventually(fn ->
      Enum.any?(history(c), fn {op, stream, _, _, result} ->
        op == :append and stream == intent_stream() and match?({:indeterminate, _}, result)
      end)
    end)

    recover(c)
    p = restart(c, p)
    assert {:ok, _, %{classification: :unknown}} = dispatch(p, key, ctx)

    assert {:ok, _, :out_of_time} =
             command(p, :complete, %{
               attempt_id: "attempt-1",
               outcome: :out_of_time,
               reason: nil,
               evidence_ref: nil
             })

    assert snapshot(p).effects["action"].classification == :unknown
    refute_receive {:send_started, _, _}, 10
  end

  for reason <- [
        :policy_changed,
        :requirement_changed,
        :payload_changed,
        :deny_at_release,
        :approver_not_authorized,
        :expired,
        :evidence_too_old,
        :revoked,
        :unavailable_context
      ] do
    @reason reason
    test "Bypass matrix: recorded release rejects #{@reason} without a new send", c do
      p = owner(c)
      create(p, c)
      {key, ctx} = request(p)
      approve(p, key)
      fault(c, :append, intent_stream(), 0, :unavailable)
      assert {:ok, _, %{classification: :reconciliation_required}} = dispatch(p, key, ctx)
      p = restart(c, p)

      ctx =
        case @reason do
          :policy_changed ->
            put_in(ctx.policy.version, 2)

          :requirement_changed ->
            put_in(ctx.policy.rules, [
              %{hd(ctx.policy.rules) | requirement: %{name: "other", version: 1, scope: :once}}
            ])

          :payload_changed ->
            put_in(ctx.proposal.payload, {:text, "different"})

          :deny_at_release ->
            put_in(ctx.policy.rules, [
              %{id: "deny", effect_class: "publish", verdict: :deny}
            ])

          :approver_not_authorized ->
            put_in(ctx.approver.authority, [])

          :expired ->
            %{ctx | now: 20_000, max_age: 50_000}

          :evidence_too_old ->
            %{ctx | now: 11_000}

          :revoked ->
            assert {:ok, _, _} =
                     command(p, :approval_evidence, %{
                       attempt_id: "attempt-1",
                       request_key: key,
                       revoked_evidence_key: {"verifier", "evidence"}
                     })

            ctx

          :unavailable_context ->
            Map.delete(ctx, :policy)
        end

      assert_refusal(@reason, dispatch(p, key, ctx))

      refute_receive {:send_started, _, _}, 10
      assert {:ok, %{revision: 0}} = Store.read(c.intent_store, :head, [intent_stream()])
    end
  end

  test "Bypass matrix: already_released is not dispatch permission; retained requires selection",
       c do
    p = owner(c)
    create(p, c)
    {key, ctx} = request(p, :run)
    approve(p, key, :run)
    fault(c, :append, intent_stream(), 0, :unavailable)
    assert {:ok, _, %{classification: :reconciliation_required}} = dispatch(p, key, ctx)
    state = approval_state(c)

    assert {:refused, :already_released, ^state} =
             Approval.release(state, key, evidence(key, :run), ctx)

    assert {:refused, :expired} = dispatch(p, key, %{ctx | now: 20_000, max_age: 50_000})
    {key2, _} = request(p, :run)
    assert key2 != key

    assert {:refused, :no_retained_consent} =
             Approval.select_retained(approval_state(c), key2, %{ctx | now: 20_000, max_age: 50_000})

    assert {:ok, _, %{classification: :waiting_approval, reason: :no_retained_consent}} =
             dispatch(p, key2, %{ctx | now: 20_000, max_age: 50_000})

    recover(c)
    p = restart(c, p)
    assert {:ok, _, %{classification: :dispatched}} = dispatch(p, key2, ctx)
    assert_receive {:send_started, _, _}
    assert length(Approval.inspect_state(approval_state(c)).consents) == 1
  end

  test "Outcomes/example: five terminal outcomes, durable correlation and late effects", c do
    p = owner(c)
    create(p, c)

    assert Elzoo.Run.Example.complete(p, %{stream: "missing", sequence: 1}) ==
             {:refused, :completion_evidence}

    wrong =
      committed_evidence(c, %{
        run_id: "wrong",
        operation_id: "operation",
        attempt_id: "attempt-1",
        action_id: "work"
      })

    assert {:refused, :completion_evidence} = Elzoo.Run.Example.complete(p, wrong)

    ref =
      committed_evidence(c, %{
        run_id: "run",
        operation_id: "operation",
        attempt_id: "attempt-1",
        action_id: "work"
      })

    assert {:ok, _, :completed} = Elzoo.Run.Example.complete(p, ref)

    for outcome <- [:failed, :cancelled, :out_of_budget, :out_of_time] do
      id = Atom.to_string(outcome)
      create(p, c, id)
      assert Run.outcome?(outcome)

      assert {:ok, _, ^outcome} =
               command(
                 p,
                 :complete,
                 %{attempt_id: "attempt-1", outcome: outcome, reason: nil, evidence_ref: nil},
                 id
               )
    end

    for action_class <- [
          :unknown,
          :late,
          :expired,
          :refused,
          :resource_lost,
          :retries_exhausted,
          :waiting,
          :paused
        ],
        do: refute(Run.outcome?(action_class))
  end

  defp assert_refusal(:deny_at_release, result),
    do: assert(match?({:refused, {:deny_at_release, _}}, result))

  defp assert_refusal(:unavailable_context, result),
    do: assert(match?({:error, {:unavailable_context, _}}, result))

  defp assert_refusal(reason, result), do: assert(result == {:refused, reason})

  defp eventually(fun, attempts \\ 100)
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
end
