# SPDX-License-Identifier: Apache-2.0
defmodule ElzooAshSpike.WorkTest do
  use ExUnit.Case, async: false
  alias ElzooAshSpike.WorkItem

  setup do
    tenant = Ash.UUID.generate()
    worker = %{id: Ash.UUID.generate(), tenant_id: tenant, role: :worker}
    {:ok, tenant: tenant, worker: worker, member: %{worker | role: :member}}
  end

  defp create(actor, tenant, title \\ "Review the report") do
    WorkItem
    |> Ash.Changeset.for_create(:create, %{title: title}, actor: actor, tenant: tenant)
    |> Ash.create()
  end

  defp complete(item, actor, tenant) do
    item
    |> Ash.Changeset.for_update(:complete, %{}, actor: actor, tenant: tenant)
    |> Ash.update()
  end

  defp tool(name, args, actor, tenant) do
    # Reuse a descriptor discovered by an authorized worker. Dispatch must
    # still enforce the actual caller's authority, even with a cached tool.
    discovery_actor = %{id: "discovery-fixture", tenant_id: tenant, role: :worker}

    definition =
      AshAi.exposed_tools(otp_app: :elzoo_ash_spike, actor: discovery_actor, tenant: tenant)
      |> Enum.find(&(&1.name == name))

    assert definition, "expected an authorized tool descriptor for #{name}"
    AshAi.Tools.execute(definition, args, %{actor: actor, tenant: tenant})
  end

  test "tool discovery reflects caller authority", ctx do
    assert [] == AshAi.exposed_tools(otp_app: :elzoo_ash_spike, tenant: ctx.tenant)

    names =
      AshAi.exposed_tools(otp_app: :elzoo_ash_spike, actor: ctx.member, tenant: ctx.tenant)
      |> Enum.map(& &1.name)

    assert :create_work in names
    assert :list_work in names
    refute :complete_work in names
  end

  test "direct actions create, read and complete the same work intent", ctx do
    assert {:ok, item} = create(ctx.member, ctx.tenant)
    assert item.state == :pending
    assert {:ok, fetched} = Ash.get(WorkItem, item.id, actor: ctx.worker, tenant: ctx.tenant)
    assert {:ok, completed} = complete(fetched, ctx.worker, ctx.tenant)
    assert completed.state == :completed
    assert completed.id == item.id
    assert {:error, %Ash.Error.Invalid{}} = complete(completed, ctx.worker, ctx.tenant)
  end

  test "unauthenticated and cross-tenant creates fail", ctx do
    assert {:error, _} = create(nil, ctx.tenant)
    assert {:error, _} = create(ctx.worker, Ash.UUID.generate())
    assert {:error, _} = create(ctx.worker, nil)
  end

  test "tenant selection is not authority and unauthorized writes leave state intact", ctx do
    assert {:ok, item} = create(ctx.worker, ctx.tenant)
    outsider = %{ctx.worker | tenant_id: Ash.UUID.generate()}
    assert {:error, _} = Ash.get(WorkItem, item.id, actor: outsider, tenant: ctx.tenant)
    assert {:error, _} = complete(item, outsider, ctx.tenant)
    assert {:error, %Ash.Error.Forbidden{}} = complete(item, ctx.member, ctx.tenant)
    assert {:ok, unchanged} = Ash.get(WorkItem, item.id, actor: ctx.worker, tenant: ctx.tenant)
    assert unchanged.state == :pending
  end

  test "unaccepted fields and invalid title cannot alter the resource", ctx do
    assert {:error, %Ash.Error.Invalid{}} = create(ctx.worker, ctx.tenant, "")

    assert {:error, %Ash.Error.Invalid{}} =
             WorkItem
             |> Ash.Changeset.for_create(:create, %{title: "x", state: :completed},
               actor: ctx.worker,
               tenant: ctx.tenant
             )
             |> Ash.create()
  end

  test "agent tools invoke the declared actions with the same transitions", ctx do
    assert {:ok, _, item} =
             tool(:create_work, %{"input" => %{"title" => "Agent task"}}, ctx.worker, ctx.tenant)

    assert {:ok, _, completed} =
             tool(:complete_work, %{"id" => item.id}, ctx.worker, ctx.tenant)

    assert completed.state == :completed
    assert {:error, _} = tool(:complete_work, %{"id" => item.id}, ctx.worker, ctx.tenant)
    assert {:ok, fetched} = Ash.get(WorkItem, item.id, actor: ctx.worker, tenant: ctx.tenant)
    assert fetched.state == :completed
  end

  test "agent arguments cannot grant authority or change tenant", ctx do
    assert {:ok, item} = create(ctx.worker, ctx.tenant)
    outsider = %{ctx.worker | tenant_id: Ash.UUID.generate()}

    for actor <- [nil, ctx.member, outsider] do
      assert {:error, _} = tool(:complete_work, %{"id" => item.id}, actor, ctx.tenant)
    end

    assert {:error, _} =
             tool(
               :complete_work,
               %{"id" => item.id, "actor" => ctx.worker},
               ctx.member,
               ctx.tenant
             )

    for actor <- [nil, outsider] do
      assert {:error, _} =
               tool(:create_work, %{"input" => %{"title" => "x"}}, actor, ctx.tenant)
    end

    assert {:error, _} =
             tool(
               :create_work,
               %{"input" => %{"title" => "x", "tenant_id" => ctx.tenant}},
               outsider,
               ctx.tenant
             )

    assert {:error, _} =
             tool(:create_work, %{"input" => %{"title" => ""}}, ctx.worker, ctx.tenant)

    assert {:ok, item} = Ash.get(WorkItem, item.id, actor: ctx.worker, tenant: ctx.tenant)
    assert item.state == :pending
  end

  test "tool reads filter out another tenant even when its tenant option is supplied", ctx do
    assert {:ok, item} = create(ctx.worker, ctx.tenant)

    assert {:ok, _, %Ash.Page.Keyset{results: [visible]}} =
             tool(:list_work, %{}, ctx.worker, ctx.tenant)

    assert visible.id == item.id
    outsider = %{ctx.worker | tenant_id: Ash.UUID.generate()}
    assert {:ok, _, %Ash.Page.Keyset{results: []}} = tool(:list_work, %{}, outsider, ctx.tenant)
    assert {:error, _} = tool(:list_work, %{}, nil, ctx.tenant)
  end

  test "background execution carries explicit authority into the same action", ctx do
    assert {:ok, item} = create(ctx.worker, ctx.tenant)
    supervisor = start_supervised!({Task.Supervisor, []})

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        tool(:complete_work, %{"id" => item.id}, ctx.worker, ctx.tenant)
      end)

    assert {:ok, _, completed} = Task.await(task)
    assert completed.state == :completed
  end
end
