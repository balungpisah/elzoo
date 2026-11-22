# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.MemoryRecord do
  @moduledoc """
  Scoped memory records over a consumer-owned Ecto Repo on PostgreSQL 16, in the two tables
  that `Elzoo.MemoryRecord.Migration.install/1` creates under the `state/tenant-isolation`
  floor.

  `write/4` stores one immutable record per `{tenant, memory_id}` after the pure
  `check_write/2` allows it under the host's policy (an `:ask` needs an approval of the exact
  `digest/2`); `recall/3` returns the current records of the named scopes and kinds, newest
  first within count and byte bounds, in the `workflow/context-selection` candidate and node
  shape; `forget/3` deletes a record and keeps a tombstone without content; `erase_subject/3`
  forgets a subject's records in resumable batches.

  Cure owns the policy decision (`Cure.Elzoo.MemoryRecord`). Every ID is an opaque host
  value. Errors are `{:error, reason}` with a fixed atom that never echoes an ID or content.
  The Piece emits no telemetry and no log; its queries pass `log: false`.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.MemoryRecord.Migration
  alias Elzoo.TenantIsolation
  alias Elzoo.UntrustedContent

  @enforce_keys [:repo, :prefix]
  defstruct [:repo, :prefix]

  @cure :"Cure.Elzoo.MemoryRecord"
  @max_time 9_007_199_254_740_991
  @max_content 4096
  @scoped [:space, :subject, :bot]
  @kinds [:fact, :preference, :summary]
  @writer_kinds [:human, :service, :agent]
  @provenance_kinds [:run, :message, :artifact, :person]
  @decisions [:allow, :ask, :deny]
  @proposal_keys [
    :content,
    :expires_at_ms,
    :kind,
    :memory_id,
    :provenance,
    :scope,
    :supersedes,
    :written_at_ms,
    :written_by,
    :writer_kind
  ]
  @request_keys [:checked_at, :max_bytes, :max_records, :now_ms, :principal, :scopes]
  @forget_keys [:actor_ref, :forgotten_at_ms, :memory_id, :reason]
  @erase_keys [:actor_ref, :cursor, :forgotten_at_ms, :max_batch, :subject]
  @passed [
    :isolation,
    :forgotten,
    :conflict,
    :unknown_supersedes,
    :already_superseded,
    :unknown_memory,
    :unavailable
  ]
  @scope_terms %{"space" => :space, "subject" => :subject, "bot" => :bot}
  @kind_terms Map.new(@kinds, &{Atom.to_string(&1), &1})

  @doc """
  A memory value over `repo:` (a started Ecto Repo module) and `prefix:` (the schema of the
  installed tables). Raises `ArgumentError` with the migration's fixed message otherwise.
  """
  def new(opts) do
    memory =
      Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == [:prefix, :repo] and
        %__MODULE__{repo: opts[:repo], prefix: opts[:prefix]}

    if memory?(memory), do: memory, else: raise(ArgumentError, Migration.message())
  end

  @doc """
  `{:ok, sha256}` of the README canonical encoding of `tenant` and every proposal field
  except `written_at_ms`, or `{:error, :invalid}`. It decides duplicates and is the digest
  that an approval names.
  """
  def digest(tenant, proposal) do
    if text?(tenant, 128) and proposal?(proposal),
      do: {:ok, digest!(tenant, proposal)},
      else: {:error, :invalid}
  end

  @doc """
  The pure policy decision for a proposal: `:allow`, `{:ask, :policy}`, `{:deny, :policy}`,
  `{:deny, :unlisted}` for a triple `{scope_kind, kind, writer_kind}` that the policy does not
  list, or `{:error, :invalid}`. There is no default policy.
  """
  def check_write(policy, proposal) do
    if policy?(policy) and proposal?(proposal) do
      case decide(policy, proposal) do
        :MemoryAllowed -> :allow
        :MemoryAskPolicy -> {:ask, :policy}
        :MemoryDenyPolicy -> {:deny, :policy}
        :MemoryDenyUnlisted -> {:deny, :unlisted}
      end
    else
      {:error, :invalid}
    end
  end

  @doc """
  Write one proposal under `%{policy: policy}` or `%{policy: policy, approval: %{ref, digest}}`:
  `{:ok, :applied}`, `{:ok, :duplicate}` for an equal digest under a stored `memory_id`, or
  `{:error, reason}`.
  """
  def write(memory, tenant, proposal, opts) do
    valid? =
      memory?(memory) and text?(tenant, 128) and proposal?(proposal) and write_opts?(opts)

    with :ok <- valid(valid?),
         digest = digest!(tenant, proposal),
         :ok <- admit(decide(opts.policy, proposal), approval(opts, digest)),
         :ok <- outside(memory) do
      writing(memory, tenant, &store(&1, &2, memory, tenant, proposal, digest, opts))
    end
  end

  @doc """
  The current records of `request.scopes` (and `request.kinds`, all when absent): not
  superseded, not forgotten and not expired at `now_ms`, newest first, within `max_records`
  and `max_bytes`: `{:ok, %{entries: entries, more: boolean}}`.
  """
  def recall(memory, tenant, request) do
    with :ok <- valid(memory?(memory) and text?(tenant, 128) and request?(request)),
         :ok <- outside(memory),
         {:ok, rows} <- scoped(memory, tenant, &recall_rows(&1, &2, tenant, request)) do
      {entries, more} = within(rows, request.max_records, request.max_bytes, [])
      {:ok, %{entries: Enum.map(entries, &entry(&1, tenant, request)), more: more}}
    end
  end

  @doc """
  Forget one record, `%{memory_id, actor_ref, reason, forgotten_at_ms}`: delete its row and
  keep a tombstone without content or provenance. `{:ok, :applied}`, `{:ok, :duplicate}`
  when already forgotten, or `{:error, :unknown_memory}`.
  """
  def forget(memory, tenant, request) do
    with :ok <- valid(memory?(memory) and text?(tenant, 128) and forget?(request)),
         :ok <- outside(memory) do
      writing(memory, tenant, fn repo, t ->
        with :ok <- lock(repo, memory, tenant, [request.memory_id]),
             {:ok, buried} <- bury(repo, t, tenant, [request.memory_id], request) do
          case buried do
            [_] -> {:ok, :applied}
            [] -> forgotten_before(repo, t, tenant, request.memory_id)
          end
        end
      end)
    end
  end

  @doc """
  Forget one bounded batch of the records of scope `{:subject, subject}`,
  `%{subject, actor_ref, forgotten_at_ms, cursor, max_batch}`: `{:ok, %{forgotten: ids,
  cursor: next}}` with the batch's IDs among records and tombstones together, in byte order
  after `cursor`, and `next` the last of them or `nil` when no ID of the scope follows.
  """
  def erase_subject(memory, tenant, request) do
    with :ok <- valid(memory?(memory) and text?(tenant, 128) and erase?(request)),
         :ok <- outside(memory) do
      writing(memory, tenant, fn repo, t ->
        forget = Map.put(request, :reason, "subject_erasure")

        with {:ok, ids, next} <- batch(repo, t, tenant, request),
             :ok <- lock(repo, memory, tenant, ids),
             {:ok, _} <- bury(repo, t, tenant, ids, forget) do
          {:ok, %{forgotten: ids, cursor: next}}
        end
      end)
    end
  end

  # ── the policy decision (Cure) ──────────────────────────────────────────

  defp decide(policy, p) do
    entry =
      case Map.fetch(policy, {scope_kind(p.scope), p.kind, p.writer_kind}) do
        {:ok, :allow} -> {:MemoryListed, :MemoryAllow}
        {:ok, :ask} -> {:MemoryListed, :MemoryAsk}
        {:ok, :deny} -> {:MemoryListed, :MemoryDeny}
        :error -> :MemoryUnlisted
      end

    apply(@cure, :decide, [entry])
  end

  defp approval(%{approval: %{digest: digest}}, digest), do: :MemoryMatching
  defp approval(%{approval: _}, _), do: :MemoryMismatching
  defp approval(_, _), do: :MemoryNoApproval

  defp admit(decision, approval) do
    case apply(@cure, :admit, [decision, approval]) do
      :MemoryWrite -> :ok
      :MemoryDenied -> {:error, :denied}
      :MemoryApprovalRequired -> {:error, :approval_required}
      :MemoryApprovalMismatch -> {:error, :approval_mismatch}
    end
  end

  # ── transactions ────────────────────────────────────────────────────────

  defp valid(true), do: :ok
  defp valid(_), do: {:error, :invalid}

  defp outside(memory),
    do: if(memory.repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok)

  # One tenant-scoped transaction whose first query refuses anything but READ COMMITTED.
  defp writing(memory, tenant, fun) do
    scoped(memory, tenant, fn repo, t ->
      case query(repo, "SELECT current_setting('transaction_isolation')", []) do
        {:ok, %{rows: [["read committed"]]}} -> fun.(repo, t)
        {:ok, _} -> {:error, :isolation}
        {:error, _} -> {:error, :unavailable}
      end
    end)
  end

  defp scoped(%{repo: repo, prefix: prefix}, tenant, fun) do
    p = Migration.prefix!(prefix)
    t = %{rec: "#{p}.elzoo_memory_records", tomb: "#{p}.elzoo_memory_tombstones"}

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

  # The per-ID lock: each distinct key once, in ascending key order, so two callers never
  # wait on each other in a cycle (README "The per-ID lock").
  defp lock(repo, memory, tenant, ids) do
    ids
    |> Enum.map(&lock_key(memory.prefix, tenant, &1))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case query(repo, "SELECT pg_catalog.pg_advisory_xact_lock($1)", [key]) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  defp lock_key(prefix, tenant, id) do
    <<key::signed-64, _::binary>> =
      :crypto.hash(:sha256, ["elzoo.memory-record.lock", 0, frame([prefix, tenant, id])])

    key
  end

  # ── write ───────────────────────────────────────────────────────────────

  defp store(repo, t, memory, tenant, p, digest, opts) do
    with :ok <- lock(repo, memory, tenant, [p.memory_id | List.wrap(p.supersedes)]),
         :absent <- tombstone(repo, t, tenant, p.memory_id),
         :absent <- existing(repo, t, tenant, p.memory_id, digest),
         :ok <- predecessor(repo, t, tenant, p) do
      insert(repo, t, tenant, p, digest, get_in(opts, [:approval, :ref]))
    end
  end

  defp tombstone(repo, t, tenant, id) do
    case query(repo, "SELECT 1 FROM #{t.tomb} WHERE tenant = $1 AND memory_id = $2", [tenant, id]) do
      {:ok, %{rows: []}} -> :absent
      {:ok, %{rows: [_]}} -> {:error, :forgotten}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp existing(repo, t, tenant, id, digest) do
    sql = "SELECT digest FROM #{t.rec} WHERE tenant = $1 AND memory_id = $2"

    case query(repo, sql, [tenant, id]) do
      {:ok, %{rows: []}} -> :absent
      {:ok, %{rows: [[^digest]]}} -> {:ok, :duplicate}
      {:ok, %{rows: [[_]]}} -> {:error, :conflict}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp predecessor(_repo, _t, _tenant, %{supersedes: nil}), do: :ok

  # The predecessor's lock is held, so its record, scope and successors cannot change here.
  defp predecessor(repo, t, tenant, p) do
    sql = """
    SELECT r.scope_kind, r.scope_id,
           EXISTS (SELECT 1 FROM #{t.rec} s WHERE s.tenant = $1 AND s.supersedes = $2)
           OR EXISTS (SELECT 1 FROM #{t.tomb} s WHERE s.tenant = $1 AND s.supersedes = $2)
    FROM #{t.rec} r WHERE r.tenant = $1 AND r.memory_id = $2
    """

    {scope_kind, scope_id} = scope_columns(p.scope)

    case query(repo, sql, [tenant, p.supersedes]) do
      {:ok, %{rows: [[^scope_kind, ^scope_id, false]]}} -> :ok
      {:ok, %{rows: [[^scope_kind, ^scope_id, true]]}} -> {:error, :already_superseded}
      {:ok, %{rows: _}} -> {:error, :unknown_supersedes}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp insert(repo, t, tenant, p, digest, approval_ref) do
    sql = """
    INSERT INTO #{t.rec} (tenant, memory_id, scope_kind, scope_id, kind, schema_id,
      schema_version, sources, trust, max_bytes, content, provenance_kinds, provenance_ids,
      written_by, writer_kind, written_at_ms, expires_at_ms, supersedes, approval_ref, digest)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18,
      $19, $20)
    """

    {scope_kind, scope_id} = scope_columns(p.scope)
    m = marked!(p.content)

    params = [
      tenant,
      p.memory_id,
      scope_kind,
      scope_id,
      Atom.to_string(p.kind),
      m["schema_id"],
      m["schema_version"],
      m["sources"],
      m["trust"],
      m["max_bytes"],
      m["content"],
      Enum.map(p.provenance, fn {kind, _} -> Atom.to_string(kind) end),
      Enum.map(p.provenance, fn {_, id} -> id end),
      p.written_by,
      Atom.to_string(p.writer_kind),
      p.written_at_ms,
      p.expires_at_ms,
      p.supersedes,
      approval_ref,
      digest
    ]

    case query(repo, sql, params) do
      {:ok, %{num_rows: 1}} -> {:ok, :applied}
      _ -> {:error, :unavailable}
    end
  end

  # ── forget and erase ────────────────────────────────────────────────────

  # Delete the live records of `ids` and keep their tombstones in one statement; the
  # tombstone copies the scope and supersedes, never content or provenance.
  defp bury(_repo, _t, _tenant, [], _request), do: {:ok, []}

  defp bury(repo, t, tenant, ids, r) do
    sql = """
    WITH gone AS (
      DELETE FROM #{t.rec} WHERE tenant = $1 AND memory_id = ANY($2::text[])
      RETURNING tenant, memory_id, scope_kind, scope_id, supersedes
    )
    INSERT INTO #{t.tomb} (tenant, memory_id, scope_kind, scope_id, supersedes,
      forgotten_at_ms, actor_ref, reason)
    SELECT tenant, memory_id, scope_kind, scope_id, supersedes, $3, $4, $5 FROM gone
    RETURNING memory_id
    """

    case query(repo, sql, [tenant, ids, r.forgotten_at_ms, r.actor_ref, r.reason]) do
      {:ok, %{rows: rows}} -> {:ok, List.flatten(rows)}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp forgotten_before(repo, t, tenant, id) do
    case tombstone(repo, t, tenant, id) do
      {:error, :forgotten} -> {:ok, :duplicate}
      :absent -> {:error, :unknown_memory}
      error -> error
    end
  end

  # The first max_batch IDs of the subject after cursor, among records and tombstones, and
  # one more to tell whether an ID follows.
  defp batch(repo, t, tenant, r) do
    sql = """
    SELECT memory_id FROM (
      SELECT memory_id FROM #{t.rec}
      WHERE tenant = $1 AND scope_kind = 'subject' AND scope_id = $2
        AND ($3::text IS NULL OR memory_id > $3::text COLLATE "C")
      UNION
      SELECT memory_id FROM #{t.tomb}
      WHERE tenant = $1 AND scope_kind = 'subject' AND scope_id = $2
        AND ($3::text IS NULL OR memory_id > $3::text COLLATE "C")
    ) ids
    ORDER BY memory_id COLLATE "C"
    LIMIT $4
    """

    case query(repo, sql, [tenant, r.subject, r.cursor, r.max_batch + 1]) do
      {:ok, %{rows: rows}} ->
        {ids, rest} = rows |> List.flatten() |> Enum.split(r.max_batch)
        {:ok, ids, if(rest == [], do: nil, else: List.last(ids))}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  # ── recall ──────────────────────────────────────────────────────────────

  # One statement, so supersession, tombstones and records come from one snapshot. At most
  # max_records + 1 rows: one more tells whether a current record was left out.
  defp recall_rows(repo, t, tenant, r) do
    sql = """
    SELECT r.memory_id, r.scope_kind, r.scope_id, r.kind, r.schema_id, r.schema_version,
           r.sources, r.trust, r.max_bytes, r.content, r.written_at_ms
    FROM #{t.rec} r
    WHERE r.tenant = $1
      AND (r.scope_kind, r.scope_id) IN (SELECT * FROM unnest($2::text[], $3::text[]))
      AND r.kind = ANY($4::text[])
      AND (r.expires_at_ms IS NULL OR r.expires_at_ms > $5)
      AND NOT EXISTS (SELECT 1 FROM #{t.rec} s WHERE s.tenant = r.tenant AND s.supersedes = r.memory_id)
      AND NOT EXISTS (SELECT 1 FROM #{t.tomb} s WHERE s.tenant = r.tenant AND s.supersedes = r.memory_id)
    ORDER BY r.written_at_ms DESC, r.memory_id COLLATE "C"
    LIMIT $6
    """

    {kinds, ids} = r.scopes |> Enum.map(&scope_columns/1) |> Enum.unzip()
    wanted = r |> Map.get(:kinds, @kinds) |> Enum.map(&Atom.to_string/1)

    case query(repo, sql, [tenant, kinds, ids, wanted, r.now_ms, r.max_records + 1]) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, _} -> {:error, :unavailable}
    end
  end

  # Stop at max_records entries or before the first record whose content passes max_bytes.
  defp within([row | rest], records_left, bytes_left, taken) when records_left > 0 do
    size = byte_size(Enum.at(row, 9))

    if size <= bytes_left,
      do: within(rest, records_left - 1, bytes_left - size, [row | taken]),
      else: {Enum.reverse(taken), true}
  end

  defp within(rest, _, _, taken), do: {Enum.reverse(taken), rest != []}

  defp entry(row, tenant, r) do
    [id, scope_kind, scope_id, kind, schema_id, version, sources, trust, max_bytes, content, at] =
      row

    source = "memory:" <> id
    hash = :crypto.hash(:sha256, content)

    marked = %{
      "schema_id" => schema_id,
      "schema_version" => version,
      "sources" => sources,
      "trust" => trust,
      "max_bytes" => max_bytes,
      "content" => content
    }

    %{
      candidate: %{
        item_id: id,
        version: 1,
        source: source,
        content: content,
        content_hash: hash,
        derived_from: [],
        access: %{principal: r.principal, checked_at: r.checked_at, result: :allowed}
      },
      node: %{
        item_id: id,
        version: 1,
        tenant: tenant,
        source: source,
        content_hash: hash,
        derived_from: [],
        check: nil
      },
      scope: scope_term(scope_kind, scope_id),
      kind: Map.fetch!(@kind_terms, kind),
      marked: marked,
      updated_at: at
    }
  end

  defp query(repo, sql, params), do: SQL.query(repo, sql, params, log: false)

  # ── the canonical encoding (README "Proposal digest") ───────────────────

  defp digest!(tenant, p) do
    m = marked!(p.content)

    content =
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
      {"content", IO.iodata_to_binary(content)},
      {"expires_at_ms", if(p.expires_at_ms, do: Integer.to_string(p.expires_at_ms), else: "")},
      {"kind", Atom.to_string(p.kind)},
      {"memory_id", p.memory_id},
      {"provenance", frame(for {kind, id} <- p.provenance, do: frame([Atom.to_string(kind), id]))},
      {"scope", frame(scope_parts(p.scope))},
      {"supersedes", p.supersedes || ""},
      {"tenant", tenant},
      {"written_by", p.written_by},
      {"writer_kind", Atom.to_string(p.writer_kind)}
    ]

    body = for {name, value} <- Enum.sort(fields), do: frame([name, value])
    :crypto.hash(:sha256, ["elzoo.memory-record.proposal", 0 | body])
  end

  # Each item as <<byte_size(item)::32, item>>.
  defp frame(items),
    do: IO.iodata_to_binary(for(i <- items, do: [<<byte_size(i)::32>>, i]))

  # ── shapes ──────────────────────────────────────────────────────────────

  defp memory?(%__MODULE__{repo: repo, prefix: prefix}),
    do: is_atom(repo) and repo not in [nil, true, false] and Migration.prefix?(prefix)

  defp memory?(_), do: false

  defp proposal?(p) do
    keys?(p, @proposal_keys) and text?(p.memory_id, 128) and scope?(p.scope) and
      p.kind in @kinds and content?(p.content) and provenance?(p.provenance) and
      text?(p.written_by, 128) and p.writer_kind in @writer_kinds and time?(p.written_at_ms) and
      (is_nil(p.expires_at_ms) or time?(p.expires_at_ms)) and
      (is_nil(p.supersedes) or (text?(p.supersedes, 128) and p.supersedes != p.memory_id))
  end

  defp policy?(policy) do
    is_map(policy) and not is_struct(policy) and map_size(policy) <= 36 and
      Enum.all?(policy, fn
        {{scope_kind, kind, writer_kind}, decision} ->
          scope_kind in [:tenant | @scoped] and kind in @kinds and writer_kind in @writer_kinds and
            decision in @decisions

        _ ->
          false
      end)
  end

  defp write_opts?(%{policy: policy, approval: a} = opts) when map_size(opts) == 2,
    do:
      policy?(policy) and keys?(a, [:digest, :ref]) and text?(a.ref, 256) and is_binary(a.digest) and
        byte_size(a.digest) == 32

  defp write_opts?(%{policy: policy} = opts) when map_size(opts) == 1, do: policy?(policy)
  defp write_opts?(_), do: false

  defp request?(r) do
    (keys?(r, @request_keys) or
       (keys?(r, [:kinds | @request_keys]) and list?(r.kinds, 3) and distinct?(r.kinds) and
          Enum.all?(r.kinds, &(&1 in @kinds)))) and
      text?(r.principal, 128) and time?(r.checked_at) and list?(r.scopes, 16) and
      distinct?(r.scopes) and Enum.all?(r.scopes, &scope?/1) and
      int?(r.max_records, 1, 256) and int?(r.max_bytes, 1, 1_048_576) and time?(r.now_ms)
  end

  defp forget?(r) do
    keys?(r, @forget_keys) and text?(r.memory_id, 128) and text?(r.actor_ref, 128) and
      reason?(r.reason) and time?(r.forgotten_at_ms)
  end

  defp erase?(r) do
    keys?(r, @erase_keys) and text?(r.subject, 128) and text?(r.actor_ref, 128) and
      time?(r.forgotten_at_ms) and (is_nil(r.cursor) or text?(r.cursor, 128)) and
      int?(r.max_batch, 1, 256)
  end

  defp keys?(m, keys),
    do: is_map(m) and map_size(m) == length(keys) and Enum.sort(Map.keys(m)) == Enum.sort(keys)

  defp scope?({:tenant}), do: true
  defp scope?({kind, id}) when kind in @scoped, do: text?(id, 128)
  defp scope?(_), do: false

  defp scope_kind(scope), do: elem(scope, 0)
  defp scope_parts({:tenant}), do: ["tenant"]
  defp scope_parts({kind, id}), do: [Atom.to_string(kind), id]
  defp scope_columns({:tenant}), do: {"tenant", ""}
  defp scope_columns({kind, id}), do: {Atom.to_string(kind), id}
  defp scope_term("tenant", ""), do: {:tenant}
  defp scope_term(kind, id), do: {Map.fetch!(@scope_terms, kind), id}

  defp content?(content) do
    case marked(content) do
      {:ok, m} -> byte_size(m["content"]) in 1..@max_content
      :error -> false
    end
  end

  # A marked value is one that Elzoo.UntrustedContent.decode/1 gives for its own neutral map.
  defp marked(content) do
    m = UntrustedContent.encode(content)
    if UntrustedContent.decode(m) == {:ok, content}, do: {:ok, m}, else: :error
  rescue
    FunctionClauseError -> :error
  end

  defp marked!(content), do: UntrustedContent.encode(content)

  defp provenance?(refs) do
    list?(refs, 16) and distinct?(refs) and
      Enum.all?(refs, fn
        {kind, id} -> kind in @provenance_kinds and text?(id, 128)
        _ -> false
      end)
  end

  # A proper list of 1..max elements, without walking past max.
  defp list?([_ | _] = list, max), do: within?(list, max)
  defp list?(_, _), do: false
  defp within?([], _), do: true
  defp within?([_ | rest], n) when n > 0, do: within?(rest, n - 1)
  defp within?(_, _), do: false

  defp distinct?(list), do: length(Enum.uniq(list)) == length(list)

  defp reason?(r), do: is_binary(r) and r =~ ~r/\A[a-z0-9_.:-]{1,64}\z/

  defp time?(n), do: int?(n, 0, @max_time)
  defp int?(n, min, max), do: is_integer(n) and n >= min and n <= max

  defp text?(t, max),
    do: is_binary(t) and byte_size(t) in 1..max and String.valid?(t) and printable?(t)

  # No C0 or C1 control character (U+0000-U+001F, U+007F-U+009F).
  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
