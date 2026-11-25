# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TenantIsolation do
  @moduledoc """
  A database-enforced tenant floor over a consumer-owned Ecto Repo (PostgreSQL 16).

  `transact/3` runs a function in a transaction whose two transaction-local settings,
  `elzoo.tenant_id` and `elzoo.space_ids`, carry the caller's tenant and exact space list; the
  restrictive `elzoo_tenant_floor` policy that `Elzoo.TenantIsolation.Migration.protect/2`
  creates reads them. `verify/3` is the startup check: it reads the catalog facts of one
  protected table and `decide/1` turns them into `:ok` or one reason.

  Errors are fixed values and never echo a tenant or space ID. The Piece emits no telemetry and
  no log; its own queries run with `log: false` (the Repo's query telemetry still receives
  them, see the README).
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.TenantIsolation.Migration

  @max_spaces 1024
  @set "SELECT set_config('elzoo.tenant_id', $1::text, true), set_config('elzoo.space_ids', $2::text[]::text, true)"
  @clear "SELECT set_config('elzoo.tenant_id', '', true), set_config('elzoo.space_ids', '', true)"
  @rebuildable [:undefined_function, :invalid_schema_name, :undefined_object, :undefined_column]

  @doc """
  Run `fun` (arity 0) in `repo.transact/2` under `scope`, `%{tenant: t}` or
  `%{tenant: t, spaces: list}`. Returns `{:error, {:tenant_isolation, :scope}}` for a bad scope
  or function. With `[]` (the default), use the Repo's transaction timeout. Otherwise pass
  exactly `[timeout: ms]`, with `ms` in 1..600_000, or get `{:error, {:tenant_isolation, :timeout}}`.
  Refuses an open transaction (`:in_transaction`), then an existing checkout (`:in_checkout`,
  explicit timeout only), both tagged `:tenant_isolation`. A deadline failure during begin,
  scope setup or clearing, or commit returns `{:error, :unavailable}` without attesting whether
  a commit happened. Callback errors, exceptions and explicit rollbacks are not translated.
  """
  def transact(repo, scope, fun, opts \\ []) do
    case scope(scope) do
      {:ok, tenant, spaces} when is_function(fun, 0) ->
        cond do
          opts != [] and not match?([{:timeout, ms}] when ms in 1..600_000, opts) ->
            {:error, {:tenant_isolation, :timeout}}

          repo.in_transaction?() ->
            {:error, {:tenant_isolation, :in_transaction}}

          opts != [] and repo.checked_out?() ->
            {:error, {:tenant_isolation, :in_checkout}}

          true ->
            transaction(repo, opts, fn phase ->
              SQL.query!(repo, @set, [tenant, spaces], log: false)
              phase.(:callback)

              case fun.() do
                {:ok, _} = ok ->
                  phase.(:clear)
                  clear!(repo)
                  phase.(:commit)
                  ok

                other ->
                  other
              end
            end)
        end

      _ ->
        {:error, {:tenant_isolation, :scope}}
    end
  end

  defp transaction(repo, [], run), do: repo.transact(fn -> run.(fn _ -> :ok end) end)

  defp transaction(repo, [timeout: ms] = opts, run) do
    deadline = System.monotonic_time(:millisecond) + ms
    # Repo.transact unwinds before it reports failure. Remember who was running: the same
    # error (even :rollback) from the callback must pass through untouched.
    ref = make_ref()

    try do
      case repo.transact(fn -> run.(fn phase -> Process.put(ref, phase) end) end, opts) do
        {:error, :rollback} = error ->
          if Process.get(ref) == :commit and System.monotonic_time(:millisecond) >= deadline,
            do: {:error, :unavailable},
            else: error

        result ->
          result
      end
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error] ->
        if Process.get(ref) != :callback and System.monotonic_time(:millisecond) >= deadline and
             deadline_disconnect?(e),
           do: {:error, :unavailable},
           else: reraise(e, __STACKTRACE__)
    after
      Process.delete(ref)
    end
  end

  # Postgrex cancels an active statement before disconnecting. When idle, DBConnection
  # 2.10.2 reports a lost holder, without a distinct timeout reason.
  defp deadline_disconnect?(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: true

  defp deadline_disconnect?(%DBConnection.ConnectionError{message: message})
       when is_binary(message) do
    message in [
      "connection is closed because of an error, disconnect or timeout",
      "connection not available because deadline reached while in queue"
    ] or
      String.ends_with?(
        message,
        "possibly due to a timeout or because the pool has been terminated)"
      )
  end

  defp deadline_disconnect?(_), do: false

  # After a nested repo.transact inside fun failed, DBConnection 2.10.2 has marked the transaction
  # aborted and refuses every statement with this error; transact/2 would return
  # {:error, :rollback} for that transaction, so the call returns the same.
  defp clear!(repo) do
    SQL.query!(repo, @clear, [], log: false)
  rescue
    e in DBConnection.ConnectionError ->
      if e.message == "transaction rolling back",
        do: repo.rollback(:rollback),
        else: reraise(e, __STACKTRACE__)
  end

  @doc """
  Check one protected table: `:ok` or `{:error, reason}`, `reason` in `:unavailable`,
  `:bypass_role`, `:not_enabled`, `:not_forced`, `:floor_missing` or `:floor_changed`, in that
  order. Takes the same table and options as `Migration.protect/2` and raises the same
  `ArgumentError` for a bad identifier.
  """
  def verify(repo, table, opts) do
    policy = Migration.policy!(table, opts)

    case read_facts(repo, policy) do
      {:ok, facts} -> decide(facts)
      :unavailable -> {:error, :unavailable}
    end
  end

  @doc """
  The pure decision of `verify/3` over read facts:

      %{superuser: boolean, bypassrls: boolean,
        table: nil | %{enabled: boolean, forced: boolean},
        floor: nil | %{permissive: boolean, command: String.t(), public: boolean,
                       using: String.t() | nil, check: String.t() | nil},
        expected: nil | %{using: String.t(), check: String.t()}}

  `table` is `nil` when no such table exists, `floor` when no policy is named
  `elzoo_tenant_floor`, and `expected` when the floor cannot be rebuilt (a protected column or
  the readers' schema is missing).
  """
  def decide(%{superuser: s, bypassrls: b}) when s or b, do: {:error, :bypass_role}
  def decide(%{table: %{enabled: true, forced: true}} = facts), do: floor_decision(facts)
  def decide(%{table: %{enabled: true}}), do: {:error, :not_forced}
  def decide(%{table: _}), do: {:error, :not_enabled}

  defp floor_decision(%{floor: %{permissive: false, command: "*", public: true} = floor} = facts) do
    if facts.expected == %{using: floor.using, check: floor.check},
      do: :ok,
      else: {:error, :floor_changed}
  end

  defp floor_decision(_), do: {:error, :floor_missing}

  # One transaction: the deparse depends on search_path, so the rebuild and the catalog read
  # share it. The rebuild runs inside a savepoint that is always rolled back.
  defp read_facts(repo, policy) do
    result =
      repo.transact(fn ->
        with {:ok, %{rows: [[superuser, bypassrls]]}} <-
               query(
                 repo,
                 "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
               ),
             {:ok, %{rows: table_rows}} <-
               query(
                 repo,
                 "SELECT c.oid, c.relrowsecurity, c.relforcerowsecurity FROM pg_class c WHERE c.oid = to_regclass($1)",
                 [policy.table]
               ),
             {:ok, table, floor, expected} <- table_facts(repo, policy, table_rows) do
          {:ok,
           %{
             superuser: superuser,
             bypassrls: bypassrls,
             table: table,
             floor: floor,
             expected: expected
           }}
        end
      end)

    case result do
      {:ok, facts} -> {:ok, facts}
      {:error, _} -> :unavailable
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp table_facts(_repo, _policy, []), do: {:ok, nil, nil, nil}

  defp table_facts(repo, policy, [[oid, enabled, forced]]) do
    with {:ok, %{rows: floor_rows}} <-
           query(
             repo,
             """
             SELECT p.polpermissive, p.polcmd::text, p.polroles = '{0}'::oid[],
                    pg_get_expr(p.polqual, p.polrelid), pg_get_expr(p.polwithcheck, p.polrelid)
             FROM pg_policy p WHERE p.polrelid = $1 AND p.polname = 'elzoo_tenant_floor'
             """,
             [oid]
           ),
         {:ok, %{rows: column_rows}} <-
           query(
             repo,
             """
             SELECT a.attname, format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
             WHERE a.attrelid = $1 AND a.attname = ANY($2::text[]) AND a.attnum > 0 AND NOT a.attisdropped
             """,
             [oid, policy.columns]
           ),
         {:ok, expected} <- rebuild(repo, policy, Map.new(column_rows, &List.to_tuple/1)) do
      floor =
        case floor_rows do
          [] ->
            nil

          [[permissive, command, public, using, check]] ->
            %{permissive: permissive, command: command, public: public, using: using, check: check}
        end

      {:ok, %{enabled: enabled, forced: forced}, floor, expected}
    end
  end

  # The same floor on a temporary table whose columns copy the protected columns' types.
  defp rebuild(repo, policy, types) do
    if Enum.all?(policy.columns, &Map.has_key?(types, &1)) do
      columns = Enum.map_join(policy.columns, ", ", &~s("#{&1}" #{types[&1]}))

      with {:ok, _} <- query(repo, "SAVEPOINT elzoo_tenant_verify") do
        result =
          with {:ok, _} <-
                 query(repo, "CREATE TEMPORARY TABLE elzoo_tenant_verify (#{columns})"),
               {:ok, _} <-
                 query(
                   repo,
                   "CREATE POLICY elzoo_tenant_floor ON pg_temp.elzoo_tenant_verify AS RESTRICTIVE FOR ALL TO PUBLIC USING (#{policy.floor}) WITH CHECK (#{policy.floor})"
                 ) do
            query(
              repo,
              """
              SELECT pg_get_expr(p.polqual, p.polrelid), pg_get_expr(p.polwithcheck, p.polrelid)
              FROM pg_policy p
              WHERE p.polrelid = 'pg_temp.elzoo_tenant_verify'::regclass AND p.polname = 'elzoo_tenant_floor'
              """
            )
          end

        with {:ok, _} <- query(repo, "ROLLBACK TO SAVEPOINT elzoo_tenant_verify") do
          case result do
            {:ok, %{rows: [[using, check]]}} ->
              {:ok, %{using: using, check: check}}

            {:error, %Postgrex.Error{postgres: %{code: code}}} when code in @rebuildable ->
              {:ok, nil}

            {:error, _} = error ->
              error
          end
        end
      end
    else
      {:ok, nil}
    end
  end

  defp query(repo, sql, params \\ []), do: SQL.query(repo, sql, params, log: false)

  defp scope(%{tenant: tenant} = scope) when map_size(scope) == 1,
    do: if(text?(tenant), do: {:ok, tenant, []}, else: :error)

  defp scope(%{tenant: tenant, spaces: spaces} = scope) when map_size(scope) == 2 do
    if text?(tenant) and within?(spaces, @max_spaces) and Enum.all?(spaces, &text?/1),
      do: {:ok, tenant, spaces},
      else: :error
  end

  defp scope(_), do: :error

  # A proper list of at most n elements, without walking past n.
  defp within?([], _), do: true
  defp within?([_ | rest], n) when n > 0, do: within?(rest, n - 1)
  defp within?(_, _), do: false

  defp text?(t),
    do: is_binary(t) and byte_size(t) in 1..128 and String.valid?(t) and printable?(t)

  # No C0 or C1 control character (U+0000-U+001F, U+007F-U+009F).
  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
