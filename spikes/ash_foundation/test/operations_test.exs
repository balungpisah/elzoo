# SPDX-License-Identifier: Apache-2.0
defmodule ElzooAshSpike.OperationsTest do
  use ExUnit.Case, async: false
  alias ElzooAshSpike.{AdmissionServer, Operations}

  setup do
    tenant = Ash.UUID.generate()
    server = start_supervised!({AdmissionServer, tenant})
    actor = %{id: "test-operator", tenant_id: tenant, role: :operator}
    {:ok, server: server, tenant: tenant, actor: actor}
  end

  defp call(ctx, action, args \\ %{}, role \\ :operator) do
    Operations
    |> Ash.ActionInput.for_action(action, args,
      actor: %{ctx.actor | role: role},
      tenant: ctx.tenant,
      context: %{controller: ctx.server}
    )
    |> Ash.run_action()
  end

  defp tool(ctx, name, args, actor) do
    definition =
      AshAi.exposed_tools(otp_app: :elzoo_ash_spike, actor: ctx.actor, tenant: ctx.tenant)
      |> Enum.find(&(&1.name == name))

    assert definition

    AshAi.Tools.execute(definition, %{"input" => args}, %{
      actor: actor,
      tenant: ctx.tenant,
      context: %{controller: ctx.server}
    })
  end

  test "config is versioned and invalid or stale writes leave effective settings intact", ctx do
    assert {:ok, %{state: %{limit: 3, revision: 1}}} =
             call(ctx, :configure, %{expected_revision: 0, limit: 3})

    assert {:error, _} = call(ctx, :configure, %{expected_revision: 0, limit: 4})

    for limit <- [0, 65] do
      assert {:error, _} = call(ctx, :configure, %{expected_revision: 1, limit: limit})
    end

    assert {:ok, %{state: %{limit: 3, revision: 1}}} = call(ctx, :snapshot)
  end

  test "two controllers cannot both apply the same configuration revision", ctx do
    results =
      [3, 4]
      |> Task.async_stream(fn limit ->
        call(ctx, :configure, %{expected_revision: 0, limit: limit})
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert {:ok, %{state: %{revision: 1}}} = call(ctx, :snapshot)
  end

  test "lowering the limit preserves active work and restricts new admissions", ctx do
    assert {:ok, _} = call(ctx, :admit, %{work_id: "one"}, :worker)
    assert {:ok, _} = call(ctx, :admit, %{work_id: "two"}, :worker)

    assert {:ok, %{state: %{active: 2, limit: 1}}} =
             call(ctx, :configure, %{expected_revision: 0, limit: 1})

    assert {:error, _} = call(ctx, :admit, %{work_id: "three"}, :worker)
    assert {:ok, _} = call(ctx, :finish, %{work_id: "one"}, :worker)
    assert {:error, _} = call(ctx, :admit, %{work_id: "three"}, :worker)
    assert {:ok, _} = call(ctx, :finish, %{work_id: "two"}, :worker)
    assert {:ok, _} = call(ctx, :admit, %{work_id: "three"}, :worker)
  end

  test "drain waits for named work to finish, then pauses before explicit resume", ctx do
    assert {:ok, _} = call(ctx, :admit, %{work_id: "one"}, :worker)

    assert {:ok, %{state: %{mode: :draining, revision: 1}}} =
             call(ctx, :drain, %{expected_revision: 0})

    assert {:error, _} = call(ctx, :admit, %{work_id: "two"}, :worker)
    assert {:error, _} = call(ctx, :resume, %{expected_revision: 1})
    assert {:error, _} = call(ctx, :pause, %{expected_revision: 1})

    assert {:ok, %{state: %{mode: :paused, revision: 2}}} =
             call(ctx, :finish, %{work_id: "one"}, :worker)

    assert {:error, _} = call(ctx, :resume, %{expected_revision: 1})
    assert {:ok, %{state: %{mode: :running}}} = call(ctx, :resume, %{expected_revision: 2})
  end

  test "pause does not cancel existing work; duplicate finish cannot release another slot", ctx do
    assert {:ok, _} = call(ctx, :admit, %{work_id: "one"}, :worker)
    assert {:error, _} = call(ctx, :admit, %{work_id: "one"}, :worker)
    assert {:ok, _} = call(ctx, :pause, %{expected_revision: 0})
    assert {:error, _} = call(ctx, :admit, %{work_id: "two"}, :worker)

    assert {:ok, %{state: %{active: 0, mode: :paused}}} =
             call(ctx, :finish, %{work_id: "one"}, :worker)

    assert {:error, _} = call(ctx, :finish, %{work_id: "one"}, :worker)
  end

  test "empty drain pauses immediately", ctx do
    assert {:ok, %{state: %{mode: :paused}}} = call(ctx, :drain, %{expected_revision: 0})
  end

  test "direct and cached tool calls enforce the same authority and revision", ctx do
    assert {:error, _} = call(ctx, :configure, %{expected_revision: 0, limit: 3}, :viewer)

    for actor <- [nil, %{ctx.actor | role: :worker}, %{ctx.actor | tenant_id: "elsewhere"}] do
      assert {:error, _} =
               tool(ctx, :configure_admission, %{"expected_revision" => 0, "limit" => 3}, actor)
    end

    assert {:ok, _, %{state: %{limit: 3, revision: 1}}} =
             tool(ctx, :configure_admission, %{"expected_revision" => 0, "limit" => 3}, ctx.actor)

    assert {:error, _} = call(ctx, :configure, %{expected_revision: 0, limit: 4})

    assert {:error, _} =
             tool(ctx, :configure_admission, %{"expected_revision" => 1, "limit" => 0}, ctx.actor)

    assert {:ok, _, %{state: %{mode: :paused}}} =
             tool(ctx, :pause_admission, %{"expected_revision" => 1}, ctx.actor)

    assert {:ok, %{state: %{mode: :paused, limit: 3}}} = call(ctx, :snapshot, %{}, :viewer)
  end

  test "misrouting trusted context to another tenant controller fails closed", ctx do
    wrong = %{ctx | tenant: "another", actor: %{ctx.actor | tenant_id: "another"}}
    assert {:error, _} = call(wrong, :configure, %{expected_revision: 0, limit: 3})
    assert {:ok, %{state: %{revision: 0, limit: 2}}} = call(ctx, :snapshot)
  end

  test "telemetry reports bounded summaries without work IDs or actor/tenant data", ctx do
    id = "test-observer-" <> ctx.tenant
    :ok = :telemetry.attach(id, [:elzoo, :admission, :operation], &__MODULE__.observe/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    assert {:ok, _} = call(ctx, :admit, %{work_id: "sensitive-work-id"}, :worker)

    assert_receive {:observed, %{active: 1, limit: 2, revision: 0},
                    %{action: :admit, mode: :running, outcome: :ok}}
  end

  @tag capture_log: true
  test "a throwing telemetry handler is detached without vetoing admission", ctx do
    id = "failing-observer-" <> ctx.tenant

    :ok =
      :telemetry.attach(id, [:elzoo, :admission, :operation], &__MODULE__.fail_observer/4, nil)

    on_exit(fn -> :telemetry.detach(id) end)
    assert {:ok, %{state: %{active: 1}}} = call(ctx, :admit, %{work_id: "one"}, :worker)
    refute Enum.any?(:telemetry.list_handlers([:elzoo, :admission, :operation]), &(&1.id == id))
  end

  def observe(_event, measurements, metadata, pid),
    do: send(pid, {:observed, measurements, metadata})

  def fail_observer(_, _, _, _), do: raise("observer failed")
end
