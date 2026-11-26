# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/knowledge_ingest_test_helper.exs", __DIR__)

defmodule Elzoo.KnowledgeIngestTest do
  # Groups 1-5, 7 and 9 of the task Contract on the worker's own PostgreSQL 19 with pgvector,
  # a real Oban 2.24.2 instance (drained, so no real backoff, snooze or wait runs), a scripted
  # provider and a real state/artifact store over the disposable MinIO. Groups 3 and 6 run the
  # intent Store on integration/sql, except the one Memory case. Expected values are written
  # out by hand.
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Elzoo.{DocumentParse, TextChunking}
  alias Elzoo.DurableLog.Store
  alias Elzoo.EffectIntent.Model
  alias Elzoo.Jobs.Worker
  alias Elzoo.KnowledgeIngest, as: KI
  alias Elzoo.KnowledgeIngest.{Harness, Hooks, Script, TestRepo}
  import Elzoo.KnowledgeIngest.Cases

  @v1 [0.6, 0.8, 0.0, 0.0]
  @v2 [0.0, 0.0, 0.28, 0.96]

  setup_all do
    %{ap: Harness.module_setup!()}
  end

  ## helpers

  ## 1 Submit and config

  test "1 new/1 refuses each bad field and bound; accepts the edges", ctx do
    env = env(ctx)
    o = Harness.opts(env)
    ok = fn opts -> match?({:ok, _}, KI.new(opts)) end
    bad = fn opts -> KI.new(opts) == {:error, :invalid} end
    e = fn extra -> Harness.embedding(env.script, extra) end

    assert ok.(o)
    assert bad.(o ++ [extra: 1])
    assert bad.(Keyword.delete(o, :queue))
    assert bad.(o ++ [queue: "q"])
    assert bad.(:not_a_list)
    assert bad.(Keyword.put(o, :prefix, "Bad"))
    assert bad.(Keyword.put(o, :repo, nil))
    assert bad.(Keyword.put(o, :queue, ""))
    assert bad.(Keyword.put(o, :queue, String.duplicate("q", 65)))
    assert ok.(Keyword.put(o, :queue, String.duplicate("q", 64)))
    assert bad.(Keyword.put(o, :search, Map.put(env.search, :extra, 1)))
    assert bad.(Keyword.put(o, :artifact, %{}))
    assert bad.(Keyword.put(o, :artifact_scopes, List.duplicate("s", 17)))
    assert ok.(Keyword.put(o, :artifact_scopes, List.duplicate("s", 16)))
    assert bad.(Keyword.put(o, :artifact_scopes, ["a\0"]))
    assert bad.(Keyword.put(o, :intent, Map.put(env.intent, :allow_volatile, true)))
    assert bad.(Keyword.put(o, :intent, Map.delete(Harness.memory_intent(), :allow_volatile)))
    assert ok.(Keyword.put(o, :intent, Harness.memory_intent()))
    assert bad.(Keyword.put(o, :intent, Map.delete(env.intent, :clock)))
    assert bad.(Keyword.put(o, :max_attempts, 0))
    assert bad.(Keyword.put(o, :max_attempts, 6))
    assert ok.(Keyword.put(o, :max_attempts, 1)) and ok.(Keyword.put(o, :max_attempts, 5))
    assert bad.(Keyword.put(o, :embedding, e.(tenant: "t")))
    assert bad.(Keyword.put(o, :embedding, e.(sink: fn _, _ -> :ok end)))
    assert bad.(Keyword.put(o, :embedding, e.(max_inputs: 0)))
    assert bad.(Keyword.put(o, :embedding, e.(max_input_bytes: 7_999)))
    assert ok.(Keyword.put(o, :embedding, e.(max_input_bytes: 8_000)))
    # the request model and dimension must be the index descriptor's (test-embed, 4)
    assert bad.(Keyword.put(o, :request, %{model: "test-other"}))
    assert bad.(Keyword.put(o, :request, %{model: "test-embed", dimensions: 2}))
    assert ok.(Keyword.put(o, :request, %{model: "test-embed", dimensions: 4}))
    assert bad.(Keyword.put(o, :request, %{model: "test-embed", input_type: :query}))
    assert ok.(Keyword.put(o, :request, %{model: "test-embed", input_type: :document}))
    assert bad.(Keyword.put(o, :request, %{model: "test-embed", version: 1}))
    assert bad.(Keyword.put(o, :request, %{model: "unknown"}))
  end

  test "1 submit and the other calls refuse each bad field before any query", ctx do
    env = env(ctx)
    t = tenant()
    r = Harness.request("a1")
    c = env.c

    bad_callers = [
      %{tenant: String.duplicate("t", 65), actor: "a"},
      %{tenant: "a/b", actor: "a"},
      %{tenant: "..", actor: "a"},
      %{tenant: t, actor: "a\u0085b"},
      %{tenant: t, actor: "a\u0001"},
      %{tenant: t, actor: ""},
      %{tenant: t, actor: String.duplicate("a", 129)},
      %{tenant: t, actor: "a", extra: 1},
      %{tenant: t}
    ]

    bad_requests = [
      put_in(r.artifact.version, :head),
      put_in(r.artifact.version, 0),
      put_in(r.artifact.artifact_id, "a/b"),
      Map.put(r, :index, "handbook"),
      Map.delete(r, :chunking),
      %{r | version: 0},
      %{r | version: 2_147_483_648},
      %{r | source_ref: ""},
      %{r | source_ref: "a\u0001"},
      %{r | source_ref: String.duplicate("s", 1025)},
      %{r | media_type: "application/pdf"},
      %{r | chunking: [unknown: 1]},
      %{r | chunking: [chunk_size: 2_000, chunk_size: 2_000]},
      %{r | chunking: [format: :markdown]},
      %{r | chunking: [max_source_bytes: 10]},
      %{r | chunking: [chunk_size: 1_999]},
      %{r | chunking: [chunk_size: 8_193]},
      %{r | chunking: [chunk_overlap: 201]},
      %{r | chunking: [max_chunks: 0]},
      %{r | chunking: :none}
    ]

    for bad <- bad_callers do
      assert {{:error, :invalid}, 0} = queries(fn -> KI.submit(c, bad, r) end), inspect(bad)
      assert {{:error, :invalid}, 0} = queries(fn -> KI.status(c, bad, key(r)) end)
      assert {{:error, :invalid}, 0} = queries(fn -> KI.cancel(c, bad, key(r)) end)
      assert {{:error, :invalid}, 0} = queries(fn -> KI.resubmit(c, bad, key(r)) end)
    end

    for bad <- bad_requests,
        do: assert({{:error, :invalid}, 0} = queries(fn -> KI.submit(c, caller(t), bad) end))

    for bad <- [
          %{source_ref: "s", version: 0},
          %{source_ref: "s"},
          %{source_ref: "s", version: 1, x: 1}
        ] do
      assert {{:error, :invalid}, 0} = queries(fn -> KI.status(c, caller(t), bad) end)
      assert {{:error, :invalid}, 0} = queries(fn -> KI.cancel(c, caller(t), bad) end)
      assert {{:error, :invalid}, 0} = queries(fn -> KI.resubmit(c, caller(t), bad) end)
    end

    page = Map.merge(key(r), %{after: nil, limit: 1})

    for bad <- [
          %{page | limit: 0},
          %{page | limit: 257},
          %{page | after: :x},
          Map.delete(page, :after),
          :not_a_map,
          {:ok, {{r.source_ref, r.version}, 1_000_000, {-5, -5}}}
        ],
        do: assert({{:error, :invalid}, 0} = queries(fn -> KI.attempts(c, caller(t), bad) end))

    # the counter sees the queries of a valid call
    assert {{:error, :not_found}, n} = queries(fn -> KI.status(c, caller(t), key(r)) end)
    assert n > 0

    assert {:error, :invalid} = KI.submit(:not_a_config, caller(t), r)
    assert {:error, :invalid} = KI.status(%{}, caller(t), key(r))

    # the edges: a 64-byte tenant, versions 1 and 2^31-1, chunk_size 2,000 and 8,192 (a quarter
    # of max_input_bytes 32,768), chunk_overlap 200
    long = String.duplicate("t", 64)
    assert {:ok, %{state: :requested}} = KI.submit(c, caller(long), r)
    assert {:ok, _} = KI.submit(c, caller(t), %{r | version: 2_147_483_647})

    assert {:ok, _} =
             KI.submit(c, caller(t), %{r | source_ref: "s2", chunking: [chunk_size: 2_000]})

    assert {:ok, _} =
             KI.submit(c, caller(t), %{
               r
               | source_ref: "s3",
                 chunking: [chunk_size: 8_192, chunk_overlap: 200]
             })

    # a chunk_size over a quarter of max_input_bytes is invalid
    {:ok, narrow} =
      Harness.config(env, embedding: Harness.embedding(env.script, max_input_bytes: 8_000))

    assert {:ok, _} =
             KI.submit(narrow, caller(t), %{r | source_ref: "s4", chunking: [chunk_size: 2_000]})

    assert {:error, :invalid} =
             KI.submit(narrow, caller(t), %{r | source_ref: "s5", chunking: [chunk_size: 2_001]})
  end

  test "1 equal, other and versioned submits; two at once store one ingest and one job", ctx do
    env = env(ctx)
    t = tenant()
    r = Harness.request("a1")
    assert {:ok, %{state: :requested} = s} = KI.submit(env.c, caller(t, "first"), r)
    assert {:ok, ^s} = KI.submit(env.c, caller(t, "second"), r)

    assert {:ok, ^s} =
             KI.submit(env.c, caller(t), %{r | chunking: [chunk_size: 2_000, chunk_overlap: 200]})

    assert {:error, :conflict} = KI.submit(env.c, caller(t), put_in(r.artifact.version, 2))
    assert {:error, :conflict} = KI.submit(env.c, caller(t), %{r | media_type: "text/html"})
    assert {:error, :conflict} = KI.submit(env.c, caller(t), %{r | chunking: [chunk_overlap: 100]})

    # the second actor is not recorded
    assert [["first"]] =
             Harness.scoped!(
               t,
               ~s[SELECT actor FROM "#{env.p}".elzoo_knowledge_ingests WHERE tenant = $1]
             )

    assert length(jobs(env, "prepare")) == 1

    # versions 1 and 2 are two ingests
    assert {:ok, %{version: 2, state: :requested}} = KI.submit(env.c, caller(t), %{r | version: 2})
    assert length(jobs(env, "prepare")) == 2

    # two equal submits behind a barrier
    t2 = tenant()
    b = Harness.barrier(2)
    Hooks.on(env.hooks, :submit, fn _ -> Harness.arrive(b) end)
    tasks = for _ <- 1..2, do: Task.async(fn -> KI.submit(env.c, caller(t2), r) end)
    assert [{:ok, s1}, {:ok, s1}] = Task.await_many(tasks, 15_000)
    assert s1.state == :requested

    assert [[1]] =
             Harness.scoped!(
               t2,
               ~s[SELECT count(*) FROM "#{env.p}".elzoo_knowledge_ingests WHERE tenant = $1]
             )

    assert length(jobs(env, "prepare")) == 3
  end

  test "1 an enqueue failure, a caller transaction and REPEATABLE READ write nothing", ctx do
    env = env(ctx)
    t = tenant()
    r = Harness.request("a1")
    Hooks.on(env.hooks, :enqueue, fn _ -> {:override, {:error, :injected}} end)
    assert {:error, :unavailable} = KI.submit(env.c, caller(t), r)
    Hooks.off(env.hooks, :enqueue)
    rows = ~s[SELECT count(*) FROM "#{env.p}".elzoo_knowledge_ingests WHERE tenant = $1]
    assert [[0]] = Harness.scoped!(t, rows)
    assert Harness.jobs(env) == []

    assert {:ok, {:error, :in_transaction}} =
             TestRepo.transaction(fn -> KI.submit(env.c, caller(t), r) end)

    assert [[0]] = Harness.scoped!(t, rows)

    Harness.start!(Elzoo.KnowledgeIngest.RepeatableRepo,
      pool_size: 2,
      after_connect:
        {Postgrex, :query!, ["SET default_transaction_isolation = 'repeatable read'", []]}
    )

    rr = :"rr_oban_#{env.p}"
    pid = Harness.oban!(rr, env.p, repo: Elzoo.KnowledgeIngest.RepeatableRepo)
    on_exit(fn -> Harness.stop_oban(pid) end)
    {:ok, c} = Harness.config(env, repo: Elzoo.KnowledgeIngest.RepeatableRepo, oban: rr)
    assert {:error, :isolation} = KI.submit(c, caller(t), r)
    assert {:error, :isolation} = KI.cancel(c, caller(t), key(r))
    assert {:error, :isolation} = KI.resubmit(c, caller(t), key(r))
    assert [[0]] = Harness.scoped!(t, rows)
    assert Harness.jobs(env) == []
  end

  test "1 a step under a search binding with another index_identity fails :index_mismatch", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "some text"))
    {:ok, other} = Harness.config(env, search: Harness.search!(env.p, index_identity: "other"))
    Harness.register(env, other)
    Harness.drain(env)
    assert %{state: :failed, reason: :index_mismatch} = status(env, t, r)
    assert Script.calls(env.script) == []
  end

  ## 2 Prepare

  test "2 HTML and Markdown reach embedding with the chunker's staged chunks", ctx do
    env = env(ctx)
    t = tenant()
    html = "<html><body><h1>Title</h1><p>" <> String.duplicate("word ", 900) <> "</p></body></html>"
    md = "# Title\n\n" <> String.duplicate("para text. ", 400)
    rh = submit!(env, t, doc(env, t, html, media_type: "text/html", source_ref: "h"))
    rm = submit!(env, t, doc(env, t, md, media_type: "text/markdown", source_ref: "m"))
    Harness.drain_once(env)

    for {r, bytes, media, library} <- [
          {rh, html, "text/html", "floki 0.38.5"},
          {rm, md, "text/markdown", nil}
        ] do
      {:ok, parsed} = DocumentParse.parse(bytes, media)

      {:ok, %{chunks: expected}} =
        TextChunking.chunk(parsed.text, parsed.text_sha256, r.source_ref, format: parsed.format)

      s = status(env, t, r)
      assert s.state == :embedding
      assert s.text_sha256 == :crypto.hash(:sha256, parsed.text)
      assert s.parser == %{id: "integration/document-parse", version: 1, library: library}
      assert s.batches.total >= 1 and s.batches.done == 0
      id = ingest_id(env.p, "handbook", t, r.source_ref, 1)

      staged =
        Harness.scoped!(
          t,
          ~s[SELECT chunk_index, start_byte, end_byte, content, content_digest FROM "#{env.p}".elzoo_knowledge_chunks WHERE tenant = $1 AND ingest_id = $2 ORDER BY chunk_index],
          [id]
        )

      assert staged ==
               Enum.map(
                 expected,
                 &[&1.index, &1.start_byte, &1.end_byte, &1.content, &1.content_digest]
               )

      assert length(staged) >= 2
    end
  end

  test "2 artifact integrity mismatch, deleted and access denied fail at once", ctx do
    env = env(ctx)
    t = tenant()
    r1 = doc(env, t, "tampered " <> t, source_ref: "r1")
    [rec] = artifact_records(env, t, r1)
    assert %{status: :committed} = Elzoo.ObjectStore.put(Harness.s3!(), rec.object_key, "evil")
    r2 = doc(env, t, "deleted " <> t, source_ref: "r2")

    {:ok, _} =
      Elzoo.Artifact.delete(
        env.art,
        %{tenant: t, principal: "svc-ingest", scopes: ["read"]},
        r2.artifact.artifact_id,
        1
      )

    r3 =
      doc(env, t, "denied " <> t,
        source_ref: "r3",
        access: %{tenant: t, principals: ["someone-else"], scopes: :any}
      )

    Enum.each([r1, r2, r3], &submit!(env, t, &1))
    Harness.drain(env)
    assert %{state: :failed, reason: {:artifact, :integrity_mismatch}} = status(env, t, r1)
    assert %{state: :failed, reason: {:artifact, :deleted}} = status(env, t, r2)
    assert %{state: :failed, reason: {:artifact, :access_denied}} = status(env, t, r3)
    # each failed on its first job attempt
    assert Enum.all?(jobs(env, "prepare"), fn [_, state, _, attempt] ->
             state == "completed" and attempt == 1
           end)

    assert Script.calls(env.script) == []
  end

  defp artifact_records(env, t, r) do
    {:ok, %{record: rec}} =
      Elzoo.Artifact.get(
        env.art,
        %{tenant: t, principal: "svc-ingest", scopes: ["read"]},
        r.artifact.artifact_id,
        1
      )

    [rec]
  end

  test "2 store_unavailable is retried, and fails on the last attempt", ctx do
    env = env(ctx)
    t = tenant()
    r1 = submit!(env, t, doc(env, t, "retried " <> t, source_ref: "r1"))

    Hooks.on(env.hooks, :artifact, fn %{attempt: a} ->
      if a <= 2, do: {:override, {:error, :store_unavailable}}, else: :ok
    end)

    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r1)
    assert [[_, "completed", _, 3]] = jobs(env, "prepare")

    r2 = submit!(env, t, doc(env, t, "never " <> t, source_ref: "r2"))

    Hooks.on(env.hooks, :artifact, fn _ ->
      {:override, {:error, {:object_store_unknown, :timeout}}}
    end)

    Harness.drain(env)
    assert %{state: :failed, reason: {:artifact, :object_store_unknown}} = status(env, t, r2)
    r3 = submit!(env, t, doc(env, t, "never3 " <> t, source_ref: "r3"))
    Hooks.on(env.hooks, :artifact, fn _ -> {:override, {:error, :store_unavailable}} end)
    Harness.drain(env)
    assert %{state: :failed, reason: {:artifact, :store_unavailable}} = status(env, t, r3)
    assert [_, [_, "cancelled", _, 3], [_, "cancelled", _, 3]] = jobs(env, "prepare")
  end

  test "2 parse and chunk errors, oversized chunks and NUL fail before any provider call", ctx do
    env = env(ctx)
    t = tenant()
    r1 = submit!(env, t, doc(env, t, <<"ok", 0xFF, "x">>, source_ref: "r1"))

    r2 =
      submit!(
        env,
        t,
        doc(env, t, "<p></p><script>x()</script>", media_type: "text/html", source_ref: "r2")
      )

    r3 = submit!(env, t, doc(env, t, xs(2), source_ref: "r3", chunking: [max_chunks: 1]))
    # 2,000 grapheme clusters of 21 bytes (a and ten U+0301): one chunk of 42,000 bytes
    clusters = String.duplicate("a" <> String.duplicate("\u0301", 10), 2_000)
    assert byte_size(clusters) == 42_000
    r4 = submit!(env, t, doc(env, t, clusters, source_ref: "r4"))
    Harness.drain(env)
    assert %{state: :failed, reason: {:parse, :invalid_utf8}} = status(env, t, r1)
    assert %{state: :failed, reason: {:parse, :empty_text}} = status(env, t, r2)
    assert %{state: :failed, reason: {:chunk, :too_many_chunks}} = status(env, t, r3)
    assert %{state: :failed, reason: :chunk_too_large} = status(env, t, r4)

    # 500 quotes fit max_input_bytes, but the escaped one-input request passes 1,000 bytes
    {:ok, narrow} =
      Harness.config(env, embedding: Harness.embedding(env.script, max_request_bytes: 1_000))

    Harness.register(env, narrow)
    r5 = doc(env, t, String.duplicate("\"", 500), source_ref: "r5")
    assert {:ok, _} = KI.submit(narrow, caller(t), r5)
    Harness.drain(env)
    assert %{state: :failed, reason: :chunk_too_large} = status(env, t, r5)
    assert Script.calls(env.script) == []
  end

  test "2 text with a NUL on a text_search index fails {:index, :invalid_chunk}", ctx do
    env = env(ctx, text_search: %{config: "simple"})
    t = tenant()
    r = submit!(env, t, doc(env, t, "before\0after"))
    Harness.drain(env)
    assert %{state: :failed, reason: {:index, :invalid_chunk}} = status(env, t, r)
    assert Script.calls(env.script) == []
  end

  test "2 batches are greedy within max_request_bytes and max_inputs", ctx do
    env = env(ctx)
    t = tenant()
    exact = [chunk_overlap: 0]
    # chunks of 2,000 graphemes; a batch of k plain inputs of b bytes is 45 + k × (b + 3)
    # bytes with the model test-embed: 32 ASCII (64,141), 10 three-byte (60,075), 8 four-byte
    # (64,069), 16 of newlines only (4,000 escaped bytes: 64,093); one more passes 65,536.
    cases = [
      {"ascii", xs(33), [32, 1]},
      {"cjk", xs(11, "語"), [10, 1]},
      {"emoji", xs(9, "😀"), [8, 1]},
      {"newline", String.duplicate("\n", 2_000 * 22), [16, 6]}
    ]

    rs =
      for {ref, text, _} <- cases,
          do: submit!(env, t, doc(env, t, text, source_ref: ref, chunking: exact))

    Harness.drain_once(env)

    for {{ref, _, counts}, r} <- Enum.zip(cases, rs) do
      assert %{state: :embedding} = status(env, t, r)
      assert batch_counts(env, t, ref) == counts, ref
    end

    # max_inputs 4 bounds the count: 9 ASCII chunks give 4, 4, 1
    {:ok, four} = Harness.config(env, embedding: Harness.embedding(env.script, max_inputs: 4))
    r = doc(env, t, xs(9), source_ref: "four", chunking: exact)
    assert {:ok, _} = KI.submit(four, caller(t), r)
    Harness.register(env, four)
    Harness.drain_once(env)
    assert batch_counts(env, t, "four") == [4, 4, 1]
  end

  defp batch_counts(env, t, ref) do
    id = ingest_id(env.p, "handbook", t, ref, 1)

    Harness.scoped!(
      t,
      ~s[SELECT chunk_count FROM "#{env.p}".elzoo_knowledge_batches WHERE tenant = $1 AND ingest_id = $2 ORDER BY batch],
      [id]
    )
    |> List.flatten()
  end

  test "2 two prepare runs leave one set of staged chunks and one batch-0 job", ctx do
    env = env(ctx)
    t = tenant()
    # a second run after the first committed
    r1 = submit!(env, t, doc(env, t, xs(3), source_ref: "r1", chunking: [chunk_overlap: 0]))
    [[job1 | _]] = jobs(env, "prepare")
    first = Harness.job!(env, job1)
    assert :ok = Worker.perform(first)
    assert :ok = Worker.perform(first)
    assert %{state: :embedding} = status(env, t, r1)
    assert Harness.staged(env, t) == 3
    assert length(jobs(env, "embed")) == 1

    # two runs behind a barrier at the commit
    t2 = tenant()
    r2 = submit!(env, t2, doc(env, t2, xs(3), source_ref: "r2", chunking: [chunk_overlap: 0]))
    [_, [job2 | _]] = jobs(env, "prepare")
    b = Harness.barrier(2)
    Hooks.on(env.hooks, :prepare_commit, fn _ -> Harness.arrive(b) end)
    job = Harness.job!(env, job2)
    tasks = for _ <- 1..2, do: Task.async(fn -> Worker.perform(job) end)
    assert [:ok, :ok] = Task.await_many(tasks, 15_000)
    assert %{state: :embedding, batches: %{total: 1}} = status(env, t2, r2)
    assert Harness.staged(env, t2) == 3
    assert length(jobs(env, "embed")) == 2
  end

  test "2 a prepare run held at its commit while the ingest fails and is resubmitted writes nothing",
       ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, xs(3), chunking: [chunk_overlap: 0]))
    [[id, _, old_key, _]] = jobs(env, "prepare")
    me = self()

    Hooks.on(env.hooks, :prepare_commit, fn _ ->
      send(me, {:at_commit, self()})
      receive(do: (:go -> :ok))
    end)

    # run A of the job waits at its commit
    a = Task.async(fn -> Worker.perform(Harness.job!(env, id)) end)
    assert_receive {:at_commit, pid_a}, 30_000
    # run B of the same job fails the ingest; resubmit/3 makes a new prepare job current
    Hooks.on(env.hooks, :artifact, fn _ -> {:override, {:error, :deleted}} end)
    assert :ok = Worker.perform(Harness.job!(env, id))
    Hooks.off(env.hooks, :artifact)
    assert %{state: :failed, reason: {:artifact, :deleted}} = status(env, t, r)
    assert {:ok, %{state: :requested}} = KI.resubmit(env.c, caller(t), key(r))
    [_, [new_id, "available", new_key, _]] = jobs(env, "prepare")
    assert new_key != old_key
    # run C, the current job, begins (preparing) and waits at its commit
    c = Task.async(fn -> Worker.perform(Harness.job!(env, new_id)) end)
    assert_receive {:at_commit, pid_c}, 30_000
    assert %{state: :preparing} = status(env, t, r)
    # A is no longer the current job: its commit writes nothing
    send(pid_a, :go)
    assert :ok = Task.await(a, 15_000)
    assert %{state: :preparing} = status(env, t, r)
    assert Harness.staged(env, t) == 0
    assert jobs(env, "embed") == []
    send(pid_c, :go)
    assert :ok = Task.await(c, 15_000)
    Hooks.off(env.hooks, :prepare_commit)
    assert %{state: :embedding} = status(env, t, r)
    assert Harness.staged(env, t) == 3
    assert length(jobs(env, "embed")) == 1
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)
  end

  test "2 a prepare job that committed and then errors on its last attempt writes nothing", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "committed then error"))
    Hooks.on(env.hooks, :prepare_committed, fn _ -> raise "injected" end)
    assert {:cancel, :raised} = run(env, "prepare", %{attempt: 3, max_attempts: 3})
    assert %{state: :embedding, reason: nil} = status(env, t, r)
    Hooks.off(env.hooks, :prepare_committed)
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)
  end

  test "2 1 MiB of four-byte emoji at the default options prepares within the real deadline",
       ctx do
    env = env(ctx)
    t = tenant()
    text = String.duplicate("😀", 262_144)
    assert byte_size(text) == 1_048_576
    r = submit!(env, t, doc(env, t, text))
    assert KI.__deadlines__(env.c) == %{prepare: 120_000, embed: 90_000, index: 120_000}
    {us, _} = :timer.tc(fn -> Harness.drain_once(env) end)
    IO.puts("\n[observation] prepare of 1 MiB of four-byte emoji: #{div(us, 1000)} ms")
    assert %{state: :embedding, batches: %{total: total}} = status(env, t, r)
    assert total > 0
  end

  ## 3 Embed

  test "3 completed batches give put_source the provider's floats element for element", ctx do
    env = env(ctx)
    {:ok, c} = Harness.config(env, embedding: Harness.embedding(env.script, max_inputs: 2))
    Harness.register(env, c)
    env = %{env | c: c}
    t = tenant()
    r = submit!(env, t, doc(env, t, xs(3), chunking: [chunk_overlap: 0]))
    {:ok, seen} = Agent.start(fn -> nil end)

    Hooks.on(env.hooks, :put_source, fn %{chunks: chunks} ->
      Agent.update(seen, fn _ -> chunks end)
    end)

    Harness.drain(env)
    assert %{state: :indexed, batches: %{done: 2, total: 2}, attempts: 2} = status(env, t, r)
    chunks = Agent.get(seen, & &1)
    assert Enum.map(chunks, & &1.index) == [0, 1, 2]
    assert Enum.map(chunks, & &1.embedding.index) == [0, 1, 0]
    assert Enum.map(chunks, & &1.embedding.vector) == [@v1, @v2, @v1]
    assert Enum.all?(chunks, &(&1.embedding.descriptor == Harness.descriptor()))
    assert [[_], [_]] = Script.calls(env.script) |> Enum.map(&Enum.take(&1, 1))
  end

  test "3 a throttle with retry_after 7 snoozes 7 s; an overload without it snoozes 5 s", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "throttled"))
    Script.script(env.script, [{:status, :throttled, %{retry_after: 7}}, {:status, :overloaded}])
    Harness.drain_once(env)
    Harness.drain_once(env)
    assert snooze(env) == 7
    # the second attempt: 5 × 2^(2 − 1) s
    Oban.drain_queue(env.oban, queue: env.queue, with_scheduled: true)
    assert snooze(env) == 10
    Harness.drain(env)
    assert %{state: :indexed, attempts: 3} = status(env, t, r)
    r2 = submit!(env, t, doc(env, t, "overloaded", source_ref: "o"))
    Script.script(env.script, [{:status, :overloaded}])
    Harness.drain_once(env)
    Harness.drain_once(env)
    assert snooze(env) == 5
    Harness.drain(env)
    assert %{state: :indexed, attempts: 2} = status(env, t, r2)
    # after resubmit/3 the numbers continue: attempt 2 overloaded snoozes 5 × 2^(2 − 1) = 10 s
    r3 = submit!(env, t, doc(env, t, "after resubmit", source_ref: "rs"))
    Script.script(env.script, [:timeout, {:status, :overloaded}])
    Harness.drain(env)
    assert %{state: :failed, reason: :embedding_unknown} = status(env, t, r3)
    assert {:ok, _} = KI.resubmit(env.c, caller(t), key(r3))
    Harness.drain_once(env)
    assert snooze(env) == 10
    Harness.drain(env)
    assert %{state: :indexed, attempts: 3} = status(env, t, r3)
    id = ingest_id(env.p, "handbook", t, "doc-1", 1)

    assert [
             %{ref: ref1, batch: 0, number: 1, outcome: {:refused, :throttled}, usage: nil},
             %{ref: ref2, number: 2, outcome: {:refused, :overloaded}},
             %{ref: ref3, number: 3, outcome: :completed, usage: %{}}
           ] = attempts(env, t, r)

    assert [ref1, ref2, ref3] == ["#{id}/0/1", "#{id}/0/2", "#{id}/0/3"]
    assert length(Script.calls(env.script)) == 8
  end

  test "3 the backoff without retry_after is clamped: attempt 10 snoozes 2,560 s, 11 3,600 s",
       ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "clamped"))
    # max_attempts 3: attempts 1-3, 4-6 and 7-9 overloaded fail :embedding_exhausted, and each
    # resubmit/3 continues the numbers; 10 and 11 overloaded snooze, 12 completes
    Script.script(env.script, List.duplicate({:status, :overloaded}, 11))

    for last <- [3, 6, 9] do
      Harness.drain(env)
      assert %{state: :failed, reason: :embedding_exhausted, attempts: ^last} = status(env, t, r)
      assert {:ok, _} = KI.resubmit(env.c, caller(t), key(r))
    end

    Harness.drain_once(env)
    # attempt 10: 5 × 2^9 = 2,560 s, below the cap
    assert snooze(env) == 2_560
    Oban.drain_queue(env.oban, queue: env.queue, with_scheduled: true)
    # attempt 11: 5 × 2^10 = 5,120 s unclamped, clamped to 3,600 s
    assert snooze(env) == 3_600
    Harness.drain(env)
    assert %{state: :indexed, attempts: 12} = status(env, t, r)
  end

  defp snooze(env) do
    [[s]] =
      Harness.query!(
        TestRepo,
        ~s[SELECT round(extract(epoch FROM scheduled_at - attempted_at)) FROM "#{env.p}".oban_jobs WHERE state = 'scheduled']
      ).rows

    s |> Decimal.to_integer()
  end

  test "3 throttles on every attempt fail :embedding_exhausted at max_attempts 1 and 5", ctx do
    env = env(ctx)

    for max <- [1, 5] do
      {:ok, c} = Harness.config(env, max_attempts: max)
      Harness.register(env, c)
      t = tenant()
      r = doc(env, t, "exhausted #{max}")
      assert {:ok, _} = KI.submit(c, caller(t), r)
      Script.script(env.script, List.duplicate({:status, :throttled}, 5))
      before = length(Script.calls(env.script))
      Harness.drain(env)
      assert %{state: :failed, reason: :embedding_exhausted, attempts: ^max} = status(env, t, r)
      assert length(Script.calls(env.script)) - before == max
    end
  end

  test "3 credentials_unavailable starts a new attempt; authentication_failed fails", ctx do
    env = env(ctx)
    {:ok, gate} = Agent.start(fn -> :closed end)

    credentials = fn ->
      if Agent.get_and_update(gate, &{&1, :open}) == :closed, do: :error, else: {:ok, "sk-test-key"}
    end

    {:ok, c} =
      Harness.config(env, embedding: Harness.embedding(env.script, credentials: credentials))

    Harness.register(env, c)
    t = tenant()
    r = doc(env, t, "credentials")
    assert {:ok, _} = KI.submit(c, caller(t), r)
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)

    assert [%{outcome: {:refused, :credentials_unavailable}}, %{outcome: :completed}] =
             attempts(env, t, r)

    assert length(Script.calls(env.script)) == 1

    r2 = doc(env, t, "auth", source_ref: "auth")
    assert {:ok, _} = KI.submit(c, caller(t), r2)
    Script.script(env.script, [{:status, :authentication_failed}])
    Harness.drain(env)

    assert %{state: :failed, reason: {:embedding_refused, :authentication_failed}} =
             status(env, t, r2)
  end

  test "3 an unknown outcome and a provider that never answers fail :embedding_unknown", ctx do
    env = env(ctx, seam: %{wait_ms: 300})
    t = tenant()
    r = submit!(env, t, doc(env, t, "unknown"))
    Script.script(env.script, [:timeout])
    Harness.drain(env)
    assert %{state: :failed, reason: :embedding_unknown, attempts: 1} = status(env, t, r)
    assert [%{outcome: :unknown}] = attempts(env, t, r)
    assert length(Script.calls(env.script)) == 1

    # no delivery within the (shortened) wait: the call is dead before the job returns
    r2 = submit!(env, t, doc(env, t, "hang", source_ref: "hang"))
    Script.script(env.script, [:hang])
    Harness.drain(env)
    assert %{state: :failed, reason: :embedding_unknown} = status(env, t, r2)
    assert [%{outcome: :unknown}] = attempts(env, t, r2)
    assert length(Script.calls(env.script)) == 2
    refute Enum.any?(Script.pids(env.script), &Process.alive?/1)
  end

  test "3 resubmit after an unknown or an exhausted batch starts the next attempt", ctx do
    env = env(ctx)

    {:ok, c} =
      Harness.config(env, embedding: Harness.embedding(env.script, max_inputs: 1), max_attempts: 1)

    Harness.register(env, c)
    env = %{env | c: c}
    t = tenant()
    r = submit!(env, t, doc(env, t, blocks(2), chunking: [chunk_overlap: 0]))
    Script.script(env.script, [:ok, :timeout])
    Harness.drain(env)
    assert %{state: :failed, reason: :embedding_unknown, batches: %{done: 1}} = status(env, t, r)
    assert {:ok, %{state: :embedding}} = KI.resubmit(env.c, caller(t), key(r))
    Script.script(env.script, [{:status, :throttled}])
    Harness.drain(env)
    assert %{state: :failed, reason: :embedding_exhausted} = status(env, t, r)
    assert {:ok, %{state: :embedding}} = KI.resubmit(env.c, caller(t), key(r))
    Harness.drain(env)
    assert %{state: :indexed, attempts: 4} = status(env, t, r)

    assert [
             %{batch: 0, number: 1, outcome: :completed},
             %{batch: 1, number: 1, outcome: :unknown},
             %{batch: 1, number: 2, outcome: {:refused, :throttled}},
             %{batch: 1, number: 3, outcome: :completed}
           ] = attempts(env, t, r)

    # batch 0 was called once: calls 2..4 are batch 1's
    assert [c0, c1, c1, c1] = Script.calls(env.script)
    assert c0 != c1
  end

  test "3 a crash after the intent confirmed and before the vectors persist", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "lost"))
    once(env, :outcome, fn _ -> raise "injected" end)
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)

    assert [%{ref: ref1, outcome: :completed_lost}, %{ref: ref2, outcome: :completed}] =
             attempts(env, t, r)

    assert ref1 != ref2
    assert length(Script.calls(env.script)) == 2
    assert stored(env, t, "doc-1") == [1]

    # the same crash on the last attempt
    {:ok, c} = Harness.config(env, max_attempts: 1)
    Harness.register(env, c)
    r2 = doc(env, t, "lost last", source_ref: "last")
    assert {:ok, _} = KI.submit(c, caller(t), r2)
    once(env, :outcome, fn _ -> raise "injected" end)
    Harness.drain(env)
    assert %{state: :failed, reason: :embedding_exhausted} = status(env, t, r2)
    assert [%{outcome: :completed_lost}] = attempts(env, t, r2)
  end

  test "3 a crash after :pending and before admission records :not_dispatched", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "pending"))
    once(env, :pending, fn _ -> raise "injected" end)
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)
    assert [%{ref: ref1, outcome: :not_dispatched}, %{outcome: :completed}] = attempts(env, t, r)
    assert length(Script.calls(env.script)) == 1
    # the recovery owner admitted no intent for the first reference
    key = Model.key([t, "test:account", "knowledge-ingest-test", "embed", ref1])
    assert {:ok, %{revision: 0}} = Store.read(env.intent.store, :head, [Model.stream(key)])
  end

  test "3 under a Memory Store emptied by a restart the same crash is :unknown", ctx do
    env = env(ctx, intent: Harness.memory_intent())
    t = tenant()
    r = submit!(env, t, doc(env, t, "memory"))
    Hooks.on(env.hooks, :pending, fn _ -> raise "injected" end)
    Harness.drain_once(env)
    Harness.drain_once(env)
    Hooks.off(env.hooks, :pending)
    {:ok, c} = Harness.config(env, intent: Harness.memory_intent())
    Harness.register(env, c)
    Harness.drain(env)
    assert %{state: :failed, reason: :embedding_unknown} = status(env, t, r)
    assert [%{outcome: :unknown}] = attempts(env, t, r)
    assert Script.calls(env.script) == []
  end

  test "3 a send still running when the step's deadline kills the work is killed with it", ctx do
    env = env(ctx, seam: %{deadlines: %{embed: 500}})
    t = tenant()
    r = submit!(env, t, doc(env, t, "deadline"))
    Script.script(env.script, [:hang])
    Harness.drain_once(env)
    Harness.drain_once(env)
    # the job returned after the kill; the call is already dead and the attempt :pending
    assert [pid] = Script.pids(env.script)
    refute Process.alive?(pid)
    assert [%{outcome: :pending}] = attempts(env, t, r)
    assert [[_, "retryable", _, 1]] = jobs(env, "embed")
    Harness.drain(env)
    assert %{state: :failed, reason: :embedding_unknown} = status(env, t, r)
    assert [%{outcome: :unknown}] = attempts(env, t, r)
    assert {:ok, _} = KI.resubmit(env.c, caller(t), key(r))
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)
    refute Script.overlap?(env.script)
  end

  test "3 a dispatch reply of {:error, :task_start} after the dispatched barrier is :unknown",
       ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "task start"))
    dead = spawn(fn -> :ok end)
    Hooks.on(env.hooks, :task_supervisor, fn _ -> {:override, dead} end)
    Harness.drain(env)
    assert %{state: :failed, reason: :embedding_unknown} = status(env, t, r)
    assert [%{outcome: :unknown}] = attempts(env, t, r)
    assert Script.calls(env.script) == []
  end

  test "3 two runs holding one attempt's completed outcome record one and enqueue one job", ctx do
    for {batches, next} <- [{2, "embed/1"}, {1, "index"}] do
      env = env(ctx)
      {:ok, c} = Harness.config(env, embedding: Harness.embedding(env.script, max_inputs: 1))
      Harness.register(env, c)
      env = %{env | c: c}
      t = tenant()
      r = submit!(env, t, doc(env, t, xs(batches), chunking: [chunk_overlap: 0]))
      Harness.drain_once(env)
      me = self()
      {:ok, held} = Agent.start(fn -> nil end)

      Hooks.on(env.hooks, :outcome, fn %{number: 1, outcome: o} ->
        if match?({:completed, _}, o), do: Agent.update(held, fn _ -> o end)
        send(me, {:arrived, self()})
        receive(do: (:release -> {:override, Agent.get(held, & &1)}))
      end)

      job = Harness.job!(env, jobs(env, "embed") |> hd() |> hd())
      a = Task.async(fn -> Worker.perform(job) end)
      assert_receive {:arrived, pa}, 10_000
      b = Task.async(fn -> Worker.perform(job) end)
      assert_receive {:arrived, pb}, 10_000
      send(pa, :release)
      send(pb, :release)
      assert [:ok, :ok] = Task.await_many([a, b], 15_000)
      assert [%{number: 1, outcome: :completed}] = attempts(env, t, r)
      assert length(jobs(env, next)) == 1
      assert %{batches: %{done: 1}} = status(env, t, r)
    end
  end

  test "3 a stale embed job erroring on its last attempt writes nothing", ctx do
    env = env(ctx)
    {:ok, c} = Harness.config(env, embedding: Harness.embedding(env.script, max_inputs: 1))
    Harness.register(env, c)
    env = %{env | c: c}
    t = tenant()
    r = submit!(env, t, doc(env, t, xs(2), chunking: [chunk_overlap: 0]))
    Harness.drain_once(env)
    Harness.drain_once(env)
    assert %{state: :embedding, batches: %{done: 1}, attempts: 1} = status(env, t, r)
    batch0 = Harness.job!(env, jobs(env, "embed") |> hd() |> hd())

    Hooks.on(env.hooks, :start, fn
      %{step: :embed, batch: 0} -> raise "injected"
      _ -> :ok
    end)

    assert {:cancel, :raised} = Worker.perform(%{batch0 | attempt: 3, max_attempts: 3})
    assert %{state: :embedding, reason: nil, batches: %{done: 1}, attempts: 1} = status(env, t, r)
    Hooks.off(env.hooks, :start)
    Harness.drain_once(env)
    assert %{state: :indexing} = status(env, t, r)

    Hooks.on(env.hooks, :start, fn
      %{step: :embed, batch: 0} -> raise "injected"
      _ -> :ok
    end)

    assert {:cancel, :raised} = Worker.perform(%{batch0 | attempt: 3, max_attempts: 3})
    assert %{state: :indexing, reason: nil, attempts: 2} = status(env, t, r)
    assert length(Script.calls(env.script)) == 2
  end

  test "3 attempts/3 lists every attempt with its outcome and usage, in pages", ctx do
    env = env(ctx)
    {:ok, c} = Harness.config(env, embedding: Harness.embedding(env.script, max_inputs: 1))
    Harness.register(env, c)
    env = %{env | c: c}
    t = tenant()
    r = submit!(env, t, doc(env, t, xs(2), chunking: [chunk_overlap: 0]))
    Script.script(env.script, [{:status, :throttled}])
    Harness.drain(env)
    all = attempts(env, t, r)
    assert [{0, 1}, {0, 2}, {1, 1}] == Enum.map(all, &{&1.batch, &1.number})
    assert [nil, u1, u2] = Enum.map(all, & &1.usage)
    assert {:ok, ^u1} = Elzoo.AiModel.Usage.validate(u1)
    assert {:ok, ^u2} = Elzoo.AiModel.Usage.validate(u2)

    page = fn cursor ->
      KI.attempts(env.c, caller(t), Map.merge(key(r), %{after: cursor, limit: 1}))
    end

    assert {:ok, %{entries: [e1], next: n1}} = page.(nil)
    assert {:ok, %{entries: [e2], next: n2}} = page.(n1)
    assert {:ok, %{entries: [e3], next: nil}} = page.(n2)
    assert [e1, e2, e3] == all

    assert {:ok, %{entries: two, next: n}} =
             KI.attempts(env.c, caller(t), Map.merge(key(r), %{after: nil, limit: 2}))

    assert two == Enum.take(all, 2) and n != nil

    assert {:ok, %{entries: [^e3], next: nil}} =
             KI.attempts(env.c, caller(t), Map.merge(key(r), %{after: n, limit: 256}))

    assert {:error, :not_found} =
             KI.attempts(env.c, caller(t), %{source_ref: "none", version: 1, after: nil, limit: 1})
  end
end
