# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/audit_log_test_helper.exs", __DIR__)

intent_helper = Path.expand("../support/effect_intent_test_helper.exs", __DIR__)

intent_helper =
  if File.regular?(intent_helper),
    do: intent_helper,
    else:
      Path.expand(
        "../../../../delivery/effect-intent/test/support/effect_intent_test_helper.exs",
        __DIR__
      )

Code.require_file(intent_helper)

defmodule Elzoo.AuditLog.EffectIntentTest do
  @moduledoc """
  T6: the owner's first audited mutation. The ELZ-023 effect-intent decision records are
  `elzoo_log_records` changes made through the binding, on the real `Elzoo.EffectIntent` owner
  and `StoreHost` path; checkpoints are written but not audited.
  """
  use ExUnit.Case, async: false
  alias Elzoo.AuditLog
  alias Elzoo.AuditLog.{Harness, TestRepo}
  alias Elzoo.DurableLog.{Postgres, Store}
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.{Binding, Model, StoreHost, TestBinding}

  @requester %{actor: "user:42", action: "refund.request", reason: "order 7 refund"}
  @operator %{actor: "operator:9", action: "refund.activate", reason: "owner start"}

  setup_all do
    :ok = Harness.start!(TestRepo, 8)
    :ok
  end

  setup do
    install = Harness.install!(TestRepo)
    on_exit(fn -> Harness.drop!(TestRepo, install) end)
    {:ok, b} = Binding.load(TestBinding)

    store =
      Postgres.store(TestRepo, prefix: install.prefix, fold: Model.fold(b), limits: Model.limits())

    host_store =
      Postgres.store(TestRepo,
        prefix: install.prefix,
        fold: StoreHost.fold(),
        limits: StoreHost.limits()
      )

    supervisor = start_supervised!({Task.Supervisor, []})

    opts = fn store, host_store ->
      [
        binding: TestBinding,
        identity: ["tenant", "account", "test", "refund", "audit-request"],
        arguments: "args",
        deadline: 5000,
        clock: fn -> 100 end,
        store: store,
        host: {StoreHost, %{store: host_store, authorize: fn _, _ -> :fresh end}},
        adapter_context: %{
          parent: self(),
          send: fn _ -> {:error, :timeout, "timeout"} end,
          poll: fn _ -> {:unknown_to_provider, "trusted"} end
        },
        task_supervisor: supervisor
      ]
    end

    Map.merge(install, %{store: store, host_store: host_store, opts: opts})
  end

  defp owner(opts), do: start_supervised!(Supervisor.child_spec({Intent, opts}, id: make_ref()))

  defp eventually(fun, n \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, n - 1)
    end
  end

  defp audit_by_stream(c) do
    {:ok, txs} = AuditLog.read(TestRepo, c.carbonite, limit: 1000)

    for tx <- txs, change <- tx.changes do
      {change.stream, change.sequence, change.op, change.table, tx.actor, tx.action,
       tx.transaction_id}
    end
  end

  defp records(c, stream),
    do:
      Harness.query!(
        TestRepo,
        "SELECT sequence, kind FROM #{c.prefix}.elzoo_log_records WHERE stream = $1 ORDER BY sequence",
        [stream]
      ).rows

  test "T6 every effect-intent decision record is audited once, attributed to its binding", c do
    {:ok, bound} = AuditLog.bind(c.store, @requester)
    {:ok, bound_host} = AuditLog.bind(c.host_store, @operator)
    pid = owner(c.opts.(bound, bound_host))
    assert Intent.status(pid).active
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, req}, 5_000
    # the timeout result is appended asynchronously by the owner (settlement after the send)
    eventually(fn -> Intent.status(pid).revision == 3 end)
    GenServer.stop(pid)

    intent = Model.stream(req.key)
    host = StoreHost.stream(req.key)
    intent_records = records(c, intent)
    host_records = records(c, host)
    assert length(intent_records) == 3 and Enum.all?(intent_records, &match?([_, "intent"], &1))
    assert length(host_records) >= 1

    audit = audit_by_stream(c)

    intent_audit =
      for {^intent, seq, op, table, actor, action, tx} <- audit,
          do: {seq, op, table, actor, action, tx}

    host_audit = for {^host, seq, _, _, actor, action, _} <- audit, do: {seq, actor, action}

    # exactly one insert change per decision record, each in its own audit transaction
    assert Enum.map(intent_audit, &elem(&1, 0)) == Enum.map(intent_records, &hd/1)

    assert Enum.all?(intent_audit, fn {_, op, {_, table}, actor, action, _} ->
             {op, table, actor, action} ==
               {"insert", "elzoo_log_records", "user:42", "refund.request"}
           end)

    assert length(Enum.uniq(Enum.map(intent_audit, &elem(&1, 5)))) == length(intent_audit)
    assert host_audit == for([seq, _] <- host_records, do: {seq, "operator:9", "refund.activate"})

    # checkpoints were written and are outside the audited surface
    assert {:ok, %{sequence: s}} = Store.read(c.store, :latest_checkpoint, [intent, 1])
    assert s >= 1
    assert length(audit) == length(intent_records) + length(host_records)
  end

  test "T6 an owner over an audited schema without a binding cannot admit: nothing recorded", c do
    # the owner starts, but its admission write is refused by the database: it stays read-only
    pid = owner(c.opts.(c.store, c.host_store))
    refute Intent.status(pid).active
    assert {:error, :read_only} = Intent.advance(pid, :dispatch)
    refute_receive {:physical_send, _, _}, 50
    assert Harness.records(TestRepo, c.prefix) == 0
    assert Harness.transactions(TestRepo, c.carbonite) == 0
  end
end
