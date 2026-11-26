# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Metering do
  @moduledoc """
  Retained usage observations with attributable corrections over a consumer-owned Ecto Repo
  on PostgreSQL 19, in the two tables that `Elzoo.Metering.Migration.install/1` creates under
  the `state/tenant-isolation` floor.

  `record/3` stores one observation per `{tenant, usage_id}`; `correct/3` appends a
  correction and makes its amount the effective amount; `totals/3` sums the known effective
  amounts of one period per unit and source and counts the unknown ones apart, never as zero;
  `model_totals/3` does the same per provider, model, unit and source; `observation/3` reads
  one observation with its corrections in commit order.

  Every ID and the period are opaque host values. Errors are `{:error, reason}` with a fixed
  atom that never echoes an ID or amount. The Piece emits no telemetry and no log; its queries
  pass `log: false`.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.AiModel.Usage
  alias Elzoo.Metering.Migration
  alias Elzoo.TenantIsolation

  @enforce_keys [:repo, :prefix]
  defstruct [:repo, :prefix]

  @max_int 9_223_372_036_854_775_807
  @max_corrections 1024
  @max_rows 1000
  @sources [:estimated, :provider_reported, :unknown]
  @observation_keys [
    :amount,
    :attempt_id,
    :model_id,
    :observed_at_ms,
    :operation_id,
    :period,
    :provider_id,
    :run_id,
    :source,
    :unit,
    :usage_id
  ]
  @correction_keys [:actor_ref, :amount, :correction_id, :reason, :usage_id]
  @passed [:isolation, :conflict, :unknown_usage, :read_limit, :unavailable]

  @doc """
  A meter over `repo:` (a started Ecto Repo module) and `prefix:` (the schema of the
  installed tables). Raises `ArgumentError` with the migration's fixed message otherwise.
  """
  def new(opts) do
    meter =
      Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == [:prefix, :repo] and
        %__MODULE__{repo: opts[:repo], prefix: opts[:prefix]}

    if meter?(meter), do: meter, else: raise(ArgumentError, Migration.message())
  end

  @doc """
  Record one observation, exactly `%{usage_id, run_id, operation_id, attempt_id, provider_id,
  model_id, unit, amount, source, period, observed_at_ms}`: `{:ok, :applied}`,
  `{:ok, :duplicate}` for an equal request under a stored `usage_id`, or
  `{:error, :conflict}` for another.
  """
  def record(meter, tenant, observation) do
    with :ok <- admit(meter, tenant, observation?(observation)) do
      digest = digest("observation", observation_fields(observation))

      write(meter, tenant, &insert(&1, &2, tenant, observation, digest))
    end
  end

  @doc """
  Append a correction, exactly `%{correction_id, usage_id, amount, reason, actor_ref}`, and
  make `amount` the observation's effective amount: `{:ok, :applied}`, `{:ok, :duplicate}`,
  `{:error, :conflict}`, `{:error, :unknown_usage}` or `{:error, :read_limit}` for a
  correction past the 1,024th.
  """
  def correct(meter, tenant, correction) do
    with :ok <- admit(meter, tenant, correction?(correction)) do
      digest = digest("correction", correction_fields(correction))

      write(meter, tenant, fn repo, t ->
        with {:ok, revision} <- lock(repo, t, tenant, correction.usage_id),
             :absent <- existing(repo, t, tenant, correction.correction_id, digest) do
          append(repo, t, tenant, correction, digest, revision)
        end
      end)
    end
  end

  @doc """
  Totals of one period, `%{period, max_rows}` with `max_rows` in 1..1000: `{:ok, rows}`, one
  `%{unit, source, known, unknown_count, count}` per unit and source with an observation,
  sorted by unit then source in Erlang term order, or `{:error, :read_limit}` when there are
  more groups than `max_rows`.
  """
  def totals(meter, tenant, query), do: grouped(meter, tenant, query, [:unit, :source])

  @doc """
  Totals of one period per provider and model, `%{period, max_rows}` as for `totals/3`:
  `{:ok, rows}`, one `%{provider_id, model_id, unit, source, known, unknown_count, count}` per
  `{provider_id, model_id, unit, source}` with an observation, sorted by those four in Erlang
  term order, or `{:error, :read_limit}` when there are more groups than `max_rows`. The rows
  are the `rows` of a `domain/pricing` usage value.
  """
  def model_totals(meter, tenant, query),
    do: grouped(meter, tenant, query, [:provider_id, :model_id, :unit, :source])

  defp grouped(meter, tenant, query, keys) do
    valid? =
      is_map(query) and map_size(query) == 2 and Map.has_key?(query, :period) and
        Map.has_key?(query, :max_rows) and text?(query.period, 128) and
        is_integer(query.max_rows) and query.max_rows in 1..@max_rows

    with :ok <- admit(meter, tenant, valid?),
         {:ok, rows} <- scoped(meter, tenant, &group_rows(&1, &2, tenant, query, keys)) do
      if length(rows) > query.max_rows,
        do: {:error, :read_limit},
        else: {:ok, Enum.sort_by(rows, fn row -> Enum.map(keys, &Map.fetch!(row, &1)) end)}
    end
  end

  @doc """
  One observation with its fields, `effective` and `corrections` (at most 1,024, in commit
  order), or `{:error, :unknown_usage}` for an absent or another tenant's observation.
  """
  def observation(meter, tenant, usage_id) do
    with :ok <- admit(meter, tenant, text?(usage_id, 128)),
         {:ok, rows} <- scoped(meter, tenant, &observation_rows(&1, &2, tenant, usage_id)) do
      case rows do
        [] -> {:error, :unknown_usage}
        [first | _] -> {:ok, observation_value(usage_id, first, rows)}
      end
    end
  end

  # Shape and bounds, then the caller's transaction, both before any query.
  defp admit(meter, tenant, valid?) do
    cond do
      not (meter?(meter) and valid? and text?(tenant, 128)) -> {:error, :invalid}
      meter.repo.in_transaction?() -> {:error, :in_transaction}
      true -> :ok
    end
  end

  defp meter?(%__MODULE__{repo: repo, prefix: prefix}),
    do: is_atom(repo) and repo not in [nil, true, false] and Migration.prefix?(prefix)

  defp meter?(_), do: false

  # One tenant-scoped transaction whose first query refuses anything but READ COMMITTED.
  defp write(meter, tenant, fun) do
    scoped(meter, tenant, fn repo, t ->
      case query(repo, "SELECT current_setting('transaction_isolation')", []) do
        {:ok, %{rows: [["read committed"]]}} -> fun.(repo, t)
        {:ok, _} -> {:error, :isolation}
        {:error, _} -> {:error, :unavailable}
      end
    end)
  end

  defp scoped(%{repo: repo, prefix: prefix}, tenant, fun) do
    p = Migration.prefix!(prefix)
    t = %{obs: "#{p}.elzoo_metering_observations", corr: "#{p}.elzoo_metering_corrections"}

    case TenantIsolation.transact(repo, %{tenant: tenant}, fn -> fun.(repo, t) end) do
      {:ok, _} = ok -> ok
      {:error, reason} when reason in @passed -> {:error, reason}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # A concurrent insert of the same key waits for the other transaction, then does nothing.
  defp insert(repo, t, tenant, o, digest) do
    sql = """
    INSERT INTO #{t.obs} (tenant, usage_id, run_id, operation_id, attempt_id, provider_id,
      model_id, unit, amount, source, period, observed_at_ms, digest, effective, revision)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $9, 0)
    ON CONFLICT (tenant, usage_id) DO NOTHING
    """

    params = [
      tenant,
      o.usage_id,
      o.run_id,
      o.operation_id,
      o.attempt_id,
      o.provider_id,
      o.model_id,
      unit_text(o.unit),
      amount_param(o.amount),
      Atom.to_string(o.source),
      o.period,
      o.observed_at_ms,
      digest
    ]

    case query(repo, sql, params) do
      {:ok, %{num_rows: 1}} ->
        {:ok, :applied}

      {:ok, %{num_rows: 0}} ->
        same_digest(
          repo,
          "SELECT digest FROM #{t.obs} WHERE tenant = $1 AND usage_id = $2",
          [tenant, o.usage_id],
          digest
        )

      _ ->
        {:error, :unavailable}
    end
  end

  defp lock(repo, t, tenant, usage_id) do
    sql = "SELECT revision FROM #{t.obs} WHERE tenant = $1 AND usage_id = $2 FOR UPDATE"

    case query(repo, sql, [tenant, usage_id]) do
      {:ok, %{rows: [[revision]]}} -> {:ok, revision}
      {:ok, %{rows: []}} -> {:error, :unknown_usage}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp existing(repo, t, tenant, correction_id, digest) do
    sql = "SELECT digest FROM #{t.corr} WHERE tenant = $1 AND correction_id = $2"

    case query(repo, sql, [tenant, correction_id]) do
      {:ok, %{rows: []}} -> :absent
      {:ok, %{rows: [[^digest]]}} -> {:ok, :duplicate}
      {:ok, %{rows: [[_]]}} -> {:error, :conflict}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp append(_repo, _t, _tenant, _correction, _digest, revision)
       when revision >= @max_corrections,
       do: {:error, :read_limit}

  # The observation row is locked, so revision + 1 is free; a concurrent insert of the same
  # correction_id for another usage_id waits on the key, then does nothing.
  defp append(repo, t, tenant, c, digest, revision) do
    insert_sql = """
    INSERT INTO #{t.corr} (tenant, correction_id, usage_id, revision, amount, reason, actor_ref, digest)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    ON CONFLICT (tenant, correction_id) DO NOTHING
    """

    update_sql =
      "UPDATE #{t.obs} SET effective = $3, revision = $4 WHERE tenant = $1 AND usage_id = $2"

    amount = amount_param(c.amount)
    next = revision + 1
    params = [tenant, c.correction_id, c.usage_id, next, amount, c.reason, c.actor_ref, digest]

    case query(repo, insert_sql, params) do
      {:ok, %{num_rows: 1}} ->
        case query(repo, update_sql, [tenant, c.usage_id, amount, next]) do
          {:ok, %{num_rows: 1}} -> {:ok, :applied}
          _ -> {:error, :unavailable}
        end

      {:ok, %{num_rows: 0}} ->
        same_digest(
          repo,
          "SELECT digest FROM #{t.corr} WHERE tenant = $1 AND correction_id = $2",
          [tenant, c.correction_id],
          digest
        )

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp same_digest(repo, sql, params, digest) do
    case query(repo, sql, params) do
      {:ok, %{rows: [[^digest]]}} -> {:ok, :duplicate}
      {:ok, %{rows: [[_]]}} -> {:error, :conflict}
      _ -> {:error, :unavailable}
    end
  end

  # max_rows + 1 groups at most: one more than max_rows is the read limit, never a truncation.
  # The group keys are fixed column names of the observations table, never caller input.
  defp group_rows(repo, t, tenant, %{period: period, max_rows: max_rows}, keys) do
    columns = Enum.map_join(keys, ", ", &Atom.to_string/1)

    sql = """
    SELECT #{columns}, COALESCE(sum(effective), 0)::text,
           count(*) FILTER (WHERE effective IS NULL), count(*)
    FROM #{t.obs} WHERE tenant = $1 AND period = $2
    GROUP BY #{columns} LIMIT $3
    """

    case query(repo, sql, [tenant, period, max_rows + 1]) do
      {:ok, %{rows: rows}} ->
        units = unit_terms()

        {:ok,
         Enum.map(rows, fn row ->
           {group, [known, unknown_count, count]} = Enum.split(row, length(keys))

           keys
           |> Enum.zip(group)
           |> Map.new(fn
             {:unit, unit} -> {:unit, Map.fetch!(units, unit)}
             {:source, source} -> {:source, source_term(source)}
             {key, id} -> {key, id}
           end)
           |> Map.merge(%{
             known: String.to_integer(known),
             unknown_count: unknown_count,
             count: count
           })
         end)}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  # One statement, so the observation and its corrections come from one snapshot.
  defp observation_rows(repo, t, tenant, usage_id) do
    sql = """
    SELECT o.run_id, o.operation_id, o.attempt_id, o.provider_id, o.model_id, o.unit, o.amount,
           o.source, o.period, o.observed_at_ms, o.effective,
           c.correction_id, c.amount, c.reason, c.actor_ref
    FROM #{t.obs} o
    LEFT JOIN #{t.corr} c ON c.tenant = o.tenant AND c.usage_id = o.usage_id
    WHERE o.tenant = $1 AND o.usage_id = $2
    ORDER BY c.revision
    LIMIT #{@max_corrections}
    """

    case query(repo, sql, [tenant, usage_id]) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp observation_value(usage_id, first, rows) do
    [run, operation, attempt, provider, model, unit, amount, source, period, at, effective | _] =
      first

    corrections =
      for [_, _, _, _, _, _, _, _, _, _, _, id, c_amount, reason, actor] <- rows, id != nil do
        %{
          correction_id: id,
          usage_id: usage_id,
          amount: amount_term(c_amount),
          reason: reason,
          actor_ref: actor
        }
      end

    %{
      usage_id: usage_id,
      run_id: run,
      operation_id: operation,
      attempt_id: attempt,
      provider_id: provider,
      model_id: model,
      unit: Map.fetch!(unit_terms(), unit),
      amount: amount_term(amount),
      source: source_term(source),
      period: period,
      observed_at_ms: at,
      effective: amount_term(effective),
      corrections: corrections
    }
  end

  defp query(repo, sql, params), do: SQL.query(repo, sql, params, log: false)

  # The canonical encoding (README "Request digest"): a tag, then each present field sorted
  # by name as <<byte_size(name)::32, name, byte_size(value)::32, value>>.
  defp digest(tag, fields) do
    body =
      for {name, value} <- Enum.sort(fields) do
        [<<byte_size(name)::32>>, name, <<byte_size(value)::32>>, value]
      end

    :crypto.hash(:sha256, ["elzoo.metering.", tag, 0 | body])
  end

  defp observation_fields(o) do
    [
      {"amount", amount_text(o.amount)},
      {"attempt_id", o.attempt_id},
      {"model_id", o.model_id},
      {"observed_at_ms", Integer.to_string(o.observed_at_ms)},
      {"operation_id", o.operation_id},
      {"period", o.period},
      {"provider_id", o.provider_id},
      {"run_id", o.run_id},
      {"source", Atom.to_string(o.source)},
      {"unit", unit_text(o.unit)},
      {"usage_id", o.usage_id}
    ]
  end

  defp correction_fields(c) do
    [
      {"actor_ref", c.actor_ref},
      {"amount", amount_text(c.amount)},
      {"correction_id", c.correction_id},
      {"reason", c.reason},
      {"usage_id", c.usage_id}
    ]
  end

  defp observation?(o) do
    is_map(o) and Enum.sort(Map.keys(o)) == @observation_keys and text?(o.usage_id, 128) and
      text?(o.run_id, 200) and text?(o.operation_id, 200) and text?(o.attempt_id, 200) and
      text?(o.provider_id, 128) and text?(o.model_id, 128) and text?(o.period, 128) and
      o.unit in units() and amount?(o.amount) and o.source in @sources and
      int?(o.observed_at_ms)
  end

  defp correction?(c) do
    is_map(c) and Enum.sort(Map.keys(c)) == @correction_keys and
      text?(c.correction_id, 128) and text?(c.usage_id, 128) and amount?(c.amount) and
      text?(c.reason, 256) and text?(c.actor_ref, 128)
  end

  # The counter units of integration/ai-model and one cache-write unit per TTL.
  defp units, do: Usage.units() ++ Enum.map(Usage.ttls(), &{:cache_write_tokens, &1})
  defp unit_terms, do: Map.new(units(), &{unit_text(&1), &1})
  defp unit_text({:cache_write_tokens, ttl}), do: "cache_write_tokens:" <> ttl
  defp unit_text(unit), do: Atom.to_string(unit)

  defp source_term(text), do: Map.fetch!(Map.new(@sources, &{Atom.to_string(&1), &1}), text)

  defp amount?(amount), do: amount == :unknown or int?(amount)
  defp int?(n), do: is_integer(n) and n >= 0 and n <= @max_int
  defp amount_param(:unknown), do: nil
  defp amount_param(n), do: n
  defp amount_term(nil), do: :unknown
  defp amount_term(n), do: n
  defp amount_text(:unknown), do: "unknown"
  defp amount_text(n), do: Integer.to_string(n)

  defp text?(t, max),
    do: is_binary(t) and byte_size(t) in 1..max and String.valid?(t) and printable?(t)

  # No C0 or C1 control character (U+0000-U+001F, U+007F-U+009F).
  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
