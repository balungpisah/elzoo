# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/knowledge_ingest_test_helper.exs", __DIR__)

defmodule Elzoo.KnowledgeIngestLifecycleTest do
  # Groups 4 (index), 5 (cancel), 7 (bounds and stranding) and 9 (status) of the task Contract,
  # on the same stack as Elzoo.KnowledgeIngestTest. Expected values are written out by hand.
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Elzoo.KnowledgeIngest.Cases
  alias Elzoo.Jobs.Worker
  alias Elzoo.KnowledgeIngest, as: KI
  alias Elzoo.KnowledgeIngest.{Harness, Hooks, Script}
  alias Elzoo.SearchData

  @v1 [0.6, 0.8, 0.0, 0.0]

  setup_all do
    %{ap: Harness.module_setup!()}
  end

  defp delete!(env, t, v), do: SearchData.delete_source(env.search, t, "doc-1", v)

  # Drain until `r` is in `state` (each pass runs the available jobs once).
  defp until(env, t, r, state, n \\ 6) do
    cond do
      status(env, t, r).state == state -> :ok
      n == 0 -> flunk("never reached #{state}: #{inspect(status(env, t, r))}")
      true -> Harness.drain_once(env) && until(env, t, r, state, n - 1)
    end
  end

  ## 4 Index

  test "4 indexed: query returns the chunks with source_digest equal to text_sha256", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "the indexed document"))
    Harness.drain(env)
    s = status(env, t, r)
    assert %{state: :indexed, batches: %{done: 1, total: 1}} = s
    assert s.text_sha256 == :crypto.hash(:sha256, "the indexed document")
    q = %{index: 0, vector: @v1, descriptor: Harness.descriptor(), provenance: provenance()}
    assert {:ok, [hit]} = query(env, t, "doc-1", q)
    assert hit.content == "the indexed document"
    assert hit.source_digest == s.text_sha256
    assert hit.version == 1
    assert Harness.staged(env, t) == 0
  end

  defp provenance do
    {:ok, p} =
      Elzoo.AiModel.Provenance.validate(%{
        model_ref: %{provider: "test", model_id: "test-embed", wire_surface: "scripted"},
        provider_model: "test-embed",
        response_id: :absent,
        request_id: "req",
        provider_piece: "test/knowledge-ingest-provider"
      })

    p
  end

  test "4 an index job run again after indexed and a host delete calls no put_source", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "index once"))
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)
    assert {:committed, 1} = delete!(env, t, 1)
    n = puts(env)
    assert :ok = run(env, "index", %{})
    assert Agent.get(n, & &1) == 0
    assert stored(env, t, "doc-1") == []
    assert %{state: :indexed} = status(env, t, r)
  end

  test "4 a crash after the write committed and before the indexed transaction", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "crash after write"))
    once(env, :index_committed, fn _ -> raise "injected" end)
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)
    assert Harness.staged(env, t) == 0
    assert stored(env, t, "doc-1") == [1]
    assert [[_, "completed", _, 2]] = jobs(env, "index")
  end

  test "4 index steps of versions 1 and 2 at once, in both commit orders, keep version 2",
       ctx do
    for first <- [1, 2] do
      env = env(ctx)
      t = tenant()
      r1 = submit!(env, t, doc(env, t, "version one"))
      r2 = submit!(env, t, doc(env, t, "version two", version: 2))
      until(env, t, r1, :indexing)
      until(env, t, r2, :indexing)
      me = self()
      b = Harness.barrier(2)

      Hooks.on(env.hooks, :put_source, fn %{version: v} ->
        Harness.arrive(b)
        if v != first, do: receive(do: (:first_done -> :ok))
        :ok
      end)

      Hooks.on(env.hooks, :index_committed, fn %{version: v} ->
        if v == first, do: send(me, :first_done)
        :ok
      end)

      Hooks.on(env.hooks, :start, fn %{step: :index} -> send(me, {:index, self()}) end)

      [j1, j2] = for [id | _] <- jobs(env, "index"), do: Harness.job!(env, id)
      tasks = for j <- [j1, j2], do: Task.async(fn -> Worker.perform(j) end)
      # route :first_done from the test process to the second writer
      pids = for _ <- 1..2, do: receive(do: ({:index, pid} -> pid))
      receive do: (:first_done -> Enum.each(pids, &send(&1, :first_done)))
      assert [:ok, :ok] = Task.await_many(tasks, 15_000)
      assert stored(env, t, "doc-1") == [2]
      assert %{state: :indexed} = status(env, t, r2)
      v1 = if first == 1, do: :indexed, else: :superseded
      assert %{state: ^v1} = status(env, t, r1)
    end
  end

  test "4 version 1's index step after version 2 is indexed ends superseded", ctx do
    env = env(ctx)
    t = tenant()
    r1 = submit!(env, t, doc(env, t, "version one"))
    until(env, t, r1, :indexing)
    # hold version 1's index job while version 2 is indexed, then run it again
    [[held | _]] = jobs(env, "index")
    :ok = Oban.cancel_job(env.oban, held)
    r2 = submit!(env, t, doc(env, t, "version two", version: 2))
    until(env, t, r2, :indexed)
    assert %{state: :indexing} = status(env, t, r1)
    :ok = Oban.retry_job(env.oban, held)
    Harness.drain(env)
    assert %{state: :superseded} = status(env, t, r1)
    assert Harness.staged(env, t) == 0
    assert stored(env, t, "doc-1") == [2]
  end

  test "4 a delete_source/4 during embedding ends the ingest superseded", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "deleted while embedding"))
    until(env, t, r, :embedding)
    assert {:committed, 0} = delete!(env, t, 1)
    Harness.drain(env)
    assert %{state: :superseded} = status(env, t, r)
    assert stored(env, t, "doc-1") == []
  end

  test "4 a delete between the committed write and the indexed transaction", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "deleted after write"))
    once(env, :index_committed, fn _ -> {:committed, 1} = delete!(env, t, 1) end)
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)
    assert stored(env, t, "doc-1") == []

    # the same delete after a crash there, followed by a re-run
    t2 = tenant()
    r2 = submit!(env, t2, doc(env, t2, "deleted after crash"))

    once(env, :index_committed, fn _ ->
      {:committed, 1} = SearchData.delete_source(env.search, t2, "doc-1", 1)
      raise "injected"
    end)

    Harness.drain(env)
    assert %{state: :superseded} = status(env, t2, r2)
    assert stored(env, t2, "doc-1") == []
  end

  test "4 non-unit vectors fail {:index, :incompatible_embedding}; indeterminate is retried",
       ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "not unit"))
    Script.script(env.script, [:nonunit])
    Harness.drain(env)
    assert %{state: :failed, reason: {:index, :incompatible_embedding}} = status(env, t, r)
    assert Harness.staged(env, t) == 1

    r2 = submit!(env, t, doc(env, t, "indeterminate", source_ref: "ind"))
    once(env, :put_source, fn _ -> {:override, {:indeterminate, :unavailable}} end)
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r2)
    assert stored(env, t, "ind") == [1]
  end

  ## 5 Cancel

  test "5 cancel in requested, preparing and embedding gives cancelled with nothing indexed",
       ctx do
    env = env(ctx)
    n = puts(env)
    t = tenant()
    r1 = submit!(env, t, doc(env, t, "requested", source_ref: "r1"))
    assert {:ok, %{state: :cancelled}} = KI.cancel(env.c, caller(t), key(r1))

    r2 = submit!(env, t, doc(env, t, "preparing", source_ref: "r2"))

    once(env, :artifact, fn _ ->
      assert %{state: :preparing} = status(env, t, r2)
      {:ok, %{state: :cancelled}} = KI.cancel(env.c, caller(t), key(r2))
      :ok
    end)

    r3 = submit!(env, t, doc(env, t, "embedding", source_ref: "r3"))
    Harness.drain_once(env)
    assert %{state: :embedding} = status(env, t, r3)
    assert {:ok, %{state: :cancelled}} = KI.cancel(env.c, caller(t), key(r3))
    Harness.drain(env)

    for r <- [r1, r2, r3], do: assert(%{state: :cancelled, reason: nil} = status(env, t, r))
    assert Agent.get(n, & &1) == 0
    assert Harness.staged(env, t) == 0
    assert Script.calls(env.script) == []
    # a second cancel returns cancelled again
    assert {:ok, %{state: :cancelled}} = KI.cancel(env.c, caller(t), key(r1))
  end

  test "5 an outcome that arrives after a cancel is recorded and writes no vector", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "late outcome"))

    once(env, :outcome, fn _ ->
      {:ok, %{state: :cancelled}} = KI.cancel(env.c, caller(t), key(r))
      :ok
    end)

    Harness.drain(env)
    assert %{state: :cancelled} = status(env, t, r)
    assert [%{outcome: :completed, usage: %{}}] = attempts(env, t, r)
    assert Harness.staged(env, t) == 0
    assert stored(env, t, "doc-1") == []
  end

  test "5 cancel in indexing, indexed, superseded and failed; resubmit outside failed", ctx do
    env = env(ctx)
    t = tenant()
    ri = submit!(env, t, doc(env, t, "indexing", source_ref: "i"))
    assert {:error, :not_failed} = KI.resubmit(env.c, caller(t), key(ri))
    until(env, t, ri, :embedding)
    assert {:error, :not_failed} = KI.resubmit(env.c, caller(t), key(ri))
    until(env, t, ri, :indexing)
    assert {:error, :indexing} = KI.cancel(env.c, caller(t), key(ri))
    assert {:error, :not_failed} = KI.resubmit(env.c, caller(t), key(ri))
    Harness.drain(env)
    assert {:error, :terminal} = KI.cancel(env.c, caller(t), key(ri))
    assert {:error, :terminal} = KI.resubmit(env.c, caller(t), key(ri))

    rs = submit!(env, t, doc(env, t, "superseded", source_ref: "s"))
    assert {:committed, 0} = SearchData.delete_source(env.search, t, "s", 1)
    Harness.drain(env)
    assert %{state: :superseded} = status(env, t, rs)
    assert {:error, :terminal} = KI.cancel(env.c, caller(t), key(rs))
    assert {:error, :terminal} = KI.resubmit(env.c, caller(t), key(rs))

    rf = submit!(env, t, doc(env, t, "failed", source_ref: "f"))
    Script.script(env.script, [{:status, :authentication_failed}])
    Harness.drain(env)
    assert %{state: :failed} = status(env, t, rf)
    assert Harness.staged(env, t) == 1
    assert {:ok, %{state: :cancelled}} = KI.cancel(env.c, caller(t), key(rf))
    assert Harness.staged(env, t) == 0
    assert {:error, :terminal} = KI.resubmit(env.c, caller(t), key(rf))
    # an equal submit never restarts a terminal or failed ingest
    assert {:ok, %{state: :cancelled}} = KI.submit(env.c, caller(t), rf)
    assert {:error, :not_found} = KI.cancel(env.c, caller(t), %{source_ref: "none", version: 1})
    assert {:error, :not_found} = KI.resubmit(env.c, caller(t), %{source_ref: "none", version: 1})
  end

  ## 7 Bounds and stranding

  test "7 a prepare past its deadline is retried; on every attempt it fails :step_failed",
       ctx do
    env = env(ctx, seam: %{deadlines: %{prepare: 300}})
    t = tenant()
    r = submit!(env, t, doc(env, t, "slow twice", source_ref: "r1"))

    Hooks.on(env.hooks, :artifact, fn %{attempt: a} ->
      if a <= 2, do: Process.sleep(2_000)
      :ok
    end)

    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)
    assert [[_, "completed", _, 3]] = jobs(env, "prepare")

    r2 = submit!(env, t, doc(env, t, "slow always", source_ref: "r2"))
    Hooks.on(env.hooks, :artifact, fn _ -> Process.sleep(2_000) end)
    Harness.drain(env)
    assert %{state: :failed, reason: {:step_failed, :prepare}} = status(env, t, r2)
  end

  test "7 a step that raises on every attempt fails {:step_failed, step}", ctx do
    env = env(ctx)
    t = tenant()

    for {step, ref} <- [prepare: "p", embed: "e", index: "i"] do
      r = submit!(env, t, doc(env, t, "raising #{step}", source_ref: ref))

      Hooks.on(env.hooks, :start, fn %{step: s} ->
        if s == step, do: raise("injected"), else: :ok
      end)

      Harness.drain(env)
      assert %{state: :failed, reason: {:step_failed, ^step}} = status(env, t, r)
      # resubmit restarts the step that failed
      Hooks.off(env.hooks, :start)
      assert {:ok, %{state: restarted}} = KI.resubmit(env.c, caller(t), key(r))
      assert restarted == %{prepare: :requested, embed: :embedding, index: :indexing}[step]
      Harness.drain(env)
      assert %{state: :indexed} = status(env, t, r)
    end
  end

  test "7 a kill of only the step's process is a job error that Oban retries", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "killed once"))
    once(env, :artifact, fn _ -> Process.exit(self(), :kill) end)
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)
    assert [[_, "completed", _, 2]] = jobs(env, "prepare")
  end

  test "7 a stranded ingest is re-enqueued by an equal submit; a live job is not", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "stranded"))
    # an equal submit while the job is live enqueues none
    assert {:ok, %{state: :requested}} = KI.submit(env.c, caller(t), r)
    assert length(jobs(env, "prepare")) == 1
    Hooks.on(env.hooks, :start, fn _ -> raise "injected" end)
    Hooks.on(env.hooks, :last_failure, fn _ -> raise "injected" end)
    Harness.drain(env)
    assert %{state: :requested, reason: nil} = status(env, t, r)
    assert [[_, "cancelled", _, 3]] = jobs(env, "prepare")
    Hooks.off(env.hooks, :start)
    Hooks.off(env.hooks, :last_failure)
    assert {:ok, %{state: :requested}} = KI.submit(env.c, caller(t), r)
    assert [[_, "cancelled", _, _], [_, "available", _, _]] = jobs(env, "prepare")
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t, r)
  end

  test "7 a replaced embed job retried while its successor is snoozed writes nothing", ctx do
    env = env(ctx)
    t = tenant()
    r = submit!(env, t, doc(env, t, "replaced"))
    until(env, t, r, :embedding)
    # strand the embed job, and let an equal submit replace it with a new job key
    [[old, "available", old_key, _]] = jobs(env, "embed")
    :ok = Oban.cancel_job(env.oban, old)
    assert {:ok, %{state: :embedding}} = KI.submit(env.c, caller(t), r)
    [_, [_, "available", new_key, _]] = jobs(env, "embed")
    assert new_key != old_key
    # the successor's attempt 1 is throttled and snoozes 60 s
    Script.script(env.script, [{:status, :throttled, %{retry_after: 60}}])
    Harness.drain_once(env)
    assert [[_, "cancelled", _, _], [_, "scheduled", _, _]] = jobs(env, "embed")
    # an operator retries the replaced job: it is not the ingest's current job
    :ok = Oban.retry_job(env.oban, old)
    Harness.drain_once(env)
    assert [[_, "completed", _, _], [_, "scheduled", _, _]] = jobs(env, "embed")
    assert length(Script.calls(env.script)) == 1
    assert [%{number: 1, outcome: {:refused, :throttled}}] = attempts(env, t, r)
    assert %{state: :embedding, reason: nil} = status(env, t, r)
    Harness.drain(env)
    assert %{state: :indexed, attempts: 2} = status(env, t, r)
    assert length(Script.calls(env.script)) == 2
  end

  test "7 the step deadlines, job attempts and backoff are the version 1 values", ctx do
    env = env(ctx)
    assert KI.__deadlines__(env.c) == %{prepare: 120_000, embed: 90_000, index: 120_000}

    {:ok, long} =
      Harness.config(env, embedding: Harness.embedding(env.script, receive_timeout_ms: 600_000))

    assert KI.__deadlines__(long).embed == 630_000
    runner = KI.runner(env.c)
    assert runner.backoff.(%Oban.Job{attempt: 1}) == 5
    assert runner.backoff.(%Oban.Job{attempt: 2}) == 10
    t = tenant()
    submit!(env, t, doc(env, t, "attempts"))
    [[id | _]] = jobs(env, "prepare")
    assert Harness.job!(env, id).max_attempts == 3
  end

  ## 9 Status

  test "9 status at each state shows the state, reason, batches and attempt count", ctx do
    env = env(ctx)
    {:ok, c} = Harness.config(env, embedding: Harness.embedding(env.script, max_inputs: 1))
    Harness.register(env, c)
    env = %{env | c: c}
    t = tenant()
    r = submit!(env, t, doc(env, t, blocks(2), chunking: [chunk_overlap: 0]))

    assert %{
             source_ref: "doc-1",
             version: 1,
             state: :requested,
             reason: nil,
             batches: %{done: 0, total: 0},
             attempts: 0,
             text_sha256: nil,
             parser: nil
           } == status(env, t, r)

    once(env, :artifact, fn _ ->
      assert %{state: :preparing, batches: %{done: 0, total: 0}, attempts: 0} = status(env, t, r)
      :ok
    end)

    Harness.drain_once(env)

    assert %{state: :embedding, batches: %{done: 0, total: 2}, attempts: 0, parser: %{}} =
             status(env, t, r)

    Harness.drain_once(env)
    assert %{state: :embedding, batches: %{done: 1, total: 2}, attempts: 1} = status(env, t, r)
    Harness.drain_once(env)
    assert %{state: :indexing, batches: %{done: 2, total: 2}, attempts: 2} = status(env, t, r)
    Harness.drain_once(env)
    s = status(env, t, r)
    assert %{state: :indexed, reason: nil, batches: %{done: 2, total: 2}, attempts: 2} = s
    assert s.text_sha256 == :crypto.hash(:sha256, blocks(2))

    rf = submit!(env, t, doc(env, t, "fails", source_ref: "f"))
    Script.script(env.script, [{:status, :not_found}])
    Harness.drain(env)

    assert %{
             state: :failed,
             reason: {:embedding_refused, :not_found},
             batches: %{done: 0, total: 1},
             attempts: 1
           } = status(env, t, rf)

    assert {:error, :not_found} = KI.status(env.c, caller(tenant()), key(r))
    assert {:error, :not_found} = KI.status(env.c, caller(t), %{source_ref: "doc-1", version: 2})
  end
end
