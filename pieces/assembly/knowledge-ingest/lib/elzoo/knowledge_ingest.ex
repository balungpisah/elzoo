# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.KnowledgeIngest do
  @moduledoc """
  Durable ingest of one `state/artifact` version of a tenant's document: parse, chunk, embed and
  index it as bounded Oban jobs (`integration/jobs`) over a consumer-owned Ecto Repo on
  PostgreSQL 16, with a durable ingest record, staged chunks and counted embedding attempts in
  the Piece tables under the `state/tenant-isolation` floor.

  `new/1` builds the config, `runner/1` the map the host registers with
  `Elzoo.Jobs.register/2`, `verify/1` checks the floor of each table, and `submit/3`,
  `status/3`, `attempts/3`, `cancel/3` and `resubmit/3` act on one ingest
  `(tenant, source_ref, version)`. No public function raises for any term in any argument,
  except `Elzoo.KnowledgeIngest.Migration.install/1`. Errors are fixed atoms that never echo a
  source reference, content or vector. The Contract is in the Piece README.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.{AiEmbedding, AiModel, Artifact, DocumentParse, Jobs, SearchData}
  alias Elzoo.{TenantIsolation, TextChunking}
  alias Elzoo.AiEmbedding.Request
  alias Elzoo.KnowledgeIngest.{Migration, Steps}

  @enforce_keys [
    :repo,
    :prefix,
    :oban,
    :queue,
    :search,
    :artifact,
    :artifact_scopes,
    :embedding,
    :request,
    :intent,
    :max_attempts,
    :limits,
    :seam
  ]
  defstruct @enforce_keys

  @keys [
    :repo,
    :prefix,
    :oban,
    :queue,
    :search,
    :artifact,
    :artifact_scopes,
    :embedding,
    :request,
    :intent,
    :max_attempts
  ]
  @required @keys -- [:max_attempts]
  @request_keys [:model, :dimensions, :input_type, :provider_options]
  @media_types ["text/plain", "text/markdown", "text/html"]
  @chunking_keys [:chunk_size, :chunk_overlap, :max_chunks]
  @max_version 2_147_483_647
  @live_jobs ~w(available scheduled executing retryable)
  @states %{
    "requested" => :requested,
    "preparing" => :preparing,
    "embedding" => :embedding,
    "indexing" => :indexing,
    "indexed" => :indexed,
    "failed" => :failed,
    "cancelled" => :cancelled,
    "superseded" => :superseded
  }
  @terminal ~w(indexed cancelled superseded)
  @passed [
    :invalid,
    :in_transaction,
    :isolation,
    :conflict,
    :not_found,
    :indexing,
    :terminal,
    :not_failed,
    :unavailable
  ]
  # The ingest row's columns, in table order; a fetched row is a map of these keys.
  @fields [
    :tenant,
    :ingest_id,
    :source_ref,
    :version,
    :request_digest,
    :index_identity,
    :actor,
    :artifact_id,
    :artifact_version,
    :media_type,
    :chunk_size,
    :chunk_overlap,
    :max_chunks,
    :state,
    :reason,
    :failed_step,
    :job_key,
    :jobs,
    :text_sha256,
    :parser,
    :chunk_count,
    :batch_count,
    :batches_done
  ]
  @columns Enum.map_join(@fields, ", ", &Atom.to_string/1)

  ## Construction

  @doc """
  Builds the config from exactly the keys `repo`, `prefix`, `oban`, `queue`, `search`,
  `artifact`, `artifact_scopes`, `embedding`, `request`, `intent` and the optional
  `max_attempts` (1..5, default 3). Returns `{:ok, config}` or `{:error, :invalid}`.
  """
  def new(opts), do: __new__(opts, %{})

  # Test seam: the same construction with a seam map that may hold `deadlines` (a map of
  # step to ms), `wait_ms` (the delivery wait) and `hook` (a 2-arity function called at named
  # points of the steps). `new/1` passes an empty map.
  @doc false
  def __new__(opts, seam) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 in @keys)) and Enum.all?(@required, &(&1 in keys)),
         o = Map.new(opts),
         true <- repo?(o.repo) and Migration.prefix?(o.prefix),
         true <- Oban.config(o.oban).repo == o.repo,
         true <- is_binary(o.queue) and byte_size(o.queue) in 1..64,
         true <- search?(o.search),
         true <- match?(%Elzoo.Artifact{}, o.artifact),
         true <- scopes?(o.artifact_scopes),
         true <- intent?(o.intent),
         max = Map.get(o, :max_attempts, 3),
         true <- is_integer(max) and max in 1..5,
         {:ok, probe} <- probe(o.embedding),
         true <- probe.max_input_bytes >= 8_000,
         true <- request?(o.request, probe, o.search) do
      {:ok,
       %__MODULE__{
         repo: o.repo,
         prefix: o.prefix,
         oban: o.oban,
         queue: o.queue,
         search: o.search,
         artifact: o.artifact,
         artifact_scopes: o.artifact_scopes,
         embedding: o.embedding,
         request: o.request,
         intent: o.intent,
         max_attempts: max,
         limits:
           Map.take(probe, [:max_inputs, :max_input_bytes, :max_request_bytes, :receive_timeout_ms]),
         seam: seam
       }}
    else
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  catch
    _, _ -> {:error, :invalid}
  end

  defp repo?(repo),
    do:
      is_atom(repo) and repo not in [nil, true, false] and Code.ensure_loaded?(repo) and
        function_exported?(repo, :in_transaction?, 0) and function_exported?(repo, :transact, 2)

  # A binding is what SearchData.new/3 builds from its own members, with or without the floor.
  defp search?(%{repo: repo, declaration: d, prefix: p, statement_timeout_ms: t} = b) do
    floor = Map.take(b, [:tenant_isolation]) |> Map.to_list()
    SearchData.new(repo, d, [prefix: p, statement_timeout_ms: t] ++ floor) == {:ok, b}
  end

  defp search?(_), do: false

  defp scopes?(scopes),
    do:
      is_list(scopes) and length(scopes) <= 16 and
        Enum.all?(
          scopes,
          &(is_binary(&1) and String.valid?(&1) and not String.contains?(&1, <<0>>))
        )

  defp intent?(%{store: {module, store_opts}, host: {host, _}, clock: clock} = i)
       when is_atom(module) and is_map(store_opts) and is_atom(host) and is_function(clock, 0) do
    memory? = module == Elzoo.DurableLog.Memory

    case Map.keys(i) -- [:store, :host, :clock] do
      [] -> not memory?
      [:allow_volatile] -> memory? and i.allow_volatile == true
      _ -> false
    end
  end

  defp intent?(_), do: false

  defp probe(embedding) do
    if Keyword.keyword?(embedding) and not Keyword.has_key?(embedding, :tenant) and
         not Keyword.has_key?(embedding, :sink),
       do: AiEmbedding.configure(embedding ++ [tenant: "probe", sink: fn _, _ -> :ok end]),
       else: :error
  end

  defp request?(%{model: model} = r, probe, search) do
    descriptor = search.declaration.descriptor

    Enum.all?(Map.keys(r), &(&1 in @request_keys)) and
      match?({:ok, _}, AiEmbedding.admission(probe, declaration(r, "probe", ["probe"], 0))) and
      model == descriptor.model and
      AiEmbedding.expected_dimensions(probe, %{model: model, dimensions: r[:dimensions]}) ==
        descriptor.dimensions
  end

  defp request?(_, _, _), do: false

  ## Host composition

  @doc """
  The `%{perform: fun/1, backoff: fun/1}` map that the host registers with
  `Elzoo.Jobs.register(config.queue, runner)`.
  """
  def runner(config), do: Steps.runner(config)

  @doc """
  Runs `Elzoo.TenantIsolation.verify/3` over each Piece table, as the application role; `:ok` or
  the first `{:error, reason}`.
  """
  def verify(%__MODULE__{} = c) do
    Enum.reduce_while(Migration.tables(), :ok, fn table, :ok ->
      case TenantIsolation.verify(c.repo, {c.prefix, table},
             prefix: c.prefix,
             tenant_column: "tenant",
             space_column: nil
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  def verify(_), do: {:error, :invalid}

  ## Operations

  @doc """
  Submits one ingest: `caller` is exactly `%{tenant, actor}` and `request` exactly
  `%{source_ref, version, artifact: %{artifact_id, version}, media_type, chunking}`. Returns
  `{:ok, status}`, or `{:error, reason}` with `:invalid`, `:in_transaction`, `:isolation`,
  `:conflict` or `:unavailable`.
  """
  def submit(c, caller, request) do
    with {:ok, r} <- check(c, caller, fn -> request(c, request) end) do
      scoped(c, caller.tenant, true, fn -> submit_scoped(c, caller, r) end)
    end
  end

  defp submit_scoped(c, caller, r) do
    hook(c, :submit, %{})
    tenant = caller.tenant
    id = ingest_id(c, tenant, r.source_ref, r.version)
    digest = request_digest(c, tenant, r)

    inserted =
      q(
        c,
        """
        INSERT INTO #{table(c, :ingests)} (#{@columns})
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 'requested', NULL, NULL,
          NULL, 0, NULL, NULL, 0, 0, 0)
        ON CONFLICT (tenant, ingest_id) DO NOTHING
        RETURNING ingest_id
        """,
        [
          tenant,
          id,
          r.source_ref,
          r.version,
          digest,
          index_identity(c),
          caller.actor,
          r.artifact_id,
          r.artifact_version,
          r.media_type,
          r.chunk_size,
          r.chunk_overlap,
          r.max_chunks
        ]
      )

    row = lock(c, tenant, id)

    cond do
      inserted.num_rows == 1 ->
        with :ok <- schedule(c, row, :prepare, 0), do: {:ok, status_of(c, tenant, id)}

      row.request_digest != digest ->
        {:error, :conflict}

      row.state in @terminal or row.state == "failed" ->
        {:ok, status_of(c, tenant, id)}

      true ->
        {step, batch} = current_step(row)

        case Jobs.state(c.oban, c.queue, row.job_key) do
          {:ok, {_, state}} when state in @live_jobs ->
            {:ok, status_of(c, tenant, id)}

          {:ok, _} ->
            with :ok <- schedule(c, row, step, batch), do: {:ok, status_of(c, tenant, id)}

          _ ->
            {:error, :unavailable}
        end
    end
  end

  defp current_step(%{state: s}) when s in ["requested", "preparing"], do: {:prepare, 0}
  defp current_step(%{state: "embedding", batches_done: b}), do: {:embed, b}
  defp current_step(%{state: "indexing"}), do: {:index, 0}

  @doc """
  The status of one ingest, `%{source_ref, version, state, reason, batches: %{done, total},
  attempts, text_sha256, parser}`; another tenant's or an absent ingest is `:not_found`.
  """
  def status(c, caller, ref) do
    with {:ok, {source_ref, version}} <- check(c, caller, fn -> ref(ref) end) do
      id = ingest_id(c, caller.tenant, source_ref, version)

      scoped(c, caller.tenant, false, fn ->
        case status_of(c, caller.tenant, id) do
          nil -> {:error, :not_found}
          status -> {:ok, status}
        end
      end)
    end
  end

  @doc """
  One page of the attempts of one ingest, `%{source_ref, version, after, limit}` with `after`
  `nil` or a cursor from an earlier page and `limit` 1..256: `{:ok, %{entries, next}}`, each
  entry exactly `%{ref, batch, number, outcome, usage}` in `(batch, number)` order.
  """
  def attempts(c, caller, page) do
    valid = fn ->
      with %{after: cursor, limit: limit} when map_size(page) == 4 <- page,
           {:ok, key} <- ref(Map.take(page, [:source_ref, :version])),
           true <- is_integer(limit) and limit in 1..256,
           {:ok, from} <- cursor(cursor) do
        {:ok, {key, limit, from}}
      else
        _ -> :error
      end
    end

    with {:ok, {{source_ref, version}, limit, {b, n}}} <- check(c, caller, valid) do
      tenant = caller.tenant
      id = ingest_id(c, tenant, source_ref, version)

      scoped(c, tenant, false, fn ->
        if fetch(c, tenant, id, false) == nil do
          {:error, :not_found}
        else
          rows =
            q(
              c,
              """
              SELECT batch, number, outcome, usage FROM #{table(c, :attempts)}
              WHERE tenant = $1 AND ingest_id = $2 AND (batch, number) > ($3, $4)
              ORDER BY batch, number LIMIT $5
              """,
              [tenant, id, b, n, limit + 1]
            ).rows

          entries =
            rows
            |> Enum.take(limit)
            |> Enum.map(fn [batch, number, outcome, usage] ->
              %{
                ref: attempt_ref(id, batch, number),
                batch: batch,
                number: number,
                outcome: decode(outcome),
                usage: decode(usage)
              }
            end)

          next =
            if length(rows) > limit,
              do: entries |> List.last() |> then(&{&1.batch, &1.number}),
              else: nil

          {:ok, %{entries: entries, next: next}}
        end
      end)
    end
  end

  defp cursor(nil), do: {:ok, {-1, -1}}

  defp cursor({b, n})
       when is_integer(b) and is_integer(n) and b in 0..@max_version and n in 0..@max_version,
       do: {:ok, {b, n}}

  defp cursor(_), do: :error

  @doc """
  Cancels one ingest: `cancelled` from `requested`, `preparing`, `embedding` or `failed`, with its
  staged chunks deleted; `cancelled` again in `cancelled`; `:indexing` in `indexing`; `:terminal`
  in `indexed` or `superseded`.
  """
  def cancel(c, caller, ref) do
    with {:ok, {source_ref, version}} <- check(c, caller, fn -> ref(ref) end) do
      tenant = caller.tenant
      id = ingest_id(c, tenant, source_ref, version)

      scoped(c, tenant, true, fn ->
        case lock(c, tenant, id) do
          nil ->
            {:error, :not_found}

          %{state: "cancelled"} ->
            {:ok, status_of(c, tenant, id)}

          %{state: s} when s in ["requested", "preparing", "embedding", "failed"] ->
            q(
              c,
              """
              UPDATE #{table(c, :ingests)} SET state = 'cancelled', reason = NULL, failed_step = NULL
              WHERE tenant = $1 AND ingest_id = $2
              """,
              [tenant, id]
            )

            delete_chunks(c, tenant, id)
            {:ok, status_of(c, tenant, id)}

          %{state: "indexing"} ->
            {:error, :indexing}

          _ ->
            {:error, :terminal}
        end
      end)
    end
  end

  @doc """
  Restarts a `failed` ingest at the step that recorded the failure, with a new job; an embed
  restart gets a fresh budget of `max_attempts`. `:terminal` in a terminal state, `:not_failed` in
  any other state.
  """
  def resubmit(c, caller, ref) do
    with {:ok, {source_ref, version}} <- check(c, caller, fn -> ref(ref) end) do
      tenant = caller.tenant
      id = ingest_id(c, tenant, source_ref, version)

      scoped(c, tenant, true, fn ->
        case lock(c, tenant, id) do
          nil -> {:error, :not_found}
          %{state: s} when s in @terminal -> {:error, :terminal}
          %{state: "failed"} = row -> restart(c, row)
          _ -> {:error, :not_failed}
        end
      end)
    end
  end

  defp restart(c, row) do
    {state, step} =
      Map.fetch!(
        %{
          "prepare" => {"requested", :prepare},
          "embed" => {"embedding", :embed},
          "index" => {"indexing", :index}
        },
        row.failed_step
      )

    if step == :embed do
      q(
        c,
        """
        UPDATE #{table(c, :batches)} b SET budget_base = COALESCE(
          (SELECT max(number) FROM #{table(c, :attempts)} a
           WHERE a.tenant = b.tenant AND a.ingest_id = b.ingest_id AND a.batch = b.batch), 0)
        WHERE b.tenant = $1 AND b.ingest_id = $2 AND b.batch = $3
        """,
        [row.tenant, row.ingest_id, row.batches_done]
      )
    end

    q(
      c,
      """
      UPDATE #{table(c, :ingests)} SET state = $3, reason = NULL, failed_step = NULL
      WHERE tenant = $1 AND ingest_id = $2
      """,
      [row.tenant, row.ingest_id, state]
    )

    with :ok <- schedule(c, row, step, row.batches_done),
         do: {:ok, status_of(c, row.tenant, row.ingest_id)}
  end

  ## Validation

  # Shape and bounds, then the caller's transaction, both before any query.
  defp check(c, caller, valid) do
    with true <- match?(%__MODULE__{}, c) and caller?(caller),
         {:ok, value} <- valid.() do
      if c.repo.in_transaction?(), do: {:error, :in_transaction}, else: {:ok, value}
    else
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  catch
    _, _ -> {:error, :invalid}
  end

  defp caller?(%{tenant: tenant, actor: actor} = caller) when map_size(caller) == 2,
    do: segment?(tenant) and actor?(actor)

  defp caller?(_), do: false

  @doc false
  def segment?(s),
    do:
      is_binary(s) and byte_size(s) in 1..64 and s =~ ~r/\A[A-Za-z0-9._-]+\z/ and
        s not in [".", ".."]

  defp actor?(a),
    do:
      is_binary(a) and byte_size(a) in 1..128 and String.valid?(a) and
        not String.match?(a, ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}]/u)

  defp ref(%{source_ref: s, version: v} = ref) when map_size(ref) == 2 do
    if source?(s, v), do: {:ok, {s, v}}, else: :error
  end

  defp ref(_), do: :error

  defp source?(s, v),
    do: Elzoo.AiModel.text?(s, 1024) and is_integer(v) and v in 1..@max_version

  defp request(
         c,
         %{
           source_ref: s,
           version: v,
           artifact: %{artifact_id: artifact_id, version: artifact_version} = artifact,
           media_type: media_type,
           chunking: chunking
         } = r
       )
       when map_size(r) == 5 and map_size(artifact) == 2 do
    with true <- source?(s, v),
         true <- segment?(artifact_id),
         true <- is_integer(artifact_version) and artifact_version >= 1,
         true <- media_type in @media_types,
         {:ok, size, overlap, max} <- chunking(c, chunking) do
      {:ok,
       %{
         source_ref: s,
         version: v,
         artifact_id: artifact_id,
         artifact_version: artifact_version,
         media_type: media_type,
         chunk_size: size,
         chunk_overlap: overlap,
         max_chunks: max
       }}
    end
  end

  defp request(_, _), do: :error

  # Text-chunking's options, narrowed to 2,000..8,192 and 0..200, and a quarter of the
  # embedding config's max_input_bytes.
  defp chunking(c, chunking) do
    with true <- Keyword.keyword?(chunking),
         keys = Keyword.keys(chunking),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 in @chunking_keys)),
         size = Keyword.get(chunking, :chunk_size, 2_000),
         overlap = Keyword.get(chunking, :chunk_overlap, 200),
         max = Keyword.get(chunking, :max_chunks, 4_096),
         true <- is_integer(size) and size in 2_000..8_192,
         true <- is_integer(overlap) and overlap in 0..200 and overlap <= div(size, 2),
         true <- is_integer(max) and max in 1..65_536,
         true <- size * 4 <= c.limits.max_input_bytes do
      {:ok, size, overlap, max}
    end
  end

  ## Identity

  @doc false
  def index_identity(c), do: c.search.declaration.index_identity

  # The ingest ID: lowercase hex SHA-256 of the length-framed prefix, index identity, tenant,
  # source reference and version.
  @doc false
  def ingest_id(c, tenant, source_ref, version),
    do:
      digest([
        "elzoo/knowledge-ingest/ingest/1",
        c.prefix,
        index_identity(c),
        tenant,
        source_ref,
        Integer.to_string(version)
      ])
      |> Base.encode16(case: :lower)

  # The request digest: SHA-256 of the length-framed request fields, the text-chunking
  # defaults filled in, and the search binding's index identity; not the actor.
  defp request_digest(c, tenant, r),
    do:
      digest(
        [
          "elzoo/knowledge-ingest/request/1",
          index_identity(c),
          tenant,
          r.source_ref,
          r.artifact_id,
          r.media_type
        ] ++
          Enum.map(
            [r.version, r.artifact_version, r.chunk_size, r.chunk_overlap, r.max_chunks],
            &Integer.to_string/1
          )
      )

  defp digest(fields),
    do: :crypto.hash(:sha256, Enum.map(fields, &<<byte_size(&1)::32, &1::binary>>))

  @doc false
  def attempt_ref(id, batch, number), do: "#{id}/#{batch}/#{number}"

  ## The embedding request

  @doc false
  # The request JSON of `inputs` under the config's request members (string keys).
  def request_json(request, inputs) do
    %{"version" => 1, "model" => request.model, "inputs" => inputs}
    |> put_member("dimensions", request[:dimensions])
    |> put_member("input_type", request[:input_type] && Atom.to_string(request.input_type))
    |> put_member("provider_options", request[:provider_options])
  end

  defp put_member(map, _, nil), do: map
  defp put_member(map, key, value), do: Map.put(map, key, value)

  @doc false
  def declaration(request, ref, inputs, deadline) do
    %{
      "capability_id" => "integration/ai-embedding",
      "operation" => "embed",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => ref,
        "schema_id" => "elzoo/ai-embedding-request",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "assembly/knowledge-ingest", "port_id" => "embed"},
        "idempotency_key" => ref,
        "deadline_unix_ms" => deadline,
        "payload" => Request.canonical(request_json(request, inputs))
      }
    }
  end

  ## Step bounds and seams

  @doc false
  # The fixed version 1 deadline of each step.
  def __deadlines__(c),
    do: %{prepare: 120_000, embed: c.limits.receive_timeout_ms + 30_000, index: 120_000}

  @doc false
  def deadline(c, step), do: Map.get(c.seam[:deadlines] || %{}, step, __deadlines__(c)[step])

  @doc false
  def wait_ms(c), do: c.seam[:wait_ms] || c.limits.receive_timeout_ms + 10_000

  @doc false
  def hook(%{seam: %{hook: hook}}, point, info), do: hook.(point, info)
  def hook(_, _, _), do: :ok

  ## Storage

  @doc false
  # One tenant-scoped transaction; a write's first query refuses anything but READ COMMITTED.
  def scoped(c, tenant, write?, fun) do
    result =
      TenantIsolation.transact(c.repo, %{tenant: tenant}, fn ->
        if write? and not read_committed?(c), do: {:error, :isolation}, else: fun.()
      end)

    case result do
      {:ok, _} = ok -> ok
      {:error, reason} when reason in @passed -> {:error, reason}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp read_committed?(c),
    do: q(c, "SELECT current_setting('transaction_isolation')", []).rows == [["read committed"]]

  @doc false
  def q(c, sql, params), do: SQL.query!(c.repo, sql, params, log: false)

  @doc false
  def table(c, name) do
    p = Migration.prefix!(c.prefix)

    p <>
      "." <>
      Map.fetch!(
        %{
          ingests: "elzoo_knowledge_ingests",
          batches: "elzoo_knowledge_batches",
          attempts: "elzoo_knowledge_attempts",
          chunks: "elzoo_knowledge_chunks"
        },
        name
      )
  end

  @doc false
  def lock(c, tenant, id), do: fetch(c, tenant, id, true)

  @doc false
  def fetch(c, tenant, id, lock?) do
    sql =
      "SELECT #{@columns} FROM #{table(c, :ingests)} WHERE tenant = $1 AND ingest_id = $2" <>
        if(lock?, do: " FOR UPDATE", else: "")

    case q(c, sql, [tenant, id]) do
      %{rows: [values]} ->
        Map.new(Enum.zip(@fields, values))

      %{rows: []} ->
        nil
    end
  end

  defp status_of(c, tenant, id) do
    case fetch(c, tenant, id, false) do
      nil ->
        nil

      row ->
        [[count]] =
          q(
            c,
            "SELECT count(*) FROM #{table(c, :attempts)} WHERE tenant = $1 AND ingest_id = $2",
            [tenant, id]
          ).rows

        %{
          source_ref: row.source_ref,
          version: row.version,
          state: Map.fetch!(@states, row.state),
          reason: decode(row.reason),
          batches: %{done: row.batches_done, total: row.batch_count},
          attempts: count,
          text_sha256: row.text_sha256,
          parser: decode(row.parser)
        }
    end
  end

  @doc false
  def delete_chunks(c, tenant, id),
    do: q(c, "DELETE FROM #{table(c, :chunks)} WHERE tenant = $1 AND ingest_id = $2", [tenant, id])

  @doc false
  # Enqueues the job of `step` with a new key in the caller's transaction and records it as
  # the ingest's current job; `{:error, :unavailable}` rolls the transition back.
  def schedule(c, row, step, batch) do
    n = row.jobs + 1

    key =
      Enum.join(
        [row.tenant, row.ingest_id, step] ++ if(step == :embed, do: [batch], else: []) ++ [n],
        "/"
      )

    q(
      c,
      "UPDATE #{table(c, :ingests)} SET jobs = $3, job_key = $4 WHERE tenant = $1 AND ingest_id = $2",
      [row.tenant, row.ingest_id, n, key]
    )

    result =
      case hook(c, :enqueue, %{step: step}) do
        {:override, result} -> result
        _ -> Jobs.enqueue(c.oban, Jobs.changeset(c.queue, key, Steps.job_attempts()))
      end

    case result do
      {:ok, _} -> :ok
      _ -> {:error, :unavailable}
    end
  end

  @doc false
  def encode(nil), do: nil
  def encode(term), do: :erlang.term_to_binary(term, [:deterministic])

  # `:safe` refuses an atom that the VM does not hold yet, so before decoding, the modules
  # whose code names the stored atoms are loaded: on a fresh node in interactive mode, a read
  # can come before any step has run.
  @atom_modules [
    Steps,
    Artifact,
    DocumentParse,
    TextChunking,
    SearchData,
    AiEmbedding,
    AiEmbedding.Outcome,
    AiEmbedding.Descriptor,
    AiModel.Usage,
    AiModel.Provenance,
    AiModel.ModelRef
  ]

  @doc false
  def decode(nil), do: nil

  def decode(bytes) do
    Enum.each(@atom_modules, &Code.ensure_loaded!/1)
    :erlang.binary_to_term(bytes, [:safe])
  end
end
