# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/search_data_test_helper.exs", __DIR__)

defmodule Elzoo.SearchDataTextTest do
  @moduledoc """
  ELZ-331: lexical query, source delete, version guard and the optional tenant floor, numbered
  by the task's acceptance cases.
  """
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Elzoo.SearchData, as: Store
  alias Elzoo.SearchData.{AppRepo, AppRole, DownRepo, FloorMigration, Migration}
  alias Elzoo.SearchData.{QualifiedRepo, RepeatableRepo, TextRepo}
  alias Elzoo.TenantIsolation, as: TI

  @floor_message "search data binding has no tenant_isolation option"
  @text_prefix [:elzoo, :search_data_text_test]
  @app_prefix [:elzoo, :search_data_app_test]

  setup_all do
    url =
      System.get_env("ELZOO_TEST_DATABASE_URL") ||
        raise "ELZOO_TEST_DATABASE_URL is required; tests fail closed"

    role =
      System.get_env("ELZOO_TEST_APP_ROLE") ||
        raise "ELZOO_TEST_APP_ROLE is required (ELZ-285); tests fail closed"

    unless role =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/,
      do: raise("ELZOO_TEST_APP_ROLE is not a plain identifier; refusing")

    base = [url: url, types: Elzoo.SearchData.TestTypes, log: false]
    start_supervised!({TextRepo, base ++ [pool_size: 6, telemetry_prefix: @text_prefix]})

    # A schema whose `english` is a copy of `simple`, first on the QualifiedRepo search path.
    qualified = "elz331q_" <> hex(6)
    q!(TextRepo, "CREATE SCHEMA #{qualified}")
    q!(TextRepo, "CREATE TEXT SEARCH CONFIGURATION #{qualified}.english (COPY = pg_catalog.simple)")

    q!(
      TextRepo,
      "CREATE TEXT SEARCH CONFIGURATION #{qualified}.elz_schema_only (COPY = pg_catalog.simple)"
    )

    start_supervised!(
      {QualifiedRepo,
       base ++ [pool_size: 2, parameters: [search_path: "#{qualified}, pg_catalog, public"]]}
    )

    start_supervised!(
      {RepeatableRepo,
       base ++ [pool_size: 2, parameters: [default_transaction_isolation: "repeatable read"]]}
    )

    start_supervised!(
      {AppRepo,
       base ++
         [pool_size: 4, telemetry_prefix: @app_prefix, after_connect: {AppRole, :set, [role]}]}
    )

    on_exit(fn ->
      {:ok, pid} = TextRepo.start_link(base ++ [pool_size: 1])
      q!(TextRepo, "DROP SCHEMA #{qualified} CASCADE")
      GenServer.stop(pid)
    end)

    {:ok, role: role, qualified: qualified}
  end

  setup do
    p = "elz331_" <> hex(8)
    q!(TextRepo, "CREATE SCHEMA #{p}")
    on_exit(fn -> q!(TextRepo, "DROP SCHEMA #{p} CASCADE") end)
    {:ok, b} = Store.new(TextRepo, declaration("documents"), prefix: p)
    {:ok, t} = Store.new(TextRepo, declaration("text-english", "english"), prefix: p)
    assert {:ok, ^b} = Migration.install(b)
    assert {:ok, ^t} = Migration.install(t)
    {:ok, p: p, b: b, t: t}
  end

  defp hex(n), do: Base.encode16(:crypto.strong_rand_bytes(n), case: :lower)
  defp q!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false)

  defp descriptor,
    do: %{
      provider: "openai",
      model: "test-embedding",
      dimensions: 3,
      dtype: :float32,
      normalization: :unit_l2_verified
    }

  defp declaration(id), do: %{index_identity: id, descriptor: descriptor(), metric: :cosine}

  defp declaration(id, config),
    do: Map.put(declaration(id), :text_search, %{config: config})

  defp embedding,
    do: %{
      index: 0,
      vector: [1.0, 0.0, 0.0],
      descriptor: descriptor(),
      provenance: %{
        model_ref: %{provider: "openai", model_id: "test-embedding", wire_surface: "embeddings"},
        provider_model: "test-embedding",
        response_id: :absent,
        request_id: "recorded-request",
        provider_piece: "integration/ai-embedding-openai"
      }
    }

  # Dense chunks in source order with consecutive offsets.
  defp chunks(texts) do
    texts
    |> Enum.with_index()
    |> Enum.map_reduce(0, fn {text, i}, start ->
      {%{
         index: i,
         start_byte: start,
         end_byte: start + byte_size(text),
         content: text,
         content_digest: :crypto.hash(:sha256, text),
         embedding: embedding()
       }, start + byte_size(text)}
    end)
    |> elem(0)
  end

  defp source(ref, version), do: {ref, version, :crypto.hash(:sha256, ref)}

  defp put(b, ref, version, texts, opts \\ [], tenant \\ "tenant"),
    do: Store.put_source(b, tenant, source(ref, version), chunks(texts), opts)

  defp base_request(extra),
    do:
      Map.merge(
        %{
          tenant: "tenant",
          k: 10,
          allowed_sources: ["source"],
          principal: "reader",
          checked_at: 10
        },
        extra
      )

  defp text_request(text, extra \\ %{}), do: base_request(Map.put(extra, :text, text))
  defp vector_request(extra \\ %{}), do: base_request(Map.put(extra, :query_embedding, embedding()))

  defp contents({:ok, candidates}), do: Enum.map(candidates, & &1.content)

  # Ground truth as the table owner, read past any floor in a rolled-back transaction.
  defp truth(b, sql) do
    {:error, {:rows, rows}} =
      TextRepo.transaction(fn ->
        for t <- [Store.table(b), Store.marks(b)],
            do: q!(TextRepo, "ALTER TABLE #{t} NO FORCE ROW LEVEL SECURITY")

        TextRepo.rollback({:rows, q!(TextRepo, sql).rows})
      end)

    rows
  end

  defp versions(b, ref),
    do:
      truth(
        b,
        "SELECT version, count(*) FROM #{Store.table(b)} WHERE source_ref='#{ref}' GROUP BY 1"
      )

  defp listen(prefix) do
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, prefix ++ [:query], &AppRole.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  defp statements do
    receive do
      {:query, query, _} ->
        if query in ["begin", "commit", "rollback"], do: statements(), else: [query | statements()]
    after
      0 -> []
    end
  end

  describe "1-5 lexical query" do
    test "1 hit, miss, stop words and websearch syntax", %{t: t} do
      assert {:committed, 2} = put(t, "source", 1, ["the quick brown fox", "a lazy dog"])
      assert contents(Store.query_text(t, text_request("fox"))) == ["the quick brown fox"]
      assert {:ok, []} = Store.query_text(t, text_request("zebra"))
      assert {:ok, []} = Store.query_text(t, text_request("the a of"))

      assert contents(Store.query_text(t, text_request(~s("quick brown")))) == [
               "the quick brown fox"
             ]

      assert contents(Store.query_text(t, text_request("fox or dog"))) |> length() == 2
      assert contents(Store.query_text(t, text_request("lazy -fox"))) == ["a lazy dog"]

      for text <- [~s("quick brown), ~s(""), "-", "or", ~s(fox " or -), "!(&|:*"] do
        assert {:ok, _} = Store.query_text(t, text_request(text))
      end
    end

    test "2 tenant and permitted sources filter before ranking", %{t: t} do
      assert {:committed, 1} = put(t, "source", 1, ["fox"])
      assert {:committed, 1} = put(t, "forbidden", 1, ["fox fox fox fox"])
      assert {:committed, 1} = put(t, "source", 1, ["fox fox fox fox"], [], "other-tenant")
      assert {:ok, [hit]} = Store.query_text(t, text_request("fox", %{k: 1}))
      assert {hit.content, hit.source} == {"fox", "source"}
      assert is_float(hit.rank) and not Map.has_key?(hit, :distance)
      assert {:ok, []} = Store.query_text(t, text_request("fox", %{allowed_sources: []}))
    end

    test "3 equal ranks order by C collation then chunk index; item_id equals query/2", %{t: t} do
      assert {:committed, 1} = put(t, "a", 1, ["fox"])
      assert {:committed, 2} = put(t, "B", 1, ["fox", "fox"])
      request = %{allowed_sources: ["a", "B"]}
      assert {:ok, lexical} = Store.query_text(t, text_request("fox", request))
      assert Enum.map(lexical, &{&1.source, &1.start_byte}) == [{"B", 0}, {"B", 3}, {"a", 0}]
      assert {:ok, vector} = Store.query(t, vector_request(request))
      ids = fn list -> Map.new(list, &{{&1.source, &1.start_byte}, &1.item_id}) end
      assert ids.(lexical) == ids.(vector)
    end

    test "4 content bound: overflow, exact bound and one byte below", %{p: p} do
      {:ok, s} = Store.new(TextRepo, declaration("text-simple", "simple"), prefix: p)
      assert {:ok, ^s} = Migration.install(s)
      content = String.duplicate("word ", 209_715) <> "w"
      assert byte_size(content) == 1_048_576
      sources = for i <- 1..9, do: "large-#{i}"
      for ref <- sources, do: assert({:committed, 1} = put(s, ref, 1, [content]))
      listen(@text_prefix)

      assert {:error, :invalid_request} =
               Store.query_text(
                 s,
                 text_request("word", %{allowed_sources: sources, k: 9, max_content_bytes: 1})
               )

      assert overflow_rows() == [[nil, nil, nil, nil, nil, nil, nil, nil, nil, true]]
      eight = %{allowed_sources: Enum.take(sources, 8), k: 8}

      assert {:ok, fits} =
               Store.query_text(
                 s,
                 text_request("word", Map.put(eight, :max_content_bytes, 8_388_608))
               )

      assert length(fits) == 8
      assert overflow_rows() |> Enum.map(&byte_size(Enum.at(&1, 3))) |> Enum.sum() == 8_388_608

      assert {:error, :invalid_request} =
               Store.query_text(
                 s,
                 text_request("word", Map.put(eight, :max_content_bytes, 8_388_607))
               )

      assert [[nil, nil, nil, nil, nil, nil, nil, nil, nil, true]] = overflow_rows()
    end

    test "5 text bounds and a binding without text_search", %{b: b, t: t} do
      assert {:error, :text_search_disabled} =
               Store.query_text(%{b | repo: DownRepo}, text_request("fox"))

      for text <- ["", String.duplicate("a", 4097), <<0xFF>>, "fox\0dog", :fox] do
        assert {:error, :invalid_request} = Store.query_text(t, text_request(text))
      end

      assert {:committed, 1} = put(t, "source", 1, ["fox"])
      assert {:ok, []} = Store.query_text(t, text_request("a"))
      long = String.duplicate("fox ", 1024)
      assert byte_size(long) == 4096
      assert contents(Store.query_text(t, text_request(long))) == ["fox"]

      assert {:error, :invalid_request} =
               Store.query_text(t, Map.put(text_request("fox"), :extra, 1))
    end
  end

  defp overflow_rows do
    receive do
      {:query, "\nWITH ranked AS MATERIALIZED" <> _, {:ok, %{rows: rows}}} -> rows
      {:query, "WITH ranked AS MATERIALIZED" <> _, {:ok, %{rows: rows}}} -> rows
      {:query, _, _} -> overflow_rows()
    after
      5000 -> flunk("no ranked query observed")
    end
  end

  describe "6-7 install and writes" do
    test "6 configuration checks, immutable declaration and unchanged legacy bytes", %{
      p: p,
      b: b,
      t: t
    } do
      for {repo, config} <- [
            {TextRepo, "nosuchcfg"},
            {TextRepo, "elz_schema_only"},
            {QualifiedRepo, "elz_schema_only"}
          ] do
        {:ok, other} = Store.new(repo, declaration("cfg-" <> config, config), prefix: p)
        assert {:error, :unknown_text_search_config} = Migration.install(other)

        assert [[0, nil]] =
                 q!(
                   TextRepo,
                   "SELECT (SELECT count(*) FROM #{Store.registry(b)} WHERE index_identity=$1)::int, to_regclass($2)::text",
                   ["cfg-" <> config, Store.table(other)]
                 ).rows
      end

      assert {:error, :invalid_request} =
               Store.new(TextRepo, declaration("bad", "English"), prefix: p)

      assert {:error, :invalid_request} =
               Store.new(
                 TextRepo,
                 Map.put(declaration("bad"), :text_search, %{config: "simple", schema: "x"}),
                 prefix: p
               )

      simple = put_in(t.declaration.text_search.config, "simple")
      assert {:error, :incompatible_embedding} = Migration.install(simple)
      removed = Map.delete(t.declaration, :text_search)
      assert {:error, :incompatible_embedding} = Migration.install(%{t | declaration: removed})
      added = Map.put(b.declaration, :text_search, %{config: "simple"})
      assert {:error, :incompatible_embedding} = Migration.install(%{b | declaration: added})

      # The seven-field encoding of every declaration installed before this change.
      legacy =
        :erlang.term_to_binary(
          ["documents", "openai", "test-embedding", 3, :float32, :unit_l2_verified, :cosine],
          [:deterministic]
        )

      assert [[^legacy]] =
               q!(
                 TextRepo,
                 "SELECT descriptor FROM #{Store.registry(b)} WHERE index_identity='documents'"
               ).rows

      # A re-run over an index installed before delete marks existed creates its mark table.
      q!(TextRepo, "DROP TABLE #{Store.marks(b)}")
      assert {:ok, ^b} = Migration.install(b)
      assert [[true]] = q!(TextRepo, "SELECT to_regclass($1) IS NOT NULL", [Store.marks(b)]).rows
    end

    test "6 the configuration is schema-qualified for the writer and the reader", %{p: p} do
      assert [["'cats':1"]] = q!(QualifiedRepo, "SELECT to_tsvector('english','cats')::text").rows
      {:ok, b} = Store.new(QualifiedRepo, declaration("qualified", "english"), prefix: p)
      assert {:ok, ^b} = Migration.install(b)
      assert {:committed, 1} = put(b, "source", 1, ["cats"])

      for word <- ["cat", "cats"],
          do: assert(contents(Store.query_text(b, text_request(word))) == ["cats"])
    end

    test "7 tsvector limit refuses whole; NUL content under the key only", %{b: b, t: t} do
      assert {:committed, 1} = put(t, "source", 1, ["fox"])

      words =
        for i <- 0..149_795,
            into: [],
            do:
              for(
                d <- [i, div(i, 26), div(i, 676), div(i, 17_576)],
                into: "",
                do: <<?a + rem(d, 26)>>
              ) <> "zq"

      big = Enum.join(words, " ")
      assert byte_size(big) <= 1_048_576

      assert {:refused, :text_search_too_large} =
               put(t, "source", 2, ["fox", big])

      assert versions(t, "source") == [[1, 1]]
      assert contents(Store.query_text(t, text_request("fox"))) == ["fox"]

      assert {:refused, :invalid_chunk} = put(%{t | repo: DownRepo}, "nul", 1, ["fox\0dog"])
      assert versions(t, "nul") == []
      assert {:committed, 1} = put(b, "nul", 1, ["fox\0dog"])
    end
  end

  # The advisory-lock key of one source, as the store derives it.
  defp source_key(b, tenant, ref) do
    <<n::signed-64, _::binary>> =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          [b.prefix, b.declaration.index_identity, {:source, tenant, ref}],
          [:deterministic]
        )
      )

    n
  end

  # Another connection holds the source lock until :release.
  defp hold(key) do
    parent = self()

    task =
      Task.async(fn ->
        TextRepo.transaction(
          fn ->
            q!(TextRepo, "SELECT pg_advisory_xact_lock($1)", [key])
            send(parent, {:held, self()})

            receive do
              :release -> :ok
            after
              15_000 -> raise "barrier not released"
            end
          end,
          timeout: 20_000
        )
      end)

    assert_receive {:held, pid}, 2000
    {task, pid}
  end

  defp waiting(key) do
    <<high::32, low::32>> = <<key::signed-64>>

    [[n]] =
      q!(
        TextRepo,
        "SELECT count(*)::int FROM pg_locks WHERE locktype='advisory' AND classid::bigint=$1 AND objid::bigint=$2 AND objsubid=1 AND NOT granted",
        [high, low]
      ).rows

    n
  end

  defp wait_until(check, tries \\ 300) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("the barrier condition never held")
      true -> Process.sleep(10) && wait_until(check, tries - 1)
    end
  end

  # Start each call in order, each seen waiting on the source lock before the next starts.
  defp behind_barrier(b, ref, calls) do
    key = source_key(b, "tenant", ref)
    {holder, pid} = hold(key)

    tasks =
      for {call, n} <- Enum.with_index(calls, 1) do
        task = Task.async(call)
        wait_until(fn -> waiting(key) == n end)
        task
      end

    send(pid, :release)
    Task.await(holder)
    Enum.map(tasks, &Task.await/1)
  end

  describe "8-10 delete and version guard" do
    test "8 delete of a present, absent and higher stored source", %{t: t} do
      assert {:committed, 2} = put(t, "source", 1, ["fox", "fox"])
      assert {:committed, 2} = Store.delete_source(t, "tenant", "source", 1)
      assert {:ok, []} = Store.query_text(t, text_request("fox"))
      assert {:ok, []} = Store.query(t, vector_request())
      assert {:committed, 0} = Store.delete_source(t, "tenant", "source", 1)
      assert {:committed, 0} = Store.delete_source(t, "tenant", "absent", 7)
      assert {:committed, 1} = put(t, "kept", 2, ["fox"])
      assert {:refused, :stale_version} = Store.delete_source(t, "tenant", "kept", 1)
      assert versions(t, "kept") == [[2, 1]]

      assert truth(t, "SELECT source_ref, version FROM #{Store.marks(t)} ORDER BY 1") ==
               [["absent", 7], ["source", 1]]

      for {tenant, ref, version} <- [
            {"", "s", 1},
            {"tenant", "", 1},
            {"tenant", "s", 0},
            {"tenant", "s", 2_147_483_648},
            {"tenant", "s\n", 1}
          ] do
        assert {:refused, :invalid_request} = Store.delete_source(t, tenant, ref, version)
      end
    end

    @tag :race
    test "9 delete and put race behind a barrier, both orders", %{b: b} do
      assert {:committed, 1} = put(b, "source", 1, ["old"])

      assert [{:committed, 2}, {:committed, 2}] =
               behind_barrier(b, "source", [
                 fn -> put(b, "source", 2, ["new", "new"]) end,
                 fn -> Store.delete_source(b, "tenant", "source", 2) end
               ])

      assert versions(b, "source") == []

      assert {:committed, 1} = put(b, "reverse", 1, ["old"])

      assert [{:committed, 1}, {:committed, 2}] =
               behind_barrier(b, "reverse", [
                 fn -> Store.delete_source(b, "tenant", "reverse", 2) end,
                 fn -> put(b, "reverse", 2, ["new", "new"]) end
               ])

      assert versions(b, "reverse") == [[2, 2]]
    end

    @tag :race
    test "10 guarded writes race behind a barrier, both orders", %{b: b} do
      assert [{:committed, 1}, {:committed, 1}] =
               behind_barrier(b, "rising", [
                 fn -> put(b, "rising", 1, ["v1"], if_newer: true) end,
                 fn -> put(b, "rising", 2, ["v2"], if_newer: true) end
               ])

      assert versions(b, "rising") == [[2, 1]]

      assert [{:committed, 1}, {:refused, :stale_version}] =
               behind_barrier(b, "falling", [
                 fn -> put(b, "falling", 2, ["v2"], if_newer: true) end,
                 fn -> put(b, "falling", 1, ["v1"], if_newer: true) end
               ])

      assert versions(b, "falling") == [[2, 1]]
    end

    test "10 guard against stored versions and delete marks; option shape", %{b: b} do
      assert {:committed, 1} = put(b, "source", 5, ["v5"], if_newer: true)
      assert {:refused, :stale_version} = put(b, "source", 4, ["v4"], if_newer: true)
      assert {:committed, 1} = put(b, "source", 5, ["v5 again"], if_newer: true)
      assert {:committed, 1} = Store.delete_source(b, "tenant", "source", 6)
      assert {:refused, :stale_version} = put(b, "source", 6, ["v6"], if_newer: true)
      assert {:refused, :stale_version} = put(b, "source", 3, ["v3"], if_newer: true)
      assert versions(b, "source") == []
      assert {:committed, 1} = put(b, "source", 7, ["v7"], if_newer: true)
      assert {:refused, :stale_version} = put(b, "source", 6, ["v6"], if_newer: true)
      # Unguarded writes replace any version and ignore the mark, as before.
      assert {:committed, 1} = put(b, "source", 2, ["v2"])
      assert {:committed, 1} = put(b, "source", 6, ["v6"], if_newer: false)
      assert versions(b, "source") == [[6, 1]]
      assert truth(b, "SELECT version FROM #{Store.marks(b)}") == [[6]]

      for opts <- [
            [if_newer: 1],
            [other: true],
            [if_newer: true, if_newer: true],
            %{if_newer: true},
            :x
          ] do
        assert {:refused, :invalid_request} = put(%{b | repo: DownRepo}, "source", 8, ["v8"], opts)
      end
    end
  end

  describe "11 tenant floor as the application role" do
    setup %{p: p, role: role} do
      {:ok, admin} =
        Store.new(TextRepo, declaration("floor", "simple"),
          prefix: p,
          tenant_isolation: %{prefix: p}
        )

      assert {:ok, ^admin} = Migration.install(admin)
      :persistent_term.put({FloorMigration, :binding}, admin)
      :ok = Ecto.Migrator.up(TextRepo, 1, FloorMigration, prefix: p, log: false)

      # Only the README grants.
      for sql <- [
            ~s(GRANT USAGE ON SCHEMA "#{p}" TO "#{role}"),
            ~s(GRANT SELECT ON #{Store.registry(admin)} TO "#{role}"),
            ~s(GRANT SELECT, INSERT, DELETE ON #{Store.table(admin)} TO "#{role}"),
            ~s(GRANT SELECT, INSERT, UPDATE ON #{Store.marks(admin)} TO "#{role}")
          ],
          do: q!(TextRepo, sql)

      {:ok, admin: admin, app: %{admin | repo: AppRepo}}
    end

    test "every operation is tenant-scoped and the database refuses another tenant", %{
      app: app,
      admin: admin,
      role: role
    } do
      assert [[^role, false, false]] =
               q!(
                 AppRepo,
                 "SELECT current_user, rolsuper, rolbypassrls FROM pg_roles WHERE rolname=current_user"
               ).rows

      assert :ok = Store.verify(app)
      assert {:committed, 1} = put(app, "source", 1, ["fox"], [], "T1")
      assert {:committed, 1} = put(app, "source", 1, ["fox fox fox fox"], [], "T2")
      assert {:committed, 1} = put(app, "forbidden", 1, ["fox fox fox fox"], [], "T1")
      assert {:committed, 1} = put(app, "source", 2, ["fox"], [if_newer: true], "T1")
      assert {:ok, [%{version: 2}]} = Store.query(app, vector_request(%{tenant: "T1", k: 1}))

      assert {:ok, [%{content: "fox", source: "source", version: 2}]} =
               Store.query_text(app, text_request("fox", %{tenant: "T1", k: 1}))

      assert {:committed, 1} = Store.delete_source(app, "T1", "forbidden", 1)
      assert {:committed, 0} = Store.delete_source(app, "T2", "forbidden", 1)

      assert truth(admin, "SELECT DISTINCT tenant FROM #{Store.table(admin)} ORDER BY 1") ==
               [["T1"], ["T2"]]

      assert truth(admin, "SELECT tenant FROM #{Store.marks(admin)} ORDER BY 1") == [["T1"], ["T2"]]

      assert {:ok, {[["T1"]], [["T1"]]}} =
               TI.transact(AppRepo, %{tenant: "T1"}, fn ->
                 {:ok,
                  {q!(AppRepo, "SELECT DISTINCT tenant FROM #{Store.table(app)}").rows,
                   q!(AppRepo, "SELECT tenant FROM #{Store.marks(app)}").rows}}
               end)

      zero = :binary.copy(<<0>>, 32)

      inserts = [
        {"""
         INSERT INTO #{Store.table(app)} (tenant,source_ref,version,chunk_index,content,content_digest,
           source_digest,start_byte,end_byte,embedding,embedding_descriptor,embedding_provenance,
           batch_index,text_vector)
         VALUES ('T2','direct',1,0,'\\x61'::bytea,$1,$1,0,1,'[1,0,0]','\\x00'::bytea,'\\x00'::bytea,0,
           pg_catalog.to_tsvector('pg_catalog.simple','a'))
         """, [zero]},
        {"INSERT INTO #{Store.marks(app)} (tenant,source_ref,version) VALUES ('T2','direct',1)", []}
      ]

      for {sql, params} <- inserts do
        assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
                 TI.transact(AppRepo, %{tenant: "T1"}, fn ->
                   SQL.query(AppRepo, sql, params, log: false)
                 end)
      end

      # The scope rule of the floor, checked before any query; without the floor a 129-byte
      # tenant reaches the (never started) Repo.
      down = %{app | repo: DownRepo}

      for tenant <- [String.duplicate("t", 129), "t\u0085"] do
        assert {:refused, :invalid_request} = put(down, "source", 1, ["fox"], [], tenant)
        assert {:refused, :invalid_request} = Store.delete_source(down, tenant, "source", 1)
        assert {:error, :invalid_request} = Store.query(down, vector_request(%{tenant: tenant}))

        assert {:error, :invalid_request} =
                 Store.query_text(down, text_request("fox", %{tenant: tenant}))
      end

      plain = Map.delete(down, :tenant_isolation)

      assert {:indeterminate, :unavailable} =
               put(plain, "source", 1, ["fox"], [], String.duplicate("t", 129))
    end

    test "verify reports an unprotected index; protect and new refuse bad bindings", %{
      p: p,
      app: app,
      b: b
    } do
      {:ok, open} =
        Store.new(TextRepo, declaration("unprotected"), prefix: p, tenant_isolation: %{prefix: p})

      assert {:ok, ^open} = Migration.install(open)
      assert {:error, :not_enabled} = Store.verify(%{open | repo: AppRepo})
      assert {:error, :invalid_request} = Store.verify(b)
      assert {:error, :invalid_request} = Store.verify(%{app | tenant_isolation: %{prefix: "Bad"}})
      assert_raise ArgumentError, @floor_message, fn -> Migration.protect(b) end

      assert Enum.sort(Map.keys(b)) == [:declaration, :prefix, :repo, :statement_timeout_ms]

      for opts <- [
            [prefix: p, tenant_isolation: %{prefix: "Bad"}],
            [prefix: p, tenant_isolation: %{prefix: p, spaces: []}],
            [prefix: p, tenant_isolation: p],
            [prefix: "Mixed-Case", tenant_isolation: %{prefix: p}]
          ] do
        assert {:error, :invalid_request} = Store.new(TextRepo, declaration("x"), opts)
      end

      assert {:refused, :invalid_request} =
               put(
                 %{app | tenant_isolation: %{prefix: p, extra: 1}},
                 "source",
                 1,
                 ["fox"],
                 [],
                 "T1"
               )
    end
  end

  describe "12 caller transactions and isolation level" do
    test "a caller's transaction is refused before any query, with and without the floor", %{
      p: p,
      t: t
    } do
      {:ok, floor} =
        Store.new(AppRepo, declaration("text-english", "english"),
          prefix: p,
          tenant_isolation: %{prefix: p}
        )

      for {repo, prefix, binding} <- [{TextRepo, @text_prefix, t}, {AppRepo, @app_prefix, floor}] do
        handler = listen(prefix)

        assert {:ok, :checked} =
                 repo.transaction(fn ->
                   assert {:error, :invalid_request} =
                            Store.query_text(binding, text_request("fox"))

                   assert {:refused, :invalid_request} =
                            Store.delete_source(binding, "tenant", "source", 1)

                   assert {:refused, :invalid_request} =
                            put(binding, "source", 1, ["fox"], if_newer: true)

                   assert {:refused, :invalid_request} = put(binding, "source", 1, ["fox"], [])
                   :checked
                 end)

        :telemetry.detach(handler)
        assert statements() == []
      end
    end

    test "REPEATABLE READ refuses the delete and the guarded put; unguarded put succeeds", %{b: b} do
      rr = %{b | repo: RepeatableRepo}

      assert {:ok, "repeatable read"} =
               RepeatableRepo.transaction(fn ->
                 [[level]] =
                   q!(RepeatableRepo, "SELECT current_setting('transaction_isolation')").rows

                 level
               end)

      assert {:committed, 1} = put(b, "source", 1, ["v1"])
      assert {:refused, :isolation} = Store.delete_source(rr, "tenant", "source", 1)
      assert {:refused, :isolation} = put(rr, "source", 2, ["v2"], if_newer: true)
      assert versions(b, "source") == [[1, 1]]
      assert truth(b, "SELECT count(*)::int FROM #{Store.marks(b)}") == [[0]]
      assert {:committed, 1} = put(rr, "source", 2, ["v2"])
      assert versions(b, "source") == [[2, 1]]
    end
  end
end
