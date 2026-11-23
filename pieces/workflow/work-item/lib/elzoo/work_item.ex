# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.WorkItem do
  @moduledoc """
  The durable record of one item that a parent Run delegated to one child Run, over a
  consumer-owned Ecto Repo on PostgreSQL 16, in the table that
  `Elzoo.WorkItem.Migration.install/1` creates under the `state/tenant-isolation` floor.

  `create/3` stores an item `open` at revision 1 with its stable intent (a
  `workflow/untrusted-content` marked value), its assignee `child_run_id`, its owner and its
  parent-close rule. `start/4`, `offer/4`, `decide/4` and `close/4` move it through the
  lifecycle, each against an expected revision; a no-op writes nothing. A child's result is
  evidence only through `offer/4`, and only `decide/4` by the owner completes an item.
  `list_open/3` returns the non-final items of one parent Run.

  Every ID is an opaque host value. Errors are `{:error, reason}` with a fixed value that never
  echoes an ID or the intent. The Piece emits no telemetry and no log; its queries pass
  `log: false`.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.TenantIsolation
  alias Elzoo.UntrustedContent
  alias Elzoo.WorkItem.Migration

  @enforce_keys [:repo, :prefix]
  defstruct [:repo, :prefix]

  @max_content 4096
  @max_evidence 256
  @max_revision 2_147_483_647
  @max_limit 256
  @item_keys [:acceptance, :child_run_id, :intent, :item_id, :owner, :parent_close, :parent_run_id]
  @acceptances [:parent]
  @parent_closes [:abandon, :request_cancel, :cancel]
  @decisions [:accepted, :rejected]
  @closes [:cancel_requested, :cancelled, :abandoned]
  @non_final [:open, :running, :offered, :cancel_requested]
  @states @non_final ++ [:accepted, :rejected, :cancelled, :abandoned]
  @passed [
    :isolation,
    :unknown_item,
    :conflict,
    :stale_revision,
    :not_assignee,
    :not_owner,
    :unavailable
  ]
  @terms Map.new(@acceptances ++ @parent_closes ++ @states, &{Atom.to_string(&1), &1})
  @columns """
  item_id, parent_run_id, child_run_id, owner, schema_id, schema_version, sources, trust,
  max_bytes, content, acceptance, parent_close, state, revision, evidence, decided_by
  """

  @doc """
  An items value over `repo:` (a started Ecto Repo module) and `prefix:` (the schema of the
  installed table). Raises `ArgumentError` with the migration's fixed message otherwise.
  """
  def new(opts) do
    items =
      Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == [:prefix, :repo] and
        %__MODULE__{repo: opts[:repo], prefix: opts[:prefix]}

    if items?(items), do: items, else: raise(ArgumentError, Migration.message())
  end

  @doc "`Elzoo.TenantIsolation.verify/3` for the item table: `:ok` or `{:error, reason}`."
  def verify(%__MODULE__{repo: repo, prefix: prefix}) do
    TenantIsolation.verify(repo, {prefix, Migration.table()},
      prefix: prefix,
      tenant_column: "tenant",
      space_column: nil
    )
  end

  @doc """
  Store `item`, exactly `%{item_id, parent_run_id, child_run_id, owner, intent, acceptance,
  parent_close}`, `open` at revision 1: `{:ok, :applied}`, `{:ok, :duplicate}` for equal
  canonical bytes under a stored `item_id`, or `{:error, :conflict}` for other bytes or a
  `child_run_id` of another item.
  """
  def create(items, tenant, item) do
    with :ok <- valid(items?(items) and text?(tenant) and item?(item)),
         :ok <- outside(items) do
      writing(items, tenant, &insert(&1, &2, tenant, item))
    end
  end

  @doc "`{:ok, item}` or `{:error, :unknown_item}`."
  def get(items, tenant, item_id) do
    with :ok <- valid(items?(items) and text?(tenant) and text?(item_id)),
         :ok <- outside(items) do
      scoped(items, tenant, &read(&1, &2, tenant, item_id))
    end
  end

  @doc "`open → running`, `%{revision}`."
  def start(items, tenant, item_id, request),
    do: transition(items, tenant, item_id, request, :start, keys?(request, [:revision]))

  @doc "`running → offered`, `%{revision, child_run_id, evidence}`, only from the assignee."
  def offer(items, tenant, item_id, request) do
    valid? =
      keys?(request, [:child_run_id, :evidence, :revision]) and run_id?(request.child_run_id) and
        evidence?(request.evidence)

    transition(items, tenant, item_id, request, :offer, valid?)
  end

  @doc "`offered → accepted | rejected`, `%{revision, decided_by, decision}`, only by the owner."
  def decide(items, tenant, item_id, request) do
    valid? =
      keys?(request, [:decided_by, :decision, :revision]) and text?(request.decided_by) and
        request.decision in @decisions

    transition(items, tenant, item_id, request, :decide, valid?)
  end

  @doc "A closing transition, `%{revision, to: :cancel_requested | :cancelled | :abandoned}`."
  def close(items, tenant, item_id, request) do
    valid? = keys?(request, [:revision, :to]) and request.to in @closes
    transition(items, tenant, item_id, request, :close, valid?)
  end

  @doc """
  The non-final items of one parent Run in `item_id` byte order after `after` (`nil` from the
  start), `%{parent_run_id, after, limit}` with `limit` 1..256:
  `{:ok, %{items: items, more: boolean}}`.
  """
  def list_open(items, tenant, request) do
    with :ok <- valid(items?(items) and text?(tenant) and list_request?(request)),
         :ok <- outside(items),
         {:ok, rows} <- scoped(items, tenant, &open_rows(&1, &2, tenant, request)) do
      {listed, rest} = Enum.split(rows, request.limit)
      {:ok, %{items: Enum.map(listed, &item/1), more: rest != []}}
    end
  end

  # ── transitions (README "Rules") ────────────────────────────────────────

  defp transition(items, tenant, item_id, r, kind, valid?) do
    with :ok <-
           valid(
             valid? and items?(items) and text?(tenant) and text?(item_id) and
               revision?(r.revision)
           ),
         :ok <- outside(items) do
      writing(items, tenant, fn repo, t ->
        with {:ok, item} <- read(repo, t, tenant, item_id) do
          case plan(kind, r, item) do
            {:write, state, facts} ->
              if item.revision == r.revision,
                do: update(repo, t, tenant, item_id, r.revision, state, facts),
                else: {:error, :stale_revision}

            :unchanged ->
              {:ok, :unchanged}

            {:error, _} = error ->
              error
          end
        end
      end)
    end
  end

  # The checks after the read, in the Contract's order: the no-op, the assignee or owner,
  # then the current state. The revision is checked after them, in transition/6.
  defp plan(:start, _r, item) do
    case item.state do
      :running -> :unchanged
      :open -> {:write, :running, %{}}
      state -> {:error, {:state, state}}
    end
  end

  defp plan(:offer, r, item) do
    cond do
      item.state == :offered and item.child_run_id == r.child_run_id and
          item.evidence == r.evidence ->
        :unchanged

      r.child_run_id != item.child_run_id ->
        {:error, :not_assignee}

      item.state == :offered ->
        {:error, :conflict}

      item.state != :running ->
        {:error, {:state, item.state}}

      true ->
        {:write, :offered, %{evidence: r.evidence}}
    end
  end

  defp plan(:decide, r, item) do
    cond do
      item.state == r.decision and item.decided_by == r.decided_by -> :unchanged
      r.decided_by != item.owner -> {:error, :not_owner}
      item.state != :offered -> {:error, {:state, item.state}}
      true -> {:write, r.decision, %{decided_by: r.decided_by}}
    end
  end

  # From open, running or offered to any closing state; from cancel_requested to cancelled
  # or abandoned (cancel_requested to itself is the no-op).
  defp plan(:close, r, item) do
    cond do
      item.state == r.to -> :unchanged
      item.state in @non_final -> {:write, r.to, %{}}
      true -> {:error, {:state, item.state}}
    end
  end

  # One UPDATE guarded by the expected revision: a second writer of the same revision waits
  # for the first under READ COMMITTED and then updates no row.
  defp update(repo, t, tenant, item_id, revision, state, facts) do
    sql = """
    UPDATE #{t}
    SET state = $4, revision = revision + 1, evidence = COALESCE($5, evidence),
        decided_by = COALESCE($6, decided_by)
    WHERE tenant = $1 AND item_id = $2 AND revision = $3
    RETURNING revision
    """

    params = [
      tenant,
      item_id,
      revision,
      Atom.to_string(state),
      Map.get(facts, :evidence),
      Map.get(facts, :decided_by)
    ]

    case query(repo, sql, params) do
      {:ok, %{rows: [[new_revision]]}} -> {:ok, %{revision: new_revision}}
      {:ok, %{rows: []}} -> {:error, :stale_revision}
      {:error, _} -> {:error, :unavailable}
    end
  end

  # ── create ──────────────────────────────────────────────────────────────

  # ON CONFLICT DO NOTHING covers both keys: an equal item_id, and another item's
  # child_run_id. A concurrent insert of either key waits for the first and then does nothing.
  defp insert(repo, t, tenant, item) do
    sql = """
    INSERT INTO #{t} (tenant, item_id, parent_run_id, child_run_id, owner, schema_id,
      schema_version, sources, trust, max_bytes, content, acceptance, parent_close, state,
      revision, digest)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 'open', 1, $14)
    ON CONFLICT DO NOTHING
    """

    m = UntrustedContent.encode(item.intent)
    digest = digest(item)

    params = [
      tenant,
      item.item_id,
      item.parent_run_id,
      item.child_run_id,
      item.owner,
      m["schema_id"],
      m["schema_version"],
      m["sources"],
      m["trust"],
      m["max_bytes"],
      m["content"],
      Atom.to_string(item.acceptance),
      Atom.to_string(item.parent_close),
      digest
    ]

    case query(repo, sql, params) do
      {:ok, %{num_rows: 1}} -> {:ok, :applied}
      {:ok, %{num_rows: 0}} -> stored(repo, t, tenant, item.item_id, digest)
      {:error, _} -> {:error, :unavailable}
    end
  end

  # No row for item_id means the conflict was on another item's child_run_id.
  defp stored(repo, t, tenant, item_id, digest) do
    case query(repo, "SELECT digest FROM #{t} WHERE tenant = $1 AND item_id = $2", [
           tenant,
           item_id
         ]) do
      {:ok, %{rows: [[^digest]]}} -> {:ok, :duplicate}
      {:ok, %{rows: _}} -> {:error, :conflict}
      {:error, _} -> {:error, :unavailable}
    end
  end

  # ── reads ───────────────────────────────────────────────────────────────

  defp read(repo, t, tenant, item_id) do
    sql = "SELECT #{@columns} FROM #{t} WHERE tenant = $1 AND item_id = $2"

    case query(repo, sql, [tenant, item_id]) do
      {:ok, %{rows: [row]}} -> {:ok, item(row)}
      {:ok, %{rows: []}} -> {:error, :unknown_item}
      {:error, _} -> {:error, :unavailable}
    end
  end

  # At most limit + 1 rows: one more tells whether an open item follows.
  defp open_rows(repo, t, tenant, r) do
    sql = """
    SELECT #{@columns} FROM #{t}
    WHERE tenant = $1 AND parent_run_id = $2
      AND state IN ('open', 'running', 'offered', 'cancel_requested')
      AND ($3::text IS NULL OR item_id > $3::text COLLATE "C")
    ORDER BY item_id COLLATE "C"
    LIMIT $4
    """

    case query(repo, sql, [tenant, r.parent_run_id, r.after, r.limit + 1]) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp item(row) do
    [id, parent, child, owner, schema_id, version, sources, trust, max_bytes, content | rest] =
      row

    [acceptance, parent_close, state, revision, evidence, decided_by] = rest

    %{
      item_id: id,
      parent_run_id: parent,
      child_run_id: child,
      owner: owner,
      intent: %{
        "schema_id" => schema_id,
        "schema_version" => version,
        "sources" => sources,
        "trust" => trust,
        "max_bytes" => max_bytes,
        "content" => content
      },
      acceptance: Map.fetch!(@terms, acceptance),
      parent_close: Map.fetch!(@terms, parent_close),
      state: Map.fetch!(@terms, state),
      revision: revision,
      evidence: evidence,
      decided_by: decided_by
    }
  end

  # ── transactions ────────────────────────────────────────────────────────

  defp valid(true), do: :ok
  defp valid(_), do: {:error, :invalid}

  defp outside(items),
    do: if(items.repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok)

  # One tenant-scoped transaction whose first query refuses anything but READ COMMITTED.
  defp writing(items, tenant, fun) do
    scoped(items, tenant, fn repo, t ->
      case query(repo, "SELECT current_setting('transaction_isolation')", []) do
        {:ok, %{rows: [["read committed"]]}} -> fun.(repo, t)
        {:ok, _} -> {:error, :isolation}
        {:error, _} -> {:error, :unavailable}
      end
    end)
  end

  defp scoped(%{repo: repo, prefix: prefix}, tenant, fun) do
    t = "#{Migration.prefix!(prefix)}.#{Migration.table()}"

    case TenantIsolation.transact(repo, %{tenant: tenant}, fn -> fun.(repo, t) end) do
      {:ok, _} = ok -> ok
      {:error, reason} when reason in @passed -> {:error, reason}
      {:error, {:state, state}} when state in @states -> {:error, {:state, state}}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp query(repo, sql, params), do: SQL.query(repo, sql, params, log: false)

  # ── the canonical encoding (README "Canonical bytes") ───────────────────

  defp digest(item) do
    m = UntrustedContent.encode(item.intent)

    intent =
      for key <- Enum.sort(Map.keys(m)) do
        value =
          case m[key] do
            n when is_integer(n) -> Integer.to_string(n)
            list when is_list(list) -> frame(list)
            text -> text
          end

        frame([key, value])
      end

    fields = [
      {"acceptance", Atom.to_string(item.acceptance)},
      {"child_run_id", item.child_run_id},
      {"intent", IO.iodata_to_binary(intent)},
      {"item_id", item.item_id},
      {"owner", item.owner},
      {"parent_close", Atom.to_string(item.parent_close)},
      {"parent_run_id", item.parent_run_id}
    ]

    body = for {name, value} <- Enum.sort(fields), do: frame([name, value])
    :crypto.hash(:sha256, ["elzoo.work-item.item", 0 | body])
  end

  # Each item as <<byte_size(item)::32, item>>.
  defp frame(items),
    do: IO.iodata_to_binary(for(i <- items, do: [<<byte_size(i)::32>>, i]))

  # ── shapes ──────────────────────────────────────────────────────────────

  defp items?(%__MODULE__{repo: repo, prefix: prefix}),
    do: is_atom(repo) and repo not in [nil, true, false] and Migration.prefix?(prefix)

  defp items?(_), do: false

  defp item?(i) do
    keys?(i, @item_keys) and text?(i.item_id) and run_id?(i.parent_run_id) and
      run_id?(i.child_run_id) and text?(i.owner) and intent?(i.intent) and
      i.acceptance in @acceptances and i.parent_close in @parent_closes
  end

  defp list_request?(r) do
    keys?(r, [:after, :limit, :parent_run_id]) and run_id?(r.parent_run_id) and
      (is_nil(r.after) or text?(r.after)) and is_integer(r.limit) and r.limit >= 1 and
      r.limit <= @max_limit
  end

  defp keys?(m, keys),
    do: is_map(m) and map_size(m) == length(keys) and Enum.sort(Map.keys(m)) == keys

  defp revision?(n), do: is_integer(n) and n >= 1 and n <= @max_revision

  defp evidence?(e), do: is_binary(e) and byte_size(e) in 1..@max_evidence

  # A marked value is one that Elzoo.UntrustedContent.decode/1 gives for its own neutral map.
  defp intent?(intent) do
    m = UntrustedContent.encode(intent)

    UntrustedContent.decode(m) == {:ok, intent} and
      byte_size(m["content"]) in 1..@max_content
  rescue
    FunctionClauseError -> false
  end

  # The workflow/run rule: 1..200 bytes of valid UTF-8 without NUL.
  defp run_id?(t),
    do:
      is_binary(t) and byte_size(t) in 1..200 and String.valid?(t) and
        not String.contains?(t, <<0>>)

  # 1..128 bytes of valid UTF-8 without a C0 or C1 control character.
  defp text?(t), do: is_binary(t) and byte_size(t) in 1..128 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
