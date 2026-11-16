# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CheckedCommandExample.Repo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.CheckedCommandExample.Migration do
  use Ecto.Migration

  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
  def down, do: Elzoo.DurableLog.Postgres.Migration.down()
end

defmodule Elzoo.CheckedCommandExample do
  alias Ecto.Adapters.SQL
  alias Elzoo.{CheckedCommand, PayloadSchema, TriggerBinding}
  alias Elzoo.DurableLog.Postgres

  @hash :binary.copy(<<9>>, 32)
  @event_schema %{"schema_id" => "orders.created", "schema_version" => 1}

  def run do
    url = System.fetch_env!("ELZOO_TEST_DATABASE_URL")
    tenant = "tenant-example"
    actor = "operator-example"
    source = "webhook-example"
    resource = "trigger-example"
    prefix = "cc_example_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    {:ok, repo} = Elzoo.CheckedCommandExample.Repo.start_link(url: url, pool_size: 2, log: false)

    try do
      _ = SQL.query!(repo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)

      :ok =
        Ecto.Migrator.up(
          Elzoo.CheckedCommandExample.Repo,
          1,
          Elzoo.CheckedCommandExample.Migration,
          prefix: prefix,
          log: false
        )

      store =
        Postgres.store(Elzoo.CheckedCommandExample.Repo,
          prefix: prefix,
          fold: %{
            kinds: %{"checked_command" => :state_bearing},
            versions: [1],
            destinations: ["trigger-binding-notifications"]
          },
          limits: %{max_record_bytes: 1_048_576, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}
        )

      port = %{
        "id" => "trigger-command",
        "direction" => "input",
        "schema_id" => "trigger/install",
        "schema_version" => 1
      }

      {:ok, schema} = PayloadSchema.build(port, %{})

      declaration = %{
        "version" => 1,
        "id" => resource,
        "revision" => 1,
        "tenant" => tenant,
        "source" => source,
        "schema_id" => @event_schema["schema_id"],
        "schema_version" => @event_schema["schema_version"],
        "enabled" => true,
        "target" => %{
          "bot_ref" => "order-handler",
          "package_digest" => String.duplicate("a", 64),
          "callable" => "handle_order"
        }
      }

      own = [%{target: resource, field: "declaration", value: portable_json(declaration)}]
      prepare = &prepare_binding(&1, &2, &3, tenant, source)

      descriptor = %{
        id: "trigger/install",
        version: 1,
        content_hash: @hash,
        effect_class: "publish",
        port: port,
        schema: schema,
        prepare: prepare,
        gate: %{
          call: fn
            {:PatternStep, _}, %{proposer: ^actor, effect_class: "publish", tenant: ^tenant} ->
              :allow

            _, _ ->
              {:deny, "host_context"}
          end
        },
        approval: %{verifiers: ["command-reviewer"], max_age: 60_000},
        outbox: "trigger-binding-notifications"
      }

      {:ok, handle} = CheckedCommand.new(store, descriptor)

      context = %{
        tenant: tenant,
        actor: actor,
        policy: %{
          id: "trigger-policy",
          version: 1,
          content_hash: @hash,
          effect_classes: ["publish"],
          rules: [%{id: "allow-trigger-install", effect_class: "publish", verdict: :allow}]
        },
        own: own,
        parent: :none,
        facts: {:record, [{"source", {:text, source}}]}
      }

      request = %{
        operation_id: "install-trigger-example",
        resource: resource,
        expected_revision: 0,
        payload: %{
          "tenant" => "payload-tenant-is-not-trusted",
          "source" => "payload-source-is-not-trusted",
          "declaration" => declaration
        }
      }

      {:completed, %{revision: 1}} = CheckedCommand.execute(handle, context, request)
      scope = %{tenant: tenant, actor: actor, resources: [resource]}
      {:ok, %{revision: 1, fields: fields}} = CheckedCommand.resource(handle, scope, resource)

      {:ok, checked} =
        fields["declaration"] |> decode_portable() |> TriggerBinding.validate_declaration()

      {:ok, selected} =
        TriggerBinding.select(
          [checked],
          %{tenant: tenant, source: source},
          @event_schema
        )

      true = selected.id == resource and selected.revision == 1

      stream =
        "cc1:" <>
          Base.url_encode64(
            :erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]),
            padding: false
          )

      {:ok, pending} = Postgres.pending(store, stream, 16)

      true =
        Enum.any?(
          pending,
          &(&1.stream == stream and &1.destination == "trigger-binding-notifications")
        )

      IO.puts(
        "Installed and selected #{selected.id} at revision #{selected.revision}; " <>
          "#{length(pending)} notification(s) pending"
      )
    after
      _ =
        SQL.query(repo, "DROP SCHEMA IF EXISTS #{Postgres.identifier(prefix)} CASCADE", [],
          log: false
        )

      Supervisor.stop(repo)
    end
  end

  defp prepare_binding(snapshot, request, facts, tenant, source) do
    declaration = Map.get(request.payload, "declaration")
    trusted_source = portable_fact(facts.data, "source")

    with true <- snapshot.tenant == tenant and snapshot.revision == request.expected_revision,
         true <- facts.tenant == tenant and trusted_source == source,
         {:ok, declaration} <- TriggerBinding.validate_declaration(declaration),
         true <- declaration["id"] == request.resource,
         true <- declaration["tenant"] == facts.tenant,
         true <- declaration["source"] == trusted_source,
         true <- declaration["revision"] == request.expected_revision + 1 do
      {:ok,
       [
         %{
           target: request.resource,
           field: "declaration",
           value: portable_json(declaration)
         }
       ], {:record, [{"installed", true}]}}
    else
      _ -> {:refused, "binding_mismatch"}
    end
  end

  defp portable_fact({:record, pairs}, key) do
    case List.keyfind(pairs, key, 0) do
      {^key, {:text, value}} -> value
      _ -> nil
    end
  end

  defp portable_json(value) when is_map(value) do
    {:record,
     value
     |> Enum.sort_by(&elem(&1, 0))
     |> Enum.map(fn {key, nested} -> {key, portable_json(nested)} end)}
  end

  defp portable_json(value) when is_list(value), do: {:list, Enum.map(value, &portable_json/1)}
  defp portable_json(value) when is_binary(value), do: {:text, value}
  defp portable_json(value), do: value

  defp decode_portable({:record, pairs}),
    do: Map.new(pairs, fn {key, value} -> {key, decode_portable(value)} end)

  defp decode_portable({:list, values}), do: Enum.map(values, &decode_portable/1)
  defp decode_portable({:text, value}), do: value
  defp decode_portable(value), do: value
end

Elzoo.CheckedCommandExample.run()
