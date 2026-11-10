# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/search_data_test_helper.exs", __DIR__)

defmodule Elzoo.SearchDataTest do
  use ExUnit.Case, async: false
  alias Elzoo.SearchData, as: Store
  alias Elzoo.SearchData.{Migration, TestRepo, RestrictedRepo}
  alias Ecto.Adapters.SQL

  setup_all do
    url =
      System.get_env("ELZOO_TEST_DATABASE_URL") ||
        raise "ELZOO_TEST_DATABASE_URL is required; tests fail closed"

    start_supervised!(
      {TestRepo, url: url, types: Elzoo.SearchData.TestTypes, pool_size: 6, log: false}
    )

    assert %{rows: [[true]]} =
             SQL.query!(
               TestRepo,
               "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname='vector')",
               [],
               log: false
             )

    assert %{rows: [[server, extension]]} =
             SQL.query!(
               TestRepo,
               "SELECT current_setting('server_version_num'),extversion FROM pg_extension WHERE extname='vector'",
               [],
               log: false
             )

    assert String.to_integer(server) in 160_000..169_999
    assert String.starts_with?(extension, "0.8.")
    IO.puts("SearchData boundary: PostgreSQL16, vector " <> extension)
    restricted = "elz082_restricted_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    SQL.query!(TestRepo, "CREATE SCHEMA #{Store.identifier(restricted)}", [], log: false)

    start_supervised!(
      {RestrictedRepo,
       url: url,
       types: Elzoo.SearchData.TestTypes,
       pool_size: 2,
       parameters: [search_path: "#{restricted}, pg_catalog"],
       log: false}
    )

    on_exit(fn ->
      {:ok, pid} =
        TestRepo.start_link(url: url, types: Elzoo.SearchData.TestTypes, pool_size: 1, log: false)

      SQL.query!(TestRepo, "DROP SCHEMA #{Store.identifier(restricted)} CASCADE", [], log: false)
      GenServer.stop(pid)
    end)

    {:ok, restricted: restricted}
  end

  setup do
    prefix = "elz082_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    SQL.query!(TestRepo, "CREATE SCHEMA #{Store.identifier(prefix)}", [], log: false)

    on_exit(fn ->
      SQL.query!(TestRepo, "DROP SCHEMA #{Store.identifier(prefix)} CASCADE", [], log: false)
    end)

    {:ok, b} = Store.new(TestRepo, declaration(), prefix: prefix)
    assert {:ok, ^b} = Migration.install(b)
    {:ok, binding: b, prefix: prefix}
  end

  defp descriptor,
    do: %{
      provider: "openai",
      model: "test-embedding",
      dimensions: 3,
      dtype: :float32,
      normalization: :unit_l2_verified
    }

  defp declaration, do: %{index_identity: "documents", descriptor: descriptor(), metric: :cosine}

  defp provenance,
    do: %{
      model_ref: %{provider: "openai", model_id: "test-embedding", wire_surface: "embeddings"},
      provider_model: "test-embedding",
      response_id: :absent,
      request_id: "recorded-request",
      provider_piece: "integration/ai-embedding-openai"
    }

  defp embedding(vector \\ [1.0, 0.0, 0.0]),
    do: %{index: 0, vector: vector, descriptor: descriptor(), provenance: provenance()}

  defp chunk(text \\ "one", index \\ 0, vector \\ [1.0, 0.0, 0.0]) do
    %{
      index: index,
      start_byte: index * byte_size(text),
      end_byte: (index + 1) * byte_size(text),
      content: text,
      content_digest: :crypto.hash(:sha256, text),
      embedding: embedding(vector)
    }
  end

  defp source(ref \\ "source", version \\ 1),
    do: {ref, version, :crypto.hash(:sha256, "source binary")}

  defp request(extra \\ %{}),
    do:
      Map.merge(
        %{
          tenant: "tenant",
          query_embedding: embedding(),
          k: 10,
          allowed_sources: ["source"],
          principal: "reader",
          checked_at: 10
        },
        extra
      )

  defp put(b, ref, text, vector \\ [1.0, 0.0, 0.0]),
    do: Store.put_source(b, "tenant", source(ref), [chunk(text, 0, vector)])

  test "S1 real vector roundtrip, durable provenance and batch-local indices", %{binding: b} do
    source_text = String.duplicate("first second ", 6)
    digest = :crypto.hash(:sha256, source_text)

    assert {:ok, result} =
             Elzoo.TextChunking.chunk(source_text, digest, "source",
               chunk_size: 16,
               chunk_overlap: 0
             )

    # Two provider batches both have item index0 while source chunk identity advances.
    chunks = Enum.map(result.chunks, &Map.put(&1, :embedding, embedding()))
    count = length(chunks)
    assert count > 1
    assert {:committed, ^count} = Store.put_source(b, "tenant", {"source", 1, digest}, chunks)
    assert {:ok, retrieved} = Store.query(b, request())
    [a, c | _] = retrieved
    assert Enum.map(retrieved, & &1.content) == Enum.map(result.chunks, & &1.content)
    assert a.source_digest == digest
    assert a.access == %{principal: "reader", checked_at: 10, result: :allowed}
    assert byte_size(a.content_hash) == 32
    assert a.item_id != c.item_id

    %{rows: rows} =
      SQL.query!(
        TestRepo,
        "SELECT batch_index,embedding_descriptor,embedding_provenance,embedding FROM #{Store.table(b)} ORDER BY chunk_index",
        [],
        log: false
      )

    assert Enum.map(rows, &hd/1) == List.duplicate(0, count)
    assert {:ok, %Pgvector{}} = Pgvector.Ecto.Vector.cast([1.0, 0.0, 0.0])

    for [0, d, p, v] <- rows do
      assert :erlang.binary_to_term(d, [:safe]) == descriptor()
      assert :erlang.binary_to_term(p, [:safe]) == provenance()
      assert Pgvector.to_list(v) == [1.0, 0.0, 0.0]
    end
  end

  test "S2 SQL filters tenant and permissions before ranking, including empty permission set", %{
    binding: b
  } do
    assert {:committed, 1} = put(b, "source", "permitted", [0.0, 1.0, 0.0])
    assert {:committed, 1} = put(b, "forbidden", "closer")
    assert {:committed, 1} = Store.put_source(b, "other-tenant", source(), [chunk("other closer")])
    assert {:ok, [r]} = Store.query(b, request(%{k: 1}))
    assert r.content == "permitted"
    assert r.distance == 1.0
    assert {:ok, []} = Store.query(b, request(%{allowed_sources: []}))
  end

  test "S3 retrieval candidates require a current context-selection permission recheck", %{
    binding: b
  } do
    assert {:committed, 1} = put(b, "source", "classified")
    {:ok, [r]} = Store.query(b, request())

    c =
      r
      |> Map.take([:item_id, :version, :source, :content, :content_hash, :derived_from, :access])
      |> Map.merge(%{estimate: byte_size(r.content), priority: 0})

    check =
      Map.take(c, [:item_id, :version, :source, :content_hash])
      |> Map.merge(%{tenant: "tenant", principal: "reader", checked_at: 11, result: :denied})

    node =
      Map.take(c, [:item_id, :version, :source, :content_hash, :derived_from])
      |> Map.merge(%{tenant: "tenant", check: check})

    w = %{
      provider_id: "openai",
      model_id: "test-embedding",
      size: 1000,
      unit: :bytes,
      estimator_id: "bytes",
      estimator_version: 1
    }

    context = %{
      principal: "reader",
      tenant: "tenant",
      now: 11,
      snapshot_at: 11,
      window: w,
      windows: [w],
      reservations: [],
      policy: %{
        max_age: 100,
        allow_derived: false,
        priority: :input,
        recency: :input,
        max_selected_count: 10,
        max_selected_bytes: 1000
      },
      provenance: [node]
    }

    assert {:ok, %{selected: [], dropped: [%{reason: :access_denied}]}} =
             Elzoo.ContextSelection.select(%{candidates: [c]}, context)
  end

  test "S4 immutable declarations and incompatible vectors are refused", %{binding: b} do
    for d <- [
          put_in(b.declaration, [:descriptor, :dimensions], 2),
          put_in(b.declaration, [:descriptor, :model], "other"),
          %{b.declaration | metric: :l2}
        ] do
      case Store.new(TestRepo, d, prefix: b.prefix) do
        {:ok, other} -> assert {:error, :incompatible_embedding} = Migration.install(other)
        {:error, :invalid_request} -> :ok
      end
    end

    variants = [
      put_in(embedding().descriptor.normalization, :none),
      put_in(embedding().descriptor.provider, "other"),
      put_in(embedding().descriptor.dtype, :int8),
      put_in(embedding().vector, [2.0, 0.0, 0.0]),
      put_in(embedding().vector, [1.0, 0.0]),
      put_in(embedding().provenance.provider_model, "other")
    ]

    for e <- variants do
      assert {:refused, :incompatible_embedding} =
               Store.put_source(b, "tenant", source(), [%{chunk() | embedding: e}])

      assert {:error, :incompatible_embedding} = Store.query(b, request(%{query_embedding: e}))
    end

    assert {:ok, []} = Store.query(b, request())
  end

  test "S5 byte/count bounds refuse whole without partial source or result", %{binding: b} do
    assert {:committed, 1} = put(b, "source", "abc")
    assert {:ok, [_]} = Store.query(b, request(%{max_content_bytes: 3, k: 256}))

    assert {:refused, :source_too_large} =
             Store.put_source(b, "tenant", source(), List.duplicate(chunk(), 65_537))

    assert {:error, :invalid_request} = Store.query(b, request(%{max_content_bytes: 2}))

    for extra <- [
          %{k: 0},
          %{k: 257},
          %{max_content_bytes: 8_388_609},
          %{statement_timeout_ms: 0},
          %{allowed_sources: List.duplicate("source", 257)}
        ] do
      assert {:error, :invalid_request} = Store.query(b, request(extra))
    end

    large = chunk(String.duplicate("x", 1_048_576))
    assert {:committed, 1} = Store.put_source(b, "tenant", source("large"), [large])

    assert {:refused, :source_too_large} =
             Store.put_source(b, "tenant", source(), [chunk(String.duplicate("x", 1_048_577))])

    invalid = %{chunk("valid", 1) | content_digest: <<0::256>>}
    assert {:refused, :invalid_chunk} = Store.put_source(b, "tenant", source(), [chunk(), invalid])
    assert {:ok, [%{content: "abc"}]} = Store.query(b, request())

    eight =
      for i <- 0..7,
          do: %{large | index: i, start_byte: i * 1_048_576, end_byte: (i + 1) * 1_048_576}

    assert {:committed, 8} = Store.put_source(b, "tenant", source("eight"), eight)

    assert {:refused, :source_too_large} =
             Store.put_source(
               b,
               "tenant",
               source("eight"),
               eight ++ [%{chunk("x", 8) | start_byte: 8_388_608, end_byte: 8_388_609}]
             )
  end

  test "S6 deterministic order and identity across equal distances and replacement", %{binding: b} do
    assert {:committed, 1} = put(b, "b", "b")
    assert {:committed, 1} = put(b, "a", "a")
    q = request(%{allowed_sources: ["b", "a"]})
    assert {:ok, [a, brow]} = Store.query(b, q)
    assert [a.source, brow.source] == ["a", "b"]
    assert {:committed, 1} = Store.put_source(b, "tenant", source("a", 2), [chunk("new")])
    assert {:ok, [new, _]} = Store.query(b, q)
    assert new.version == 2
    refute new.item_id == a.item_id
  end

  defp hold_lock(_b, sql, params \\ []) do
    parent = self()

    task =
      Task.async(fn ->
        TestRepo.transaction(
          fn ->
            SQL.query!(TestRepo, sql, params, log: false)
            send(parent, {:held, self()})

            receive do
              :release -> :ok
            after
              10_000 -> raise "test lock not released"
            end
          end,
          timeout: 15_000
        )
      end)

    assert_receive {:held, pid}, 2000
    {task, pid}
  end

  test "S7 timeout returns no rows; same-process caller transaction refuses before statements", %{
    binding: b
  } do
    assert {:committed, 1} = put(b, "source", "old")
    {task, pid} = hold_lock(b, "LOCK TABLE #{Store.table(b)} IN ACCESS EXCLUSIVE MODE")
    assert {:error, :unavailable} = Store.query(b, request(%{statement_timeout_ms: 25}))

    assert {:indeterminate, :unavailable} =
             Store.put_source(%{b | statement_timeout_ms: 25}, "tenant", source(), [
               chunk("unobserved")
             ])

    send(pid, :release)
    Task.await(task)
    assert {:ok, [_]} = Store.query(b, request())

    assert {:ok, :checked} =
             TestRepo.transaction(fn ->
               assert {:error, :invalid_request} = Store.query(b, request())
               assert {:refused, :invalid_request} = put(b, "source", "refused")
               :checked
             end)
  end

  test "S8 replacement is atomic while paused after delete; concurrent writers serialize", %{
    binding: b
  } do
    assert {:committed, 1} = put(b, "source", "old")
    key = :rand.uniform(1_000_000_000)
    function = Store.identifier(b.prefix) <> ".pause_insert"

    SQL.query!(
      TestRepo,
      "CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_catalog.pg_advisory_xact_lock(#{key}::bigint); RETURN NEW; END $$",
      [],
      log: false
    )

    SQL.query!(
      TestRepo,
      "CREATE TRIGGER pause_insert BEFORE INSERT ON #{Store.table(b)} FOR EACH ROW EXECUTE FUNCTION #{function}()",
      [],
      log: false
    )

    {holder, pid} = hold_lock(b, "SELECT pg_advisory_xact_lock($1)", [key])

    writer =
      Task.async(fn ->
        Store.put_source(b, "tenant", source("source", 2), [chunk("new", 0), chunk("new", 1)])
      end)

    wait_for_lock(key, System.monotonic_time(:millisecond) + 3000)
    assert {:ok, [%{content: "old", version: 1}]} = Store.query(b, request())
    send(pid, :release)
    Task.await(holder)
    assert {:committed, 2} = Task.await(writer)
    assert {:ok, rows} = Store.query(b, request())
    assert Enum.map(rows, &{&1.content, &1.version}) == [{"new", 2}, {"new", 2}]

    tasks =
      for v <- 3..6,
          do:
            Task.async(fn ->
              Store.put_source(b, "tenant", source("source", v), [
                chunk("v#{v}", 0),
                chunk("v#{v}", 1)
              ])
            end)

    assert Enum.all?(Enum.map(tasks, &Task.await/1), &(&1 == {:committed, 2}))
    assert {:ok, [a, c]} = Store.query(b, request())
    assert a.version == c.version and a.content == c.content
  end

  defp wait_for_lock(key, deadline) do
    %{rows: [[n]]} =
      SQL.query!(
        TestRepo,
        "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=$1 AND NOT granted",
        [key],
        log: false
      )

    cond do
      n > 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("writer did not reach observable insert lock")

      true ->
        receive do
        after
          5 -> wait_for_lock(key, deadline)
        end
    end
  end

  test "S9 real extension installed but unavailable through restricted Repo namespace", %{
    binding: b,
    restricted: restricted
  } do
    assert %{rows: [[true, nil]]} =
             SQL.query!(
               RestrictedRepo,
               "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname='vector'),to_regtype('vector')",
               [],
               log: false
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :undefined_object}}} =
             SQL.query(RestrictedRepo, "SELECT NULL::vector(3)", [], log: false)

    other = %{b | repo: RestrictedRepo}
    assert {:error, :extension_missing} = Migration.install(other)
    assert {:refused, :extension_missing} = put(other, "source", "unavailable")
    assert {:error, :extension_missing} = Store.query(other, request())

    assert %{rows: [[0]]} =
             SQL.query!(
               TestRepo,
               "SELECT count(*) FROM pg_tables WHERE schemaname=$1",
               [restricted],
               log: false
             )

    # A visible same-named unrelated domain is not the extension member type.
    SQL.query!(TestRepo, "CREATE DOMAIN #{Store.identifier(restricted)}.vector AS text", [],
      log: false
    )

    assert %{rows: [[true]]} =
             SQL.query!(RestrictedRepo, "SELECT to_regtype('vector') IS NOT NULL", [], log: false)

    assert {:error, :extension_missing} = Migration.install(other)
    assert {:refused, :extension_missing} = put(other, "source", "fake vector")
    assert {:error, :extension_missing} = Store.query(other, request())
    assert {:committed, 1} = put(b, "source", "normal")
    assert {:ok, [%{content: "normal"}]} = Store.query(b, request())
  end

  test "S10 malformed configuration and input refuse safely", %{binding: b} do
    for opts <- [
          [prefix: ""],
          [statement_timeout_ms: 0],
          [statement_timeout_ms: 60_001],
          [unknown: true],
          [prefix: "x", prefix: "y"]
        ] do
      assert {:error, :invalid_request} = Store.new(TestRepo, declaration(), opts)
    end

    assert {:ok, %{statement_timeout_ms: 60_000}} =
             Store.new(TestRepo, declaration(), statement_timeout_ms: 60_000)

    for value <- [nil, [], 42, "classified", %{secret: "classified"}] do
      assert {:error, :invalid_request} = Store.query(b, value)
      assert {:refused, :invalid_request} = Store.put_source(value, "tenant", source(), [chunk()])
    end

    assert {:refused, :invalid_chunk} =
             Store.put_source(b, "tenant", source(), [%{chunk() | start_byte: 1, end_byte: 4}])

    assert {:refused, :invalid_request} =
             Store.put_source(b, "tenant", {"source", 0, <<0::256>>}, [chunk()])

    assert {:error, :invalid_request} = Migration.install(%{b | declaration: %{}})
  end
end
