# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_approval_release_test_helper.exs", __DIR__)
Code.require_file("../../examples/run_approval_release.exs", __DIR__)

defmodule Elzoo.RunApprovalReleaseTest do
  use ExUnit.Case, async: false
  import Elzoo.RunApprovalRelease.TestHelper
  alias Elzoo.{Approval, Lease}
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.DurableLog.{Store, PostgresHarness}

  setup do
    c = Elzoo.RunApprovalRelease.TestHelper.setup()
    on_exit(fn -> Elzoo.RunApprovalRelease.TestHelper.cleanup(c) end)
    c
  end

  test "Restart/identity: explicit execution retry, stale commands and durable completion", c do
    p = owner(c)
    create(p, c)
    {key, ctx} = request(p)
    {:ok, decision} = Elzoo.Authorization.decide(ctx.policy, ctx.proposal, ctx.authority)
    first = snapshot(p)

    assert {:unchanged, :duplicate, revision} =
             command(p, :approval_request, %{
               attempt_id: "attempt-1",
               decision: decision,
               expected_revision: 0
             })

    assert revision == first.revision
    assert {:ok, %{revision: ^revision}} = Store.read(c.store, :head, ["runs"])
    p = restart(c, p)
    assert snapshot(p) == first
    assert {:ok, _, "attempt-2"} = command(p, :begin_attempt, %{attempt_id: "attempt-2"})
    assert snapshot(p).operation_id == first.operation_id
    assert snapshot(p).provider_refs == first.provider_refs

    assert {:refused, :conflict} =
             command(p, :approval_request, %{
               attempt_id: "attempt-2",
               decision: decision,
               expected_revision: 0
             })

    assert {:ok, _, ^key} =
             command(p, :approval_request, %{attempt_id: "attempt-2", decision: decision})

    p = restart(c, p)
    assert snapshot(p).approvals == first.approvals
    assert Approval.inspect_state(approval_state(c)).releases == []

    assert {:unchanged, :duplicate, revision} =
             command(p, :approval_request, %{
               attempt_id: "attempt-2",
               decision: decision,
               expected_revision: 0
             })

    assert {:ok, %{revision: ^revision}} = Store.read(c.store, :head, ["runs"])

    assert {:unchanged, :stale, ^revision} =
             command(p, :approval_evidence, %{
               attempt_id: "attempt-1",
               request_key: key,
               evidence: evidence(key)
             })

    assert {:unchanged, :stale, ^revision} = dispatch(p, key, ctx)

    assert {:ok, _, ^key} =
             command(p, :approval_evidence, %{
               attempt_id: "attempt-2",
               request_key: key,
               evidence: evidence(key)
             })

    p = restart(c, p)

    assert {:ok, _, %{classification: :dispatched}} =
             command(p, :dispatch_approved, %{
               attempt_id: "attempt-2",
               request_key: key,
               context: ctx,
               intent: intent()
             })

    assert_receive {:send_started, _, _}
    assert length(Approval.inspect_state(approval_state(c)).releases) == 1
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

      assert {:ok, _, "attempt-2"} = command(p, :begin_attempt, %{attempt_id: "attempt-2"})
      p = restart(c, p)
      revision = snapshot(p).revision
      {:ok, decision} = Elzoo.Authorization.decide(ctx.policy, ctx.proposal, ctx.authority)

      assert {:refused, :intent_mismatch} =
               command(p, :approval_request, %{attempt_id: "attempt-2", decision: decision})

      assert {:refused, :unknown_request} =
               command(p, :dispatch_approved, %{
                 attempt_id: "attempt-2",
                 request_key: key,
                 context: ctx,
                 intent: intent()
               })

      assert {:ok, %{revision: ^revision}} = Store.read(c.store, :head, ["runs"])
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

    bindings =
      Map.update!(c.opts[:effect_intent], "binding", fn opts ->
        Keyword.put(opts, :binding, Elzoo.RunApprovalRelease.ChangedTestBinding)
      end)

    p = restart(c, p, Keyword.put(c.opts, :effect_intent, bindings))
    before = history(c)
    assert {:refused, :intent_mismatch} = dispatch(p, key, ctx)
    assert history(c) == before
    refute_receive {:send_started, _, _}, 10
    assert {:ok, %{revision: 0}} = Store.read(c.intent_store, :head, [intent_stream()])
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

    assert Elzoo.RunApprovalRelease.Example.complete(p, %{stream: "missing", sequence: 1}) ==
             {:refused, :completion_evidence}

    wrong =
      committed_evidence(c, %{
        run_id: "wrong",
        operation_id: "operation",
        attempt_id: "attempt-1",
        action_id: "work"
      })

    assert {:refused, :completion_evidence} = Elzoo.RunApprovalRelease.Example.complete(p, wrong)

    ref =
      committed_evidence(c, %{
        run_id: "run",
        operation_id: "operation",
        attempt_id: "attempt-1",
        action_id: "work"
      })

    assert {:ok, _, :completed} = Elzoo.RunApprovalRelease.Example.complete(p, ref)

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

  for scope <- [:once, :run, :root], bindings? <- [false, true] do
    @scope scope
    @bindings bindings?
    test "Release without dispatch: #{@scope}, executable bindings #{@bindings}", c do
      opts = if @bindings, do: c.opts, else: Keyword.put(c.opts, :effect_intent, %{})
      p = owner(c, opts)
      trace_effect_work(p)
      create(p, c)
      {key, ctx} = request(p, @scope)
      approve(p, key, @scope)
      revision = snapshot(p).revision
      assert {:ok, released, %{approval: :released, request_key: ^key}} = release(p, key, ctx)
      # Recover from SQL, rather than trusting the reply or the live owner's state.
      p = restart(c, p, opts)
      trace_effect_work(p)
      assert [%{key: ^key}] = Approval.inspect_state(approval_state(c)).releases
      assert released == revision + 1
      assert {:ok, %{revision: ^released}} = Store.read(c.store, :head, ["runs"])
      assert snapshot(p).effects == %{}
      assert {:ok, ^released, %{approval: :released}} = release(p, key, ctx)
      assert {:refused, :conflict} = release(p, key, ctx, %{expected_revision: revision})
      assert length(Approval.inspect_state(approval_state(c)).releases) == 1
      no_effect_work(c, p)
    end
  end

  test "Release without dispatch: exact request, current Attempt and ASK only", c do
    p = owner(c)
    create(p, c)
    {key, ctx} = request(p)
    approve(p, key)
    assert {:refused, :unknown_request} = release(p, put_elem(key, 4, 999), ctx)

    assert {:refused, :payload_changed} =
             release(p, key, put_in(ctx.proposal.payload, {:text, "drift"}))

    assert {:refused, :invalid_command} = release(p, key, ctx, %{intent: intent()})
    allow = put_in(ctx.policy.rules, [%{id: "allow", effect_class: "publish", verdict: :allow}])
    {:ok, decision} = Elzoo.Authorization.decide(allow.policy, allow.proposal, allow.authority)

    assert {:error, {:invalid_input, :not_ask}} =
             command(p, :approval_request, %{attempt_id: "attempt-1", decision: decision})

    assert {:ok, _, _} = command(p, :begin_attempt, %{attempt_id: "attempt-2"})
    assert {:refused, :unknown_request} = release(p, key, ctx, %{attempt_id: "attempt-2"})
    assert Approval.inspect_state(approval_state(c)).releases == []
  end

  for scope <- [:once, :run, :root] do
    @scope scope
    test "Waiting and retained consent: #{@scope} selection and restart", c do
      p = owner(c)
      create(p, c)
      {key, ctx} = request(p, @scope)
      revision = snapshot(p).revision
      assert {:ok, ^revision, %{approval: :waiting, request_key: ^key}} = release(p, key, ctx)
      p = restart(c, p)
      assert {:ok, ^revision, %{approval: :waiting}} = release(p, key, ctx)
      approve(p, key, @scope)
      assert {:ok, _, %{approval: :released}} = release(p, key, ctx)
      {next, _} = request(p, @scope)
      assert next != key
      p = restart(c, p)

      if @scope == :once do
        assert {:ok, _, %{approval: :waiting}} = release(p, next, ctx)
      else
        assert {:refused, :approver_not_authorized} =
                 release(p, next, put_in(ctx.approver.authority, []))

        assert {:ok, _, %{approval: :released}} = release(p, next, ctx)
        assert length(Approval.inspect_state(approval_state(c)).consents) == 1
      end

      refute_receive {:send_started, _, _}, 0
    end
  end

  for reason <- [
        :rejected_by_reviewer,
        :revoked,
        :expired,
        :run_mismatch,
        :self_approval,
        :unavailable_context
      ] do
    @reason reason
    test "Waiting and retained consent: fresh evidence preserves #{@reason}", c do
      p = owner(c)
      create(p, c)
      {key, ctx} = request(p)

      ev =
        case @reason do
          :rejected_by_reviewer -> %{evidence(key) | decision: :reject}
          :self_approval -> %{evidence(key) | reviewer: "agent"}
          _ -> evidence(key)
        end

      if @reason == :run_mismatch do
        assert {:refused, :invalid_evidence} =
                 command(p, :approval_evidence, %{
                   attempt_id: "attempt-1",
                   request_key: key,
                   evidence: %{ev | request: put_elem(key, 4, 999)}
                 })
      end

      assert {:ok, _, _} =
               command(p, :approval_evidence, %{
                 attempt_id: "attempt-1",
                 request_key: key,
                 evidence: ev
               })

      ctx =
        case @reason do
          :revoked ->
            assert {:ok, _, _} =
                     command(p, :approval_evidence, %{
                       attempt_id: "attempt-1",
                       request_key: key,
                       revoked_evidence_key: {"verifier", "evidence"}
                     })

            ctx

          :expired ->
            %{ctx | now: 20_000, max_age: 50_000}

          :self_approval ->
            put_in(ctx.approver.identity, "agent")

          :unavailable_context ->
            Map.delete(ctx, :policy)

          :run_mismatch ->
            put_in(ctx.run.id, "another-run")

          _ ->
            ctx
        end

      assert_refusal(@reason, release(p, key, ctx))
      assert Approval.inspect_state(approval_state(c)).releases == []
      refute_receive {:send_started, _, _}, 0
    end
  end

  for mode <- [:rejected, :unavailable, :reply_loss] do
    @mode mode
    test "Release restart windows: #{@mode} append and current-context retry", c do
      p = owner(c)
      create(p, c)
      {key, ctx} = request(p)
      # Death before invocation retains the open request, not consent.
      p = restart(c, p)
      assert {:ok, _, %{approval: :waiting}} = release(p, key, ctx)
      approve(p, key)
      p = restart(c, p)
      trace_effect_work(p)
      revision = snapshot(p).revision
      fault(c, :append, "runs", revision, @mode)
      result = release(p, key, ctx)

      if @mode == :rejected do
        assert result == {:refused, :record_too_large}
        assert snapshot(p).revision == revision
        assert Approval.inspect_state(approval_state(c)).releases == []
        no_effect_work(c, p)
        p = restart(c, p)
        trace_effect_work(p)
        assert {:ok, _, %{approval: :released}} = release(p, key, ctx)
        no_effect_work(c, p)
      else
        assert {:indeterminate, receipt} = result
        no_effect_work(c, p)

        if @mode == :reply_loss do
          assert {:committed, _} = Lease.confirm(c.lease, receipt)
        else
          assert {:unknown, _} = Lease.confirm(c.lease, receipt)
          # Absence is not permission. A winning fenced revision prevents the
          # interrupted expected-revision append from ever committing later.
          assert {:renewed, _} = Lease.renew(c.lease, "owner", ["runs"], 3_600_000)
          assert :superseded = Lease.confirm(c.lease, receipt)
        end

        p = owner(c, Keyword.put(c.opts, :reconcile, receipt))
        trace_effect_work(p)
        assert snapshot(p).current_attempt == "attempt-1"
        assert {:ok, _, %{approval: :released}} = release(p, key, ctx)
        p = restart(c, p)
        trace_effect_work(p)
        assert {:ok, _, %{approval: :released}} = release(p, key, ctx)
        assert length(Approval.inspect_state(approval_state(c)).releases) == 1
        assert {:refused, :expired} = release(p, key, %{ctx | now: 20_000, max_age: 50_000})
        no_effect_work(c, p)
      end
    end
  end

  for reason <- [:policy_changed, :approver_not_authorized, :revoked] do
    @reason reason
    test "Currentness and authority change: prior release is not permission for #{@reason}", c do
      p = owner(c)
      trace_effect_work(p)
      create(p, c)
      {key, ctx} = request(p)
      approve(p, key)
      assert {:ok, _, %{approval: :released}} = release(p, key, ctx)

      ctx =
        case @reason do
          :policy_changed ->
            put_in(ctx.policy.version, 2)

          :approver_not_authorized ->
            put_in(ctx.approver.authority, [])

          :revoked ->
            assert {:ok, _, _} =
                     command(p, :approval_evidence, %{
                       attempt_id: "attempt-1",
                       request_key: key,
                       revoked_evidence_key: {"verifier", "evidence"}
                     })

            ctx
        end

      p = restart(c, p)
      trace_effect_work(p)
      assert {:ok, _} = Run.status(p, "run")
      assert_refusal(@reason, release(p, key, ctx))
      no_effect_work(c, p)
    end
  end

  test "Currentness and authority change: newer Attempt, cancellation and every terminal outcome",
       c do
    p = owner(c)
    create(p, c)
    {key, ctx} = request(p)
    approve(p, key)
    assert {:ok, _, %{approval: :released}} = release(p, key, ctx)
    assert {:ok, _, _} = command(p, :begin_attempt, %{attempt_id: "attempt-2"})
    rev = snapshot(p).revision
    assert {:unchanged, :stale, ^rev} = release(p, key, ctx, %{expected_revision: 0})

    assert {:unchanged, :stale, ^rev} =
             command(p, :cancel, %{attempt_id: "attempt-1", expected_revision: 0})

    assert {:ok, _, :cancelled} = command(p, :cancel, %{attempt_id: "attempt-2"})

    assert {:unchanged, :terminal, _} =
             release(p, key, ctx, %{attempt_id: "attempt-2", expected_revision: 0})

    for outcome <- [:completed, :failed, :cancelled, :out_of_budget, :out_of_time] do
      id = Atom.to_string(outcome)
      create(p, c, id)

      ref =
        if outcome == :completed,
          do:
            committed_evidence(c, %{
              run_id: id,
              operation_id: "operation",
              attempt_id: "attempt-1",
              action_id: "work"
            })

      assert {:ok, _, ^outcome} =
               command(
                 p,
                 :complete,
                 %{attempt_id: "attempt-1", outcome: outcome, reason: nil, evidence_ref: ref},
                 id
               )

      assert {:unchanged, :terminal, _} =
               command(
                 p,
                 :release_approved,
                 %{attempt_id: "attempt-1", request_key: key, context: ctx, expected_revision: 0},
                 id
               )
    end

    refute_receive {:send_started, _, _}, 0
  end

  test "Resource-owned send: correlated release, FIFO, reservation and recovery", c do
    p = owner(c)
    create(p, c)
    f = resource(c)
    a = resource_intent("A")
    b = resource_intent("B")

    ctx =
      context(:run)
      |> put_in([:proposal, :action_id], "A")
      |> put_in([:proposal, :payload], {:text, a.arguments})

    b_ctx =
      ctx
      |> put_in([:proposal, :action_id], "B")
      |> put_in([:proposal, :payload], {:text, b.arguments})

    {:ok, a_decision} = Elzoo.Authorization.decide(ctx.policy, ctx.proposal, ctx.authority)
    {:ok, b_decision} = Elzoo.Authorization.decide(b_ctx.policy, b_ctx.proposal, b_ctx.authority)

    assert {:ok, _, key} =
             command(p, :approval_request, %{attempt_id: "attempt-1", decision: a_decision})

    assert {:ok, _, b_key} =
             command(p, :approval_request, %{attempt_id: "attempt-1", decision: b_decision})

    approve(p, key, :run)

    assert {:ok, _, ^b_key} =
             command(p, :approval_evidence, %{
               attempt_id: "attempt-1",
               request_key: b_key,
               evidence: %{evidence(b_key, :run) | evidence_id: "evidence-B"}
             })

    assert {:ok, %{disposition: :accepted}} = resource_action(f, "A", "resource_use", a)
    assert {:ok, %{disposition: :queued}} = resource_action(f, "B", "resource_use", b)
    # This host-owned immutable record binds the full ASK to the exact descriptor.
    correlation =
      committed_evidence(c, %{
        request_key: key,
        action: ctx.proposal,
        resource: %{run_id: "run", name: "browser", action_id: "A"},
        descriptor: a
      })

    committed_evidence(c, %{
      request_key: b_key,
      action: b_ctx.proposal,
      resource: %{run_id: "run", name: "browser", action_id: "B"},
      descriptor: b
    })

    assert {:ok, row, _} = Store.read(c.store, :read_at, [correlation.stream, correlation.sequence])
    assert %{request_key: ^key, descriptor: ^a} = :erlang.binary_to_term(row.payload, [:safe])
    trace_effect_work(p)
    assert {:ok, _, %{approval: :released}} = release(p, key, ctx)
    no_effect_work(c, p)
    p = restart(c, p)
    # Caller died after release but before resource dispatch. Revalidate, no resend.
    assert {:ok, _, %{approval: :released}} = release(p, key, ctx)
    a_owner = resource_effect(c, a)
    b_owner = resource_effect(c, b)

    assert {:refused, :not_open} =
             resource_command(f, "queued", {:dispatch, b.identity, b_owner})

    refute_receive {:send_started, _, _}, 0

    assert {:ok, %{disposition: :accepted}} =
             resource_command(f, "send-A", {:dispatch, a.identity, a_owner})

    assert_receive {:send_started, worker, req}
    assert req.arguments == a.arguments and req.key == Elzoo.EffectIntent.Model.key(a.identity)
    {:ok, retained} = Elzoo.RunResource.read(f.owner, 0)
    assert Enum.any?(retained.entries, &(&1.command_id == {:dispatch, "send-A"}))
    # The real SQL resource reservation is already committed while send is blocked.
    {:ok, %{revision: revision}} = Store.read(f.store, :head, ["resource"])
    assert revision >= List.last(retained.entries).seq

    result = %{
      "version" => 1,
      "message_id" => req.key,
      "correlation_id" => req.key,
      "attempt_id" => req.attempt_id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{"digest" => req.arguments_digest},
      "value_schema_id" => "result",
      "value_schema_version" => 1
    }

    assert {:error, :invalid_observation} =
             Elzoo.EffectIntent.observe(a_owner, %{result | "correlation_id" => "forged"})

    send(worker, {:complete, result})
    assert_receive {:physical_send, ^req}
    assert {:ok, _} = Elzoo.EffectIntent.observe(a_owner, result)
    # The trusted host carries authenticated completion to Resource; Run does not.
    assert {:ok, _} =
             resource_command(
               f,
               "A-done",
               {:observed, a.identity,
                {:completed, %{"digest" => Base.encode16(req.arguments_digest)}}}
             )

    {:ok, view} = Elzoo.RunResource.read(f.owner, 0)
    assert view.state.active_action_id == "B"

    assert {:refused, :approver_not_authorized} =
             release(p, b_key, put_in(b_ctx.approver.authority, []))

    refute_receive {:send_started, _, _}, 0
    assert {:ok, _, %{approval: :released}} = release(p, b_key, b_ctx)
    assert {:ok, _} = resource_command(f, "send-B", {:dispatch, b.identity, b_owner})
    assert_receive {:send_started, b_worker, b_req}
    assert b_req.arguments == b.arguments and b_req.key == Elzoo.EffectIntent.Model.key(b.identity)
    # Crash after reservation before caller outcome; recovery is reconciliation,
    # not a second send even if approval revalidates successfully.
    GenServer.stop(b_owner)
    recover(c)
    b_recovered = resource_effect(c, b)
    p = restart(c, p)
    assert {:ok, _, %{approval: :released}} = release(p, b_key, b_ctx)
    assert {:error, :not_dispatchable} = Elzoo.EffectIntent.advance(b_recovered, :dispatch)
    GenServer.stop(f.owner)
    {:held, held} = Lease.hold(f.lease, "resource", "owner")
    {:ok, recovered} = Elzoo.RunResource.start_link(%{f.options | held: held})
    Process.unlink(recovered)
    on_exit(fn -> if Process.alive?(recovered), do: GenServer.stop(recovered) end)

    assert {:ok, %{disposition: :late}} =
             Elzoo.RunResource.command(recovered, %{
               id: "retry-B",
               at_ms: 2000,
               body: {:dispatch, b.identity, b_recovered}
             })

    assert {:ok, %{state: %{phase: :closing}}} = Elzoo.RunResource.read(recovered, 0)
    send(b_worker, :send)
    assert_receive {:physical_send, ^b_req}
    refute_receive {:send_started, _, _}, 10
    assert snapshot(p).effects == %{}
  end

  for transition <- [:pause, :closing, :deadline, :read_only] do
    @transition transition
    test "Resource-owned send: #{@transition} after release is not dispatch permission", c do
      p = owner(c)
      create(p, c)
      {key, ctx} = request(p)
      approve(p, key)
      f = resource(c)
      a = resource_intent("A")
      assert {:ok, _} = resource_action(f, "A", "resource_use", a)
      assert {:ok, _, %{approval: :released}} = release(p, key, ctx)

      expected =
        case @transition do
          :pause ->
            assert {:ok, _} = resource_command(f, "pause", :pause)
            :paused

          :closing ->
            assert {:ok, _} = resource_action(f, "close", "resource_close", nil)
            :closing

          :deadline ->
            Agent.update(c.control, &Map.put(&1, :now, 10_000))
            :closing

          :read_only ->
            Agent.update(c.control, &Map.put(&1, :host, :read_only))
            :read_only
        end

      effect = resource_effect(c, a)
      assert {:refused, ^expected} = resource_command(f, "no-send", {:dispatch, a.identity, effect})
      refute_receive {:send_started, _, _}, 10
      refute_receive {:physical_send, _}, 0
    end
  end

  test "Isolation, copy and checked example: separate owners and release then Resource", c do
    # Old Run is not a dependency of a standalone variant copy. When both are
    # selected (repository/co-install consumer), exercise their separate streams.
    old_module = Elzoo.Run

    old =
      if Code.ensure_loaded?(old_module) do
        old_store =
          Elzoo.DurableLog.Postgres.store(c.repo,
            prefix: c.prefix,
            fold: old_module.fold(),
            limits: old_module.limits()
          )

        {:ok, old_lease} = Lease.new(store: old_store, clock: :store)
        {:held, old_held} = Lease.claim(old_lease, "old-runs", "owner", 3_600_000)

        {:ok, old} =
          old_module.start_link(
            store: old_store,
            lease: old_lease,
            held: old_held,
            effect_intent: %{}
          )

        Process.unlink(old)
        on_exit(fn -> if Process.alive?(old), do: GenServer.stop(old) end)

        assert {:ok, _, "run"} =
                 old_module.command(old, %{
                   kind: :create,
                   run_id: "run",
                   expected_revision: old_held.live.revision,
                   operation_id: "old-operation",
                   provider_refs: %{}
                 })

        assert {:ok, %{operation_id: "old-operation", current_attempt: nil}} =
                 old_module.status(old, "run")

        old
      end

    p = owner(c)
    create(p, c)
    assert snapshot(p).operation_id == "operation"
    f = resource(c)
    a = resource_intent("A")

    ctx =
      context()
      |> put_in([:proposal, :action_id], "A")
      |> put_in([:proposal, :payload], {:text, a.arguments})

    {:ok, decision} = Elzoo.Authorization.decide(ctx.policy, ctx.proposal, ctx.authority)

    assert {:ok, _, key} =
             command(p, :approval_request, %{attempt_id: "attempt-1", decision: decision})

    approve(p, key)
    assert {:ok, _} = resource_action(f, "A", "resource_use", a)

    committed_evidence(c, %{
      request_key: key,
      action: ctx.proposal,
      resource: %{run_id: "run", name: "browser", action_id: "A"},
      descriptor: a
    })

    effect = resource_effect(c, a)

    release_command = %{
      kind: :release_approved,
      run_id: "run",
      attempt_id: "attempt-1",
      expected_revision: snapshot(p).revision,
      request_key: key,
      context: ctx
    }

    dispatch_command = %{id: "example-send", at_ms: 2000, body: {:dispatch, a.identity, effect}}

    assert {:ok, %{disposition: :accepted}} =
             Elzoo.RunApprovalRelease.Example.release_then_dispatch(
               p,
               release_command,
               f.owner,
               dispatch_command
             )

    assert_receive {:send_started, worker, req}
    assert req.arguments == a.arguments and req.key == Elzoo.EffectIntent.Model.key(a.identity)
    send(worker, :send)
    assert_receive {:physical_send, ^req}
    if old, do: assert({:ok, %{current_attempt: nil}} = old_module.status(old, "run"))
    assert snapshot(p).effects == %{}
  end

  defp resource_intent(id) do
    %{
      identity: ["tenant", "account", "adapter", "send", "resource/" <> id],
      arguments: "canonical/" <> id,
      binding: "binding",
      binding_digest: Elzoo.RunApprovalRelease.TestBinding.__effect_intent_binding__().digest,
      deadline_ms: 10_000
    }
  end

  defp resource(c) do
    fold = %{
      initial: nil,
      versions: [1],
      destinations: [],
      kinds: Map.merge(%{"run_resource_state" => :state_bearing}, Lease.kinds()),
      reduce: fn _, _, _, payload -> payload end
    }

    store =
      Elzoo.DurableLog.Postgres.store(c.repo, prefix: c.prefix, fold: fold, limits: Run.limits())

    {:ok, lease} = Lease.new(store: store, clock: :store)
    {:held, held} = Lease.claim(lease, "resource", "owner", 3_600_000)

    descriptor = %{
      run_id: "run",
      name: "browser",
      deadline_ms: 10_000,
      rate_per_minute: 1,
      max_waiting: 1,
      budget: %{budget_id: "budget", unit: "credits", cost_ref: "resource", generation: {"inc", 1}},
      close_intent: %{resource_intent("close") | deadline_ms: 20_000}
    }

    options = %{
      lease: lease,
      held: held,
      clock: fn -> Agent.get(c.control, &Map.get(&1, :now, 2000)) end,
      resource: descriptor
    }

    {:ok, pid} = Elzoo.RunResource.start_link(options)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    f = %{owner: pid, store: store, lease: lease, options: options}
    assert {:ok, _} = resource_action(f, "open", "resource_open", resource_intent("open"))
    # Trusted host fixture has authenticated the pre-existing open, not a real
    # provider or permission obtained from approval. Only uses are sent here.
    assert {:ok, _} =
             resource_command(
               f,
               "opened",
               {:observed, resource_intent("open").identity, {:completed, %{opened_at_ms: 2000}}}
             )

    f
  end

  defp resource_action(f, id, kind, intent) do
    action = %{
      "id" => id,
      "kind" => kind,
      "schema_id" => "elzoo.run-resource.action",
      "schema_version" => 1,
      "payload" => %{"run_id" => "run", "resource_name" => "browser", "data" => %{}}
    }

    resource_command(
      f,
      id,
      {:action, action, %{run_id: "run", scope: :owner, resource_names: []}, intent}
    )
  end

  defp resource_command(f, id, body),
    do: Elzoo.RunResource.command(f.owner, %{id: id, at_ms: 2000, body: body})

  defp resource_effect(c, descriptor) do
    opts = c.opts[:effect_intent]["binding"]

    {:ok, owner} =
      Elzoo.EffectIntent.start_link(
        Keyword.merge(opts,
          identity: descriptor.identity,
          arguments: descriptor.arguments,
          deadline: descriptor.deadline_ms
        )
      )

    Process.unlink(owner)
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
    owner
  end

  @effect_calls [
    {Elzoo.EffectIntent, :start_link, 1},
    {Elzoo.EffectIntent, :advance, 2},
    {Elzoo.EffectIntent, :observe, 2},
    {Elzoo.EffectIntent.StoreHost, :activate, 2},
    {Task.Supervisor, :async_nolink, 2},
    {Task.Supervisor, :async_nolink, 3},
    {Task.Supervisor, :start_child, 2},
    {Elzoo.RunApprovalRelease.TestAdapter, :send_effect, 1}
  ]

  defp trace_effect_work(pid) do
    for {module, _, _} = mfa <- @effect_calls do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, true, [:local]) > 0
    end

    :erlang.trace(pid, true, [:call, :set_on_spawn, {:tracer, self()}])
    on_exit(fn -> for mfa <- @effect_calls, do: :erlang.trace_pattern(mfa, false, [:local]) end)
  end

  defp no_effect_work(c, pid) do
    barrier = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^barrier}
    refute_receive {:trace, _, :call, _}, 0
    refute_receive {:send_started, _, _}, 0
    refute_receive {:physical_send, _}, 0
    assert Task.Supervisor.children(c.opts[:effect_intent]["binding"][:task_supervisor]) == []
    assert {:ok, %{revision: 0}} = Store.read(c.intent_store, :head, [intent_stream()])
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
