# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DeadLetterStore do
  @moduledoc """
  Retained `delivery/dead-letter` records in one table under the `state/tenant-isolation` floor,
  over a consumer-owned Ecto Repo on PostgreSQL 16.

  A record is stored once per `(tenant, source, message_id)` and stays open until `resolve/3`
  sets it once as `:replayed` or `:discarded`. `list/3` pages the open records of one source,
  `count/2` counts them per source and `purge/3` deletes resolved records. The Piece stores no
  payload and dispatches nothing.

  Each function checks shape, then the caller's open transaction, both before any query, and
  then runs one transaction through `Elzoo.TenantIsolation.transact/3` whose first query refuses
  any isolation level but read committed. Errors are fixed atoms that never echo an ID. Queries
  run with `log: false`.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.DeadLetterStore.Migration

  @enforce_keys [:repo, :prefix]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{repo: module(), prefix: String.t()}

  @max_time 9_223_372_036_854_775_807
  @max_message_id 256
  @max_record 16_384
  @max_work_ref 256
  @max_limit 1000
  @max_sources 1000
  @resolutions %{replayed: "replayed", discarded: "discarded"}

  @doc """
  Build a store from exactly `repo:` (an Ecto Repo module) and `prefix:` (the schema that
  `Migration.install/1` used). Raises `ArgumentError` with a fixed message otherwise.
  """
  def new(opts) do
    if Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == [:prefix, :repo] and
         is_atom(opts[:repo]) do
      %__MODULE__{repo: opts[:repo], prefix: Migration.prefix!(opts[:prefix])}
    else
      raise ArgumentError, Migration.message()
    end
  end

  @doc """
  Store `record` (a valid `delivery/dead-letter` map) under its `message_id`. Returns
  `{:ok, :applied}`, `{:ok, :duplicate}` for the same key with equal canonical record bytes and
  `work_ref` (whether open or resolved), or `{:error, :conflict}` for the same key with others.
  """
  def put(store, tenant, %{source: source, record: record, work_ref: work_ref, at_ms: at} = req)
      when map_size(req) == 4 do
    with true <-
           store?(store) and text?(tenant) and text?(source) and work_ref?(work_ref) and time?(at),
         {:ok, message_id, bytes} <- canonical(record) do
      run(store, tenant, fn s -> insert(s, [tenant, source, message_id, bytes, work_ref, at], 2) end)
    else
      :record -> {:error, :record}
      _ -> {:error, :invalid}
    end
  end

  def put(_, _, _), do: {:error, :invalid}

  @doc """
  Resolve an open record once as `:replayed` or `:discarded`. Returns `{:ok, :applied}`,
  `{:ok, :duplicate}` when it is already resolved with equal fields, `{:error, :already_resolved}`
  when it is resolved with others, or `{:error, :unknown_record}`.
  """
  def resolve(
        store,
        tenant,
        %{source: source, message_id: id, resolution: resolution, actor_ref: actor, at_ms: at} =
          req
      )
      when map_size(req) == 5 do
    if store?(store) and text?(tenant) and text?(source) and key?(id) and
         is_map_key(@resolutions, resolution) and text?(actor) and time?(at) do
      run(store, tenant, fn s ->
        update(s, [tenant, source, id, Map.fetch!(@resolutions, resolution), actor, at], 2)
      end)
    else
      {:error, :invalid}
    end
  end

  def resolve(_, _, _), do: {:error, :invalid}

  @doc """
  Open records of one tenant and source, oldest first by `(put_at_ms, message_id)` bytes, at
  most `limit` (1..1000) after the cursor `after` (`nil` or a `next` value). Returns
  `{:ok, %{entries: [%{message_id, record, work_ref, put_at_ms}], next: cursor | nil}}`.
  """
  def list(store, tenant, %{source: source, after: cursor, limit: limit} = req)
      when map_size(req) == 3 do
    with true <- store?(store) and text?(tenant) and text?(source) and limit?(limit),
         {:ok, position} <- cursor(cursor) do
      run(store, tenant, fn s -> page(s, tenant, source, position, limit) end)
    else
      _ -> {:error, :invalid}
    end
  end

  def list(_, _, _), do: {:error, :invalid}

  @doc """
  `{:ok, [%{source, open}]}` for the sources of `tenant` with at least one open record, sorted by
  source bytes, or `{:error, :read_limit}` when more than 1,000 sources have one.
  """
  def count(store, tenant) do
    if store?(store) and text?(tenant) do
      run(store, tenant, fn s ->
        rows =
          q!(
            s,
            ~s|SELECT source, count(*) FROM #{s.prefix}.elzoo_dead_letters WHERE tenant = $1 AND state = 'open' GROUP BY source ORDER BY source COLLATE "C" LIMIT $2|,
            [tenant, @max_sources + 1]
          )

        if length(rows) > @max_sources,
          do: {:error, :read_limit},
          else: {:ok, Enum.map(rows, fn [source, open] -> %{source: source, open: open} end)}
      end)
    else
      {:error, :invalid}
    end
  end

  @doc """
  Delete up to `limit` (1..1000) resolved records of `tenant` with `resolved_at_ms < before_ms`,
  oldest `resolved_at_ms` first. Returns `{:ok, deleted_count}`; open records are never purged.
  """
  def purge(store, tenant, %{before_ms: before, limit: limit} = req) when map_size(req) == 2 do
    if store?(store) and text?(tenant) and time?(before) and limit?(limit) do
      run(store, tenant, fn s ->
        %{num_rows: n} =
          query!(
            s,
            """
            DELETE FROM #{s.prefix}.elzoo_dead_letters
            WHERE (tenant, source, message_id) IN (
              SELECT tenant, source, message_id FROM #{s.prefix}.elzoo_dead_letters
              WHERE tenant = $1 AND state = 'resolved' AND resolved_at_ms < $2
              ORDER BY resolved_at_ms, source COLLATE "C", message_id COLLATE "C"
              LIMIT $3
            ) AND state = 'resolved'
            """,
            [tenant, before, limit]
          )

        {:ok, n}
      end)
    else
      {:error, :invalid}
    end
  end

  def purge(_, _, _), do: {:error, :invalid}

  # ---------------------------------------------------------------- transaction

  # Shape, store included, was checked by the caller. Then the caller's transaction, then one
  # transaction under the tenant floor whose first query checks the isolation level. Any failure of the Repo, the
  # database or the driver is :unavailable; nothing raised reaches the caller, so no driver
  # message (which can quote parameters) does either.
  defp run(%__MODULE__{repo: repo} = s, tenant, fun) do
    if repo.in_transaction?() do
      {:error, :in_transaction}
    else
      result =
        Elzoo.TenantIsolation.transact(repo, %{tenant: tenant}, fn ->
          case q!(s, "SELECT current_setting('transaction_isolation')", []) do
            [["read committed"]] -> fun.(s)
            _ -> {:error, :isolation}
          end
        end)

      case result do
        {:ok, _} = ok -> ok
        {:error, reason} when reason in [:isolation, :conflict, :already_resolved] -> result
        {:error, reason} when reason in [:unknown_record, :read_limit] -> result
        _ -> {:error, :unavailable}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # ON CONFLICT DO NOTHING waits for a concurrent insert of the same key, then the next statement
  # reads the committed row. A row that a concurrent purge deleted in between is put again.
  defp insert(s, [tenant, source, id, bytes, work_ref, _at] = args, tries) do
    inserted =
      q!(
        s,
        "INSERT INTO #{s.prefix}.elzoo_dead_letters (tenant, source, message_id, record, work_ref, put_at_ms, state) VALUES ($1, $2, $3, $4, $5, $6, 'open') ON CONFLICT DO NOTHING RETURNING 1",
        args
      )

    if inserted == [[1]] do
      {:ok, :applied}
    else
      case q!(
             s,
             "SELECT record, work_ref FROM #{s.prefix}.elzoo_dead_letters WHERE tenant = $1 AND source = $2 AND message_id = $3",
             [tenant, source, id]
           ) do
        [[^bytes, ^work_ref]] -> {:ok, :duplicate}
        [_] -> {:error, :conflict}
        [] when tries > 1 -> insert(s, args, tries - 1)
        [] -> {:error, :unavailable}
      end
    end
  end

  # Only an open row is updated. A concurrent resolve that holds the row lock and commits first
  # leaves this update with no row; the next statement reads its result.
  defp update(s, [tenant, source, id, resolution, actor, at] = args, tries) do
    updated =
      q!(
        s,
        "UPDATE #{s.prefix}.elzoo_dead_letters SET state = 'resolved', resolution = $4, actor_ref = $5, resolved_at_ms = $6 WHERE tenant = $1 AND source = $2 AND message_id = $3 AND state = 'open' RETURNING 1",
        args
      )

    if updated == [[1]] do
      {:ok, :applied}
    else
      case q!(
             s,
             "SELECT state, resolution, actor_ref, resolved_at_ms FROM #{s.prefix}.elzoo_dead_letters WHERE tenant = $1 AND source = $2 AND message_id = $3",
             [tenant, source, id]
           ) do
        [] -> {:error, :unknown_record}
        [["resolved", ^resolution, ^actor, ^at]] -> {:ok, :duplicate}
        [["resolved" | _]] -> {:error, :already_resolved}
        # Purged and put again between the two statements.
        [["open" | _]] when tries > 1 -> update(s, args, tries - 1)
        [_] -> {:error, :unavailable}
      end
    end
  end

  defp page(s, tenant, source, position, limit) do
    {after_sql, params} =
      case position do
        nil ->
          {"", [tenant, source, limit + 1]}

        {at, id} ->
          {~s| AND (put_at_ms, message_id COLLATE "C") > ($4, $5)|,
           [tenant, source, limit + 1, at, id]}
      end

    rows =
      q!(
        s,
        ~s|SELECT message_id, record, work_ref, put_at_ms FROM #{s.prefix}.elzoo_dead_letters WHERE tenant = $1 AND source = $2 AND state = 'open'#{after_sql} ORDER BY put_at_ms, message_id COLLATE "C" LIMIT $3|,
        params
      )

    entries =
      rows
      |> Enum.take(limit)
      |> Enum.map(fn [id, record, work_ref, at] ->
        %{message_id: id, record: Jason.decode!(record), work_ref: work_ref, put_at_ms: at}
      end)

    next =
      case {length(rows) > limit, List.last(entries)} do
        {true, last} -> encode_cursor(last.put_at_ms, last.message_id)
        _ -> nil
      end

    {:ok, %{entries: entries, next: next}}
  end

  defp q!(s, sql, params), do: query!(s, sql, params).rows
  defp query!(s, sql, params), do: SQL.query!(s.repo, sql, params, log: false)

  # ---------------------------------------------------------------- shapes

  # The record's message_id and its canonical bytes: Elzoo.DeadLetter.encode/1 of the decoded
  # record as JSON with keys in byte order and no white space.
  defp canonical(record) do
    with {:ok, decoded} <- Elzoo.DeadLetter.decode(record),
         map = Elzoo.DeadLetter.encode(decoded),
         id = map["message_id"],
         true <- byte_size(id) <= @max_message_id,
         true <- not Enum.any?(Map.values(map), &(is_binary(&1) and String.contains?(&1, <<0>>))),
         bytes = map |> Enum.sort() |> Jason.OrderedObject.new() |> Jason.encode!(),
         true <- byte_size(bytes) <= @max_record do
      {:ok, id, bytes}
    else
      _ -> :record
    end
  end

  # nil, or <<"c1.">> and base64url of <<put_at_ms::64, message_id::binary>>.
  defp encode_cursor(at, id), do: "c1." <> Base.url_encode64(<<at::64, id::binary>>, padding: false)

  defp cursor(nil), do: {:ok, nil}

  defp cursor(<<"c1.", encoded::binary>>) when byte_size(encoded) <= 400 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, <<at::64, id::binary>>} -> if time?(at) and key?(id), do: {:ok, {at, id}}, else: :error
      _ -> :error
    end
  end

  defp cursor(_), do: :error

  # A stored key: 1..256 bytes of valid UTF-8 without U+0000.
  defp key?(id),
    do:
      is_binary(id) and byte_size(id) in 1..@max_message_id and String.valid?(id) and
        not String.contains?(id, <<0>>)

  defp store?(%__MODULE__{repo: repo, prefix: prefix}), do: is_atom(repo) and is_binary(prefix)
  defp store?(_), do: false

  defp work_ref?(nil), do: true
  defp work_ref?(ref), do: is_binary(ref) and byte_size(ref) in 1..@max_work_ref

  defp time?(t), do: is_integer(t) and t >= 0 and t <= @max_time
  defp limit?(n), do: is_integer(n) and n >= 1 and n <= @max_limit

  # The domain/principal text rule: 1..128 bytes of valid UTF-8 with no C0 (U+0000..U+001F) or
  # C1 (U+007F..U+009F) character.
  defp text?(t) when is_binary(t) and byte_size(t) in 1..128, do: String.valid?(t) and printable?(t)
  defp text?(_), do: false

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
