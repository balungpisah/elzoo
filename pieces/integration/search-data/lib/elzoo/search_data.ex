# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.SearchData do
  @moduledoc "Permission-scoped exact cosine and lexical retrieval through a consumer-owned Repo."
  alias Elzoo.AiEmbedding.Descriptor
  alias Elzoo.AiModel.Provenance
  alias Elzoo.TenantIsolation
  alias Ecto.Adapters.SQL

  @max_bytes 8_388_608
  @max_chunk 1_048_576
  @max_text 4096
  @binding_keys [:repo, :prefix, :declaration, :statement_timeout_ms]

  def new(repo, declaration, opts \\ []) do
    with true <- is_atom(repo) and repo not in [nil, true, false],
         true <- Keyword.keyword?(opts),
         true <-
           Enum.all?(
             Keyword.keys(opts),
             &(&1 in [:prefix, :statement_timeout_ms, :tenant_isolation])
           ),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         :ok <- declaration(declaration),
         prefix = Keyword.get(opts, :prefix, "public"),
         true <- text?(prefix, 63),
         timeout = Keyword.get(opts, :statement_timeout_ms, 5000),
         true <- integer?(timeout, 1, 60_000),
         {:ok, floor} <- floor_option(opts, prefix) do
      binding = %{
        repo: repo,
        prefix: prefix,
        declaration: declaration,
        statement_timeout_ms: timeout
      }

      {:ok, if(floor, do: Map.put(binding, :tenant_isolation, floor), else: binding)}
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  # The floor's readers and protected tables are named by the tenant-isolation identifier rule.
  defp floor_option(opts, prefix) do
    case Keyword.fetch(opts, :tenant_isolation) do
      :error ->
        {:ok, nil}

      {:ok, %{prefix: p} = floor} when map_size(floor) == 1 ->
        if identifier?(p) and identifier?(prefix), do: {:ok, floor}, else: :error

      _ ->
        :error
    end
  end

  def limits do
    %{
      max_chunks: 65_536,
      max_chunk_bytes: @max_chunk,
      max_content_bytes: @max_bytes,
      max_k: 256,
      max_allowed_sources: 256,
      max_dimensions: 16_000,
      max_text_bytes: @max_text,
      statement_timeout_ms: %{default: 5000, min: 1, max: 60_000}
    }
  end

  def declaration(d) do
    with true <-
           exact?(d, [:index_identity, :descriptor, :metric]) or
             exact?(d, [:index_identity, :descriptor, :metric, :text_search]),
         true <- text_search?(Map.fetch(d, :text_search)),
         true <- text?(d.index_identity, 256),
         {:ok, _} <- Descriptor.validate(d.descriptor),
         true <- d.descriptor.dimensions <= 16_000,
         true <- d.descriptor.normalization == :unit_l2_verified,
         true <- d.metric == :cosine do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp text_search?(:error), do: true

  defp text_search?({:ok, %{config: config} = t}) when map_size(t) == 1,
    do: identifier?(config)

  defp text_search?(_), do: false

  def put_source(binding, tenant, source, chunks, opts \\ []) do
    with :ok <- validate_binding(binding),
         true <- tenant?(binding, tenant),
         {:ok, source} <- source(source),
         {:ok, chunks} <- chunks(chunks, binding.declaration.descriptor),
         :ok <- text_chunks(binding, chunks),
         {:ok, guarded} <- put_options(opts) do
      transaction(binding, :write, tenant, fn ->
        require_index!(binding)
        if guarded, do: read_committed!(binding)
        lock!(binding, {:source, tenant, source.source_ref})

        # Read under the lock, so a version or delete mark committed while waiting is seen.
        if guarded do
          stored = stored_version(binding, tenant, source.source_ref)
          mark = delete_mark(binding, tenant, source.source_ref)

          if (stored != nil and stored > source.version) or (mark != nil and mark >= source.version),
            do: binding.repo.rollback({:refused, :stale_version})
        end

        table = table(binding)

        sql!(binding, "DELETE FROM #{table} WHERE tenant=$1 AND source_ref=$2", [
          tenant,
          source.source_ref
        ])

        Enum.each(chunks, fn chunk -> insert!(binding, tenant, source, chunk) end)
        {:committed, length(chunks)}
      end)
    else
      {:error, reason} -> {:refused, reason}
      _ -> {:refused, :invalid_request}
    end
  rescue
    _ -> {:refused, :invalid_request}
  end

  defp put_options([]), do: {:ok, false}
  defp put_options([{:if_newer, guarded}]) when is_boolean(guarded), do: {:ok, guarded}
  defp put_options(_), do: {:error, :invalid_request}

  def delete_source(binding, tenant, source_ref, version) do
    with :ok <- validate_binding(binding),
         true <- tenant?(binding, tenant),
         true <- text?(source_ref, 1024),
         true <- integer?(version, 1, 2_147_483_647) do
      transaction(binding, :write, tenant, fn ->
        require_index!(binding)
        read_committed!(binding)
        lock!(binding, {:source, tenant, source_ref})
        stored = stored_version(binding, tenant, source_ref)
        if stored != nil and stored > version, do: binding.repo.rollback({:refused, :stale_version})

        %{num_rows: count} =
          sql!(binding, "DELETE FROM #{table(binding)} WHERE tenant=$1 AND source_ref=$2", [
            tenant,
            source_ref
          ])

        marks!(
          binding,
          """
          INSERT INTO #{marks(binding)} AS m (tenant,source_ref,version) VALUES ($1,$2,$3)
          ON CONFLICT (tenant,source_ref) DO UPDATE SET version=GREATEST(m.version,EXCLUDED.version)
          """,
          [tenant, source_ref, version]
        )

        {:committed, count}
      end)
    else
      _ -> {:refused, :invalid_request}
    end
  rescue
    _ -> {:refused, :invalid_request}
  end

  # Under REPEATABLE READ the snapshot predates the lock wait, so the guard would read stale rows.
  defp read_committed!(b) do
    %{rows: [[level]]} =
      sql!(b, "SELECT pg_catalog.current_setting('transaction_isolation')", [])

    if level != "read committed", do: b.repo.rollback({:refused, :isolation})
  end

  defp stored_version(b, tenant, ref) do
    %{rows: [[version]]} =
      sql!(b, "SELECT max(version) FROM #{table(b)} WHERE tenant=$1 AND source_ref=$2", [
        tenant,
        ref
      ])

    version
  end

  defp delete_mark(b, tenant, ref) do
    case marks!(b, "SELECT version FROM #{marks(b)} WHERE tenant=$1 AND source_ref=$2", [
           tenant,
           ref
         ]).rows do
      [[version]] -> version
      [] -> nil
    end
  end

  # An index installed before delete marks existed has no mark table until install/1 runs again.
  defp marks!(b, sql, params) do
    sql!(b, sql, params)
  rescue
    e in Postgrex.Error ->
      if match?(%{code: :undefined_table}, e.postgres),
        do: b.repo.rollback({:refused, :invalid_request}),
        else: reraise(e, __STACKTRACE__)
  end

  def query(binding, request) do
    with :ok <- validate_binding(binding),
         {:ok, request} <- request(request, binding, :query_embedding),
         true <- tenant?(binding, request.tenant) do
      retrieve(
        binding,
        request,
        """
        SELECT source_ref,version,chunk_index,octet_length(content)::bigint AS bytes,
               embedding <=> $1::vector AS score
        FROM #{table(binding)}
        WHERE tenant=$2 AND source_ref=ANY($3::text[])
        ORDER BY score,source_ref COLLATE "C",version,chunk_index LIMIT $4
        """,
        {"double precision", "score"},
        [Pgvector.new(request.query_embedding.vector)],
        :distance
      )
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def query_text(binding, request) do
    with :ok <- validate_binding(binding),
         {:ok, config} <- text_config(binding.declaration),
         {:ok, request} <- request(request, binding, :text),
         true <- tenant?(binding, request.tenant) do
      # websearch_to_tsquery accepts any text; a stop-word-only query is empty and matches nothing.
      retrieve(
        binding,
        request,
        """
        SELECT c.source_ref,c.version,c.chunk_index,octet_length(c.content)::bigint AS bytes,
               pg_catalog.ts_rank_cd(c.text_vector,q.query) AS score
        FROM #{table(binding)} c,
             (SELECT pg_catalog.websearch_to_tsquery($6::text::pg_catalog.regconfig,$1) AS query) q
        WHERE c.tenant=$2 AND c.source_ref=ANY($3::text[])
          AND c.text_vector OPERATOR(pg_catalog.@@) q.query
        ORDER BY score DESC,c.source_ref COLLATE "C",c.version,c.chunk_index LIMIT $4
        """,
        {"real", "score DESC"},
        [request.text],
        :rank,
        [config]
      )
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp text_config(%{text_search: %{config: config}}), do: {:ok, "pg_catalog." <> config}
  defp text_config(_), do: {:error, :text_search_disabled}

  # $1 is the query input, $2..$5 the tenant, permitted sources, k and content bound; both access
  # predicates apply in `ranked` before ordering and LIMIT.
  defp retrieve(binding, request, ranked, {score_type, order}, input, key, extra \\ []) do
    transaction(
      %{binding | statement_timeout_ms: request.statement_timeout_ms},
      :read,
      request.tenant,
      fn ->
        require_index!(binding)

        if request.allowed_sources == [] do
          {:ok, []}
        else
          result =
            ranked!(
              binding,
              key,
              """
              WITH ranked AS MATERIALIZED (
                #{ranked}
              ), sized AS MATERIALIZED (
                SELECT COALESCE(sum(bytes),0)::bigint AS total_bytes FROM ranked
              ), admitted AS MATERIALIZED (
                SELECT ranked.* FROM ranked CROSS JOIN sized
                WHERE sized.total_bytes <= $5::bigint
              )
              SELECT * FROM (
                SELECT c.source_ref,c.version,c.chunk_index,c.content,c.content_digest,
                       c.source_digest,c.start_byte,c.end_byte,r.score,false AS overflow
                FROM admitted r JOIN #{table(binding)} c
                  ON c.tenant=$2 AND c.source_ref=r.source_ref AND c.version=r.version
                     AND c.chunk_index=r.chunk_index
                UNION ALL
                SELECT NULL::text,NULL::bigint,NULL::integer,NULL::bytea,NULL::bytea,
                       NULL::bytea,NULL::bigint,NULL::bigint,NULL::#{score_type},true
                FROM sized WHERE total_bytes > $5::bigint
              ) result
              ORDER BY #{order},source_ref COLLATE "C",version,chunk_index
              """,
              input ++
                [
                  request.tenant,
                  request.allowed_sources,
                  request.k,
                  request.max_content_bytes
                ] ++ extra
            )

          case result.rows do
            [[nil, nil, nil, nil, nil, nil, nil, nil, nil, true]] ->
              binding.repo.rollback({:refused, :invalid_request})

            rows ->
              {:ok, Enum.map(rows, &candidate(&1, request, key))}
          end
        end
      end
    )
  end

  # websearch_to_tsquery cannot parse some in-bounds texts, such as a long run of '-': a refusal
  # of the input, not unavailability. PostgreSQL 16.16 reports 54000 "tsquery is too complex";
  # 16.15 and earlier report the internal error XX000 "tsquery stack too small" for the same text.
  defp ranked!(b, :rank, sql, params) do
    sql!(b, sql, params)
  rescue
    e in Postgrex.Error ->
      case e.postgres do
        %{code: :program_limit_exceeded} ->
          b.repo.rollback({:refused, :invalid_request})

        %{code: :internal_error, message: "tsquery stack too small"} ->
          b.repo.rollback({:refused, :invalid_request})

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  defp ranked!(b, :distance, sql, params), do: sql!(b, sql, params)

  @doc """
  The startup check of a floor binding: `Elzoo.TenantIsolation.verify/3` over the vector table,
  then the delete-mark table; `:ok` or the first `{:error, reason}`.
  """
  def verify(binding) do
    with :ok <- validate_binding(binding),
         %{tenant_isolation: %{prefix: p}} <- binding do
      id = binding.declaration.index_identity

      Enum.reduce_while([table_name(id), mark_name(id)], :ok, fn name, :ok ->
        case TenantIsolation.verify(binding.repo, {binding.prefix, name},
               prefix: p,
               tenant_column: "tenant",
               space_column: nil
             ) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp candidate(
         [source, version, index, content, digest, source_digest, first, last, score, false],
         r,
         key
       ) do
    %{
      item_id:
        :crypto.hash(:sha256, encode([source, version, index])) |> Base.encode16(case: :lower),
      version: version,
      source: source,
      content: content,
      content_hash: digest,
      derived_from: [],
      access: %{principal: r.principal, checked_at: r.checked_at, result: :allowed},
      source_digest: source_digest,
      start_byte: first,
      end_byte: last
    }
    |> Map.put(key, score)
  end

  defp source({ref, version, digest}) do
    if text?(ref, 1024) and integer?(version, 1, 2_147_483_647) and digest?(digest),
      do: {:ok, %{source_ref: ref, version: version, source_digest: digest}},
      else: {:error, :invalid_request}
  end

  defp source(_), do: {:error, :invalid_request}

  defp chunks(chunks, descriptor) when is_list(chunks) do
    cond do
      length(chunks) > 65_536 ->
        {:error, :source_too_large}

      chunks == [] ->
        {:error, :invalid_chunk}

      true ->
        Enum.reduce_while(Enum.with_index(chunks), {:ok, [], 0, nil}, fn {chunk, index},
                                                                         {:ok, acc, total,
                                                                          previous_start} ->
          with :ok <- chunk(chunk, index),
               true <- previous_start == nil or chunk.start_byte >= previous_start,
               {:ok, _} <- embedding(chunk.embedding, descriptor) do
            bytes = total + byte_size(chunk.content)

            if bytes > @max_bytes,
              do: {:halt, {:error, :source_too_large}},
              else: {:cont, {:ok, [chunk | acc], bytes, chunk.start_byte}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
            false -> {:halt, {:error, :invalid_chunk}}
          end
        end)
        |> case do
          {:ok, values, _, _} -> {:ok, Enum.reverse(values)}
          error -> error
        end
    end
  end

  defp chunks(_, _), do: {:error, :invalid_chunk}

  defp chunk(c, index) do
    cond do
      not exact?(c, [:index, :start_byte, :end_byte, :content, :content_digest, :embedding]) ->
        {:error, :invalid_chunk}

      not is_binary(c.content) ->
        {:error, :invalid_chunk}

      byte_size(c.content) > @max_chunk ->
        {:error, :source_too_large}

      c.index != index or not integer?(c.start_byte, 0, 9_007_199_254_740_991) or
          (index == 0 and c.start_byte != 0) ->
        {:error, :invalid_chunk}

      not integer?(c.end_byte, 1, 9_007_199_254_740_991) ->
        {:error, :invalid_chunk}

      c.end_byte - c.start_byte != byte_size(c.content) or c.content == "" ->
        {:error, :invalid_chunk}

      not String.valid?(c.content) or not digest?(c.content_digest) ->
        {:error, :invalid_chunk}

      :crypto.hash(:sha256, c.content) != c.content_digest ->
        {:error, :invalid_chunk}

      true ->
        :ok
    end
  end

  # PostgreSQL text holds no NUL byte, so convert_from would fail on such content.
  defp text_chunks(%{declaration: %{text_search: _}}, chunks) do
    if Enum.any?(chunks, &String.contains?(&1.content, <<0>>)),
      do: {:error, :invalid_chunk},
      else: :ok
  end

  defp text_chunks(_, _), do: :ok

  defp embedding(e, descriptor) do
    with true <- exact?(e, [:index, :vector, :descriptor, :provenance]),
         true <- integer?(e.index, 0, 2047),
         true <- Descriptor.compatible?(e.descriptor, descriptor),
         true <- is_list(e.vector) and length(e.vector) == descriptor.dimensions,
         true <- Enum.all?(e.vector, &(is_number(&1) and abs(&1) <= Descriptor.float32_max())),
         true <- Descriptor.normalization([e.vector]) == :unit_l2_verified,
         {:ok, _} <- Provenance.validate(e.provenance),
         true <- e.provenance.model_ref.provider == descriptor.provider,
         true <- e.provenance.model_ref.model_id == descriptor.model,
         true <- e.provenance.provider_model == descriptor.model do
      {:ok, e}
    else
      _ -> {:error, :incompatible_embedding}
    end
  rescue
    _ -> {:error, :incompatible_embedding}
  end

  defp request(r, b, input) when is_map(r) do
    keys = [:tenant, input, :k, :allowed_sources, :principal, :checked_at]
    optional = [:max_content_bytes, :statement_timeout_ms]

    with true <-
           Enum.all?(keys, &Map.has_key?(r, &1)) and
             Enum.all?(Map.keys(r), &(&1 in (keys ++ optional))),
         true <- text?(r.tenant, 1024) and text?(r.principal, 1024),
         true <- integer?(r.checked_at, 0, 9_007_199_254_740_991) and integer?(r.k, 1, 256),
         true <- is_list(r.allowed_sources) and length(r.allowed_sources) <= 256,
         true <- Enum.all?(r.allowed_sources, &text?(&1, 1024)),
         {:ok, _} <- input(input, r, b),
         max = Map.get(r, :max_content_bytes, @max_bytes),
         true <- integer?(max, 1, @max_bytes),
         timeout = Map.get(r, :statement_timeout_ms, b.statement_timeout_ms),
         true <- integer?(timeout, 1, b.statement_timeout_ms) do
      {:ok, Map.merge(r, %{max_content_bytes: max, statement_timeout_ms: timeout})}
    else
      {:error, :incompatible_embedding} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp request(_, _, _), do: {:error, :invalid_request}

  defp input(:query_embedding, r, b), do: embedding(r.query_embedding, b.declaration.descriptor)

  defp input(:text, %{text: t}, _) do
    if is_binary(t) and byte_size(t) in 1..@max_text and String.valid?(t) and
         not String.contains?(t, <<0>>),
       do: {:ok, t},
       else: {:error, :invalid_request}
  end

  # Under the floor the tenant must also pass tenant-isolation's scope rule (no C1 control).
  defp tenant?(%{tenant_isolation: _}, t),
    do: text?(t, 128) and not String.match?(t, ~r/[\x{80}-\x{9F}]/u)

  defp tenant?(_, t), do: text?(t, 1024)

  @doc false
  def validate_binding(b) do
    with true <- exact?(b, @binding_keys) or exact?(b, [:tenant_isolation | @binding_keys]),
         floor = Map.take(b, [:tenant_isolation]) |> Map.to_list(),
         {:ok, ^b} <-
           new(
             b.repo,
             b.declaration,
             [prefix: b.prefix, statement_timeout_ms: b.statement_timeout_ms] ++ floor
           ) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  @doc false
  # tenant is nil for install; with the floor every other transaction runs under its tenant.
  def transaction(b, mode, tenant, fun) do
    if b.repo.in_transaction?() do
      reply(mode, :invalid_request)
    else
      body = fn ->
        unless available?(b), do: b.repo.rollback({:refused, :extension_missing})

        sql!(b, "SELECT pg_catalog.set_config('statement_timeout',$1,true)", [
          Integer.to_string(b.statement_timeout_ms)
        ])

        fun.()
      end

      result =
        case b do
          # transact/3 takes no options, so the checkout carries the transaction's deadline.
          %{tenant_isolation: _} when tenant != nil ->
            b.repo.checkout(
              fn ->
                TenantIsolation.transact(b.repo, %{tenant: tenant}, fn -> {:ok, body.()} end)
              end,
              timeout: b.statement_timeout_ms + 2000,
              log: false
            )

          _ ->
            b.repo.transaction(body, timeout: b.statement_timeout_ms + 2000, log: false)
        end

      case result do
        {:ok, value} -> value
        {:error, {:refused, reason}} -> reply(mode, reason)
        {:error, _} -> unknown(mode)
      end
    end
  rescue
    _ -> unknown(mode)
  catch
    :exit, _ -> unknown(mode)
  end

  defp reply(:write, reason), do: {:refused, reason}
  defp reply(:read, reason), do: {:error, reason}
  defp reply(:install, reason), do: {:error, reason}
  defp unknown(:write), do: {:indeterminate, :unavailable}
  defp unknown(_), do: {:error, :unavailable}

  @doc false
  def available?(b) do
    %{rows: [[found]]} =
      sql!(
        b,
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_catalog.pg_extension e
          JOIN pg_catalog.pg_depend d ON d.refobjid=e.oid AND d.refclassid='pg_catalog.pg_extension'::regclass
            AND d.classid='pg_catalog.pg_type'::regclass AND d.deptype='e'
          JOIN pg_catalog.pg_type t ON t.oid=d.objid
          JOIN pg_catalog.pg_operator o ON o.oprleft=t.oid AND o.oprright=t.oid AND o.oprname='<=>'
          JOIN pg_catalog.pg_depend od ON od.objid=o.oid AND od.classid='pg_catalog.pg_operator'::regclass
            AND od.refobjid=e.oid AND od.refclassid='pg_catalog.pg_extension'::regclass AND od.deptype='e'
          WHERE e.extname='vector' AND t.oid=pg_catalog.to_regtype('vector')
            AND pg_catalog.pg_operator_is_visible(o.oid))
        """,
        []
      )

    found
  end

  @doc false
  def require_index!(b) do
    result =
      sql!(b, "SELECT descriptor FROM #{registry(b)} WHERE index_identity=$1", [
        b.declaration.index_identity
      ])

    case result.rows do
      [[bytes]] ->
        if bytes != declaration_bytes(b.declaration),
          do: b.repo.rollback({:refused, :incompatible_embedding})

      _ ->
        b.repo.rollback({:refused, :invalid_request})
    end
  end

  defp insert!(b, tenant, source, c) do
    # The configuration travels as text and is cast by PostgreSQL, schema-qualified, so the
    # writer's search_path cannot pick another configuration.
    {column, value, extra} =
      case text_config(b.declaration) do
        {:ok, config} ->
          {",text_vector",
           ",pg_catalog.to_tsvector($14::text::pg_catalog.regconfig,pg_catalog.convert_from($5,'UTF8'))",
           [config]}

        _ ->
          {"", "", []}
      end

    sql!(
      b,
      """
      INSERT INTO #{table(b)}
      (tenant,source_ref,version,chunk_index,content,content_digest,source_digest,start_byte,end_byte,embedding,embedding_descriptor,embedding_provenance,batch_index#{column})
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::vector,$11,$12,$13#{value})
      """,
      [
        tenant,
        source.source_ref,
        source.version,
        c.index,
        c.content,
        c.content_digest,
        source.source_digest,
        c.start_byte,
        c.end_byte,
        Pgvector.new(c.embedding.vector),
        :erlang.term_to_binary(c.embedding.descriptor),
        :erlang.term_to_binary(c.embedding.provenance),
        c.embedding.index
      ] ++ extra
    )
  rescue
    # 54000: the chunk's tsvector passes PostgreSQL's 1 MB limit.
    e in Postgrex.Error ->
      case {e.postgres, Map.has_key?(b.declaration, :text_search)} do
        {%{code: :program_limit_exceeded}, true} ->
          b.repo.rollback({:refused, :text_search_too_large})

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  @doc false
  def sql!(b, query, params),
    do: SQL.query!(b.repo, query, params, log: false, timeout: b.statement_timeout_ms + 1000)

  @doc false
  def identifier(value), do: "\"" <> String.replace(value, "\"", "\"\"") <> "\""
  @doc false
  def registry(b), do: identifier(b.prefix) <> ".elzoo_search_indexes"
  @doc false
  def table(b),
    do: identifier(b.prefix) <> "." <> identifier(table_name(b.declaration.index_identity))

  @doc false
  def marks(b),
    do: identifier(b.prefix) <> "." <> identifier(mark_name(b.declaration.index_identity))

  @doc false
  def table_name(id), do: "elzoo_vectors_" <> hash40(id)
  @doc false
  def mark_name(id), do: "elzoo_deletes_" <> hash40(id)

  defp hash40(id),
    do: :crypto.hash(:sha256, id) |> Base.encode16(case: :lower) |> binary_part(0, 40)

  @doc false
  # The seven fields of every declaration, plus the text search configuration only when present,
  # so the stored bytes of a declaration without it are unchanged.
  def declaration_bytes(d) do
    fields = [
      d.index_identity,
      d.descriptor.provider,
      d.descriptor.model,
      d.descriptor.dimensions,
      d.descriptor.dtype,
      d.descriptor.normalization,
      d.metric
    ]

    case d do
      %{text_search: %{config: config}} -> encode(fields ++ [{:text_search, config}])
      _ -> encode(fields)
    end
  end

  @doc false
  def lock!(b, key) do
    <<n::signed-64, _::binary>> =
      :crypto.hash(:sha256, encode([b.prefix, b.declaration.index_identity, key]))

    sql!(b, "SELECT pg_catalog.pg_advisory_xact_lock($1)", [n])
  end

  defp encode(items), do: :erlang.term_to_binary(items, [:deterministic])
  defp exact?(m, keys), do: Elzoo.AiModel.exact_keys?(m, keys)
  defp text?(value, max), do: Elzoo.AiModel.text?(value, max)
  defp identifier?(value), do: is_binary(value) and value =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/
  defp integer?(n, min, max), do: is_integer(n) and n >= min and n <= max
  defp digest?(d), do: is_binary(d) and byte_size(d) == 32
end
