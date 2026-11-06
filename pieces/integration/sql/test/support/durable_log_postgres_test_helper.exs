# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DurableLog.UnreachableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DurableLog.TestMigration do
  use Ecto.Migration
  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
  def down, do: Elzoo.DurableLog.Postgres.Migration.down()
end

defmodule Elzoo.DurableLog.PostgresHarness do
  @moduledoc false
  alias Elzoo.DurableLog.{Postgres, Store}
  alias Ecto.Adapters.SQL

  def database_url! do
    System.get_env("ELZOO_TEST_DATABASE_URL") ||
      raise "ELZOO_TEST_DATABASE_URL is required: PostgreSQL tests fail closed; provide a disposable local database (never skipped)"
  end

  def reachable!(repo) do
    case SQL.query(repo, "SELECT 1", [], timeout: 2_000, log: false) do
      {:ok, _} ->
        :ok

      _ ->
        raise "ELZOO_TEST_DATABASE_URL is unreachable: PostgreSQL tests fail closed (never skipped)"
    end
  rescue
    _ ->
      raise "ELZOO_TEST_DATABASE_URL is unreachable: PostgreSQL tests fail closed (never skipped)"
  end

  def start_link(_), do: Agent.start_link(fn -> %{faults: %{}, paused: %{}, history: []} end)
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def attach(repo, prefix, fold, limits, controller) do
    Postgres.store(repo,
      prefix: prefix,
      fold: fold,
      limits: limits,
      test_dispatch: fn op, req, run -> dispatch(controller, op, req, run) end,
      test_hook: fn op, phase, repo -> barrier(controller, op, phase, repo) end,
      test_read: fn op -> read_fault(controller, op) end,
      controller: controller
    )
  end

  def hook({Postgres, opts}, :inject, [op, mode]),
    do: Agent.update(opts.controller, &put_in(&1.faults[op], mode))

  def hook({Postgres, opts}, :release, [token]), do: finish(opts.controller, token, :commit)

  def hook({Postgres, opts}, :rollback, [token]) do
    finish(opts.controller, token, :rollback)
    :ok
  end

  def hook({Postgres, opts}, :reopen, []) do
    SQL.disconnect_all(opts.repo, 0)
    {Postgres, opts}
  end

  def hook({Postgres, opts}, :snapshot, []) do
    Map.new([:elzoo_log_heads, :elzoo_log_records, :elzoo_outbox, :elzoo_checkpoints], fn table ->
      columns = if table == :elzoo_outbox or table == :elzoo_checkpoints, do: "1,2,3", else: "1,2"

      result =
        SQL.query!(
          opts.repo,
          "SELECT * FROM #{Postgres.identifier(opts.prefix)}.#{table} ORDER BY #{columns}",
          [],
          log: false
        )

      {table, result.rows}
    end)
  end

  def hook({Postgres, opts}, :duplicate_insert, [r]) do
    result =
      SQL.query(
        opts.repo,
        "INSERT INTO #{Postgres.identifier(opts.prefix)}.elzoo_log_records (stream,sequence,kind,schema_version,payload,nonce,digest) VALUES ($1,$2,$3,$4,$5,$6,$7)",
        [r.stream, r.sequence, r.kind, r.schema_version, r.payload, r.nonce, r.digest],
        log: false
      )

    case result do
      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} -> {:error, :duplicate}
      other -> other
    end
  end

  def history(controller), do: Agent.get(controller, &Enum.reverse(&1.history))
  def paused(controller, token), do: Agent.get(controller, &Map.fetch!(&1.paused, token))

  def cleanup(controller) do
    for token <- Agent.get(controller, &Map.keys(&1.paused)),
        do: finish(controller, token, :rollback)

    :ok
  end

  defp pop(controller, op),
    do:
      Agent.get_and_update(controller, fn state ->
        {mode, faults} = Map.pop(state.faults, op)
        {mode, %{state | faults: faults}}
      end)

  defp read_fault(controller, op) do
    Agent.get_and_update(controller, fn state ->
      {mode, faults} = Map.pop(state.faults, op)

      result =
        case mode do
          nil -> :ok
          :unavailable -> {:error, :unavailable}
          _ -> {:error, :malformed}
        end

      {result, %{state | faults: faults}}
    end)
  end

  defp dispatch(controller, op, request, run) do
    case pop(controller, op) do
      :unavailable ->
        Store.unknown(request, :unavailable)

      :malformed ->
        :junk

      :reply_loss ->
        run.()
        Store.unknown(request, :unavailable)

      {:pause, token} ->
        pause(
          controller,
          op,
          request,
          run,
          token,
          if(op == :append, do: :after_head_cas, else: :before_commit)
        )

      {:pause, token, phase} ->
        pause(controller, op, request, run, token, phase)

      mode ->
        previous = Process.put({__MODULE__, :mode}, mode)

        try do
          run.()
        after
          Process.put({__MODULE__, :mode}, previous)
        end
    end
  end

  defp pause(_controller, op, request, run, token, phase) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put({__MODULE__, :mode}, {:pause, token, phase, parent, ref})
        result = run.()

        case Process.get({__MODULE__, :finish}) do
          {to, finish_ref} -> send(to, {:finished, finish_ref, result})
          nil -> send(parent, {:completed, ref, result})
        end
      end)

    receive do
      {:barrier, ^ref} ->
        Process.demonitor(monitor, [:flush])
        Store.unknown(request, :timeout)

      {:completed, ^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        Store.unknown(request, :exit)
    after
      10_000 -> raise "Postgres barrier not reached for #{op}"
    end
  end

  defp barrier(controller, op, phase, repo) do
    Agent.update(controller, &%{&1 | history: [{op, phase} | &1.history]})

    case Process.get({__MODULE__, :mode}) do
      :rollback when phase == :before_commit ->
        repo.rollback(:injected_rollback)

      {:terminate, parent} when phase == :after_head_cas ->
        [[backend]] = SQL.query!(repo, "SELECT pg_backend_pid()", [], log: false).rows
        send(parent, {:postgres_backend, self(), backend})

        receive do
          :continue -> :ok
        after
          10_000 -> repo.rollback(:barrier_timeout)
        end

      {:pause, token, ^phase, parent, ref} ->
        [[backend]] = SQL.query!(repo, "SELECT pg_backend_pid()", [], log: false).rows
        worker = self()

        Agent.update(
          controller,
          &put_in(&1.paused[token], %{pid: worker, backend: backend, operation: op})
        )

        send(parent, {:barrier, ref})

        receive do
          {:finish, action, to, finish_ref} ->
            Process.put({__MODULE__, :finish}, {to, finish_ref})
            Process.put({__MODULE__, :mode}, nil)
            Agent.update(controller, &%{&1 | paused: Map.delete(&1.paused, token)})
            if action == :rollback, do: repo.rollback(:injected_rollback)
        after
          30_000 -> repo.rollback(:barrier_timeout)
        end

      _ ->
        :ok
    end
  end

  defp finish(controller, token, action) do
    entry = Agent.get(controller, &Map.get(&1.paused, token))

    if entry do
      ref = make_ref()
      monitor = Process.monitor(entry.pid)
      send(entry.pid, {:finish, action, self(), ref})

      receive do
        {:finished, ^ref, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, _, _} ->
          {:error, :unavailable}
      after
        10_000 -> raise "paused PostgreSQL operation did not finish"
      end
    else
      {:error, :absent}
    end
  end
end
