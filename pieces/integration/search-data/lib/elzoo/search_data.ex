# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.SearchData do
  @moduledoc "Permission-scoped exact cosine retrieval through a consumer-owned Repo."
  alias Elzoo.AiEmbedding.Descriptor
  alias Elzoo.AiModel.Provenance
  alias Ecto.Adapters.SQL

  @max_bytes 8_388_608
  @max_chunk 1_048_576
  @binding_keys [:repo, :prefix, :declaration, :statement_timeout_ms]

  def new(repo, declaration, opts \\ []) do
    with true <- is_atom(repo) and repo not in [nil, true, false],
         true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:prefix, :statement_timeout_ms])),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         :ok <- declaration(declaration),
         prefix = Keyword.get(opts, :prefix, "public"),
         true <- text?(prefix, 63),
         timeout = Keyword.get(opts, :statement_timeout_ms, 5000),
         true <- integer?(timeout, 1, 60_000) do
      {:ok, %{repo: repo, prefix: prefix, declaration: declaration, statement_timeout_ms: timeout}}
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def limits do
    %{
      max_chunks: 65_536,
      max_chunk_bytes: @max_chunk,
      max_content_bytes: @max_bytes,
      max_k: 256,
      max_allowed_sources: 256,
      max_dimensions: 16_000,
      statement_timeout_ms: %{default: 5000, min: 1, max: 60_000}
    }
  end

  def declaration(d) do
    with true <- exact?(d, [:index_identity, :descriptor, :metric]),
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

  def put_source(binding, tenant, source, chunks) do
    with :ok <- validate_binding(binding),
         true <- text?(tenant, 1024),
         {:ok, source} <- source(source),
         {:ok, chunks} <- chunks(chunks, binding.declaration.descriptor) do
      transaction(binding, :write, fn ->
        require_index!(binding)
        lock!(binding, {:source, tenant, source.source_ref})
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

  def query(binding, request) do
    with :ok <- validate_binding(binding),
         {:ok, request} <- request(request, binding) do
      transaction(%{binding | statement_timeout_ms: request.statement_timeout_ms}, :read, fn ->
        require_index!(binding)

        if request.allowed_sources == [] do
          {:ok, []}
        else
          # Both access predicates apply before distance ordering and LIMIT.
          result =
            sql!(
              binding,
              """
              SELECT source_ref,version,chunk_index,content,content_digest,source_digest,start_byte,end_byte,
                     embedding <=> $1::vector AS distance
              FROM #{table(binding)}
              WHERE tenant=$2 AND source_ref=ANY($3::text[])
              ORDER BY distance,source_ref COLLATE "C",version,chunk_index LIMIT $4
              """,
              [
                Pgvector.new(request.query_embedding.vector),
                request.tenant,
                request.allowed_sources,
                request.k
              ]
            )

          if Enum.reduce(result.rows, 0, fn row, n -> n + byte_size(Enum.at(row, 3)) end) >
               request.max_content_bytes do
            binding.repo.rollback({:refused, :invalid_request})
          end

          {:ok, Enum.map(result.rows, &candidate(&1, request))}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp candidate([source, version, index, content, digest, source_digest, first, last, distance], r) do
    %{
      item_id:
        :crypto.hash(:sha256, encode([source, version, index])) |> Base.encode16(case: :lower),
      version: version,
      source: source,
      content: content,
      content_hash: digest,
      derived_from: [],
      access: %{principal: r.principal, checked_at: r.checked_at, result: :allowed},
      distance: distance,
      source_digest: source_digest,
      start_byte: first,
      end_byte: last
    }
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

  defp request(r, b) when is_map(r) do
    keys = [:tenant, :query_embedding, :k, :allowed_sources, :principal, :checked_at]
    optional = [:max_content_bytes, :statement_timeout_ms]

    with true <-
           Enum.all?(keys, &Map.has_key?(r, &1)) and
             Enum.all?(Map.keys(r), &(&1 in (keys ++ optional))),
         true <- text?(r.tenant, 1024) and text?(r.principal, 1024),
         true <- integer?(r.checked_at, 0, 9_007_199_254_740_991) and integer?(r.k, 1, 256),
         true <- is_list(r.allowed_sources) and length(r.allowed_sources) <= 256,
         true <- Enum.all?(r.allowed_sources, &text?(&1, 1024)),
         {:ok, _} <- embedding(r.query_embedding, b.declaration.descriptor),
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

  defp request(_, _), do: {:error, :invalid_request}

  defp validate_binding(b) do
    with true <- exact?(b, @binding_keys),
         {:ok, ^b} <-
           new(b.repo, b.declaration,
             prefix: b.prefix,
             statement_timeout_ms: b.statement_timeout_ms
           ) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  @doc false
  def transaction(b, mode, fun) do
    if b.repo.in_transaction?() do
      reply(mode, :invalid_request)
    else
      result =
        b.repo.transaction(
          fn ->
            unless available?(b), do: b.repo.rollback({:refused, :extension_missing})

            sql!(b, "SELECT pg_catalog.set_config('statement_timeout',$1,true)", [
              Integer.to_string(b.statement_timeout_ms)
            ])

            fun.()
          end,
          timeout: b.statement_timeout_ms + 2000,
          log: false
        )

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
    sql!(
      b,
      """
      INSERT INTO #{table(b)}
      (tenant,source_ref,version,chunk_index,content,content_digest,source_digest,start_byte,end_byte,embedding,embedding_descriptor,embedding_provenance,batch_index)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::vector,$11,$12,$13)
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
      ]
    )
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
  def table_name(id),
    do:
      "elzoo_vectors_" <>
        (:crypto.hash(:sha256, id) |> Base.encode16(case: :lower) |> binary_part(0, 40))

  @doc false
  def declaration_bytes(d),
    do:
      encode([
        d.index_identity,
        d.descriptor.provider,
        d.descriptor.model,
        d.descriptor.dimensions,
        d.descriptor.dtype,
        d.descriptor.normalization,
        d.metric
      ])

  @doc false
  def lock!(b, key) do
    <<n::signed-64, _::binary>> =
      :crypto.hash(:sha256, encode([b.prefix, b.declaration.index_identity, key]))

    sql!(b, "SELECT pg_catalog.pg_advisory_xact_lock($1)", [n])
  end

  defp encode(items), do: :erlang.term_to_binary(items, [:deterministic])
  defp exact?(m, keys), do: Elzoo.AiModel.exact_keys?(m, keys)
  defp text?(value, max), do: Elzoo.AiModel.text?(value, max)
  defp integer?(n, min, max), do: is_integer(n) and n >= min and n <= max
  defp digest?(d), do: is_binary(d) and byte_size(d) == 32
end
