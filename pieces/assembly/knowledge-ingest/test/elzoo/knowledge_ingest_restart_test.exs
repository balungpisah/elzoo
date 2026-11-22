# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/knowledge_ingest_test_helper.exs", __DIR__)

defmodule Elzoo.KnowledgeIngestRestartTest do
  # Group 6 of the task Contract: the whole Oban instance is killed (its supervisor with reason
  # :kill, with a short shutdown grace, while the step is held at its seam), so the job row stays
  # `executing` as after a node death. A new Oban instance on the same Repo, with the runner
  # registered and Lifeline's rescue_after short, rescues the orphaned job. The intent Store runs
  # on integration/sql, so the recovered intent is read from storage.
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Elzoo.KnowledgeIngest.Cases
  alias Elzoo.KnowledgeIngest, as: KI
  alias Elzoo.KnowledgeIngest.{Harness, Hooks, Script}

  setup_all do
    %{ap: Harness.module_setup!()}
  end

  # Hold the step at `point` (once), kill the Oban instance, wait until the held step is dead
  # and its job row is still executing, then start a new instance with a short Lifeline.
  defp kill_at(env, point, match) do
    me = self()
    {:ok, flag} = Agent.start(fn -> true end)

    Hooks.on(env.hooks, point, fn info ->
      if match.(info) and Agent.get_and_update(flag, &{&1, false}) do
        send(me, {:held, self()})
        receive(do: (:never -> :ok))
      end

      :ok
    end)

    assert_receive {:held, held}, 30_000
    ref = Process.monitor(held)
    Process.exit(Oban.whereis(env.oban), :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 30_000
    Hooks.off(env.hooks, point)
    Harness.poll(fn -> Registry.lookup(Oban.Registry, env.oban) == [] end)

    Harness.poll(fn ->
      Registry.select(Oban.Registry, [{{{:"$1", :_}, :_, :_}, [{:==, :"$1", env.oban}], [true]}]) ==
        []
    end)

    assert Enum.any?(Harness.jobs(env), fn [_, state, _, _] -> state == "executing" end)

    Harness.oban!(env.oban, env.p,
      queues: [{String.to_atom(env.queue), 2}],
      shutdown_grace_period: 50,
      lifeline: [rescue_after: 200, interval: 100]
    )
  end

  defp settled(env, t, r, states) do
    Harness.poll(fn -> status(env, t, r).state in states end, 1_200)
    status(env, t, r)
  end

  test "6 a node killed during prepare, between batches and after the index write resumes to indexed",
       ctx do
    cases = [
      {"prepare", :artifact, fn _ -> true end},
      {"between", :start, &match?(%{step: :embed, batch: 1}, &1)},
      {"index", :index_committed, fn _ -> true end}
    ]

    for {name, point, match} <- cases do
      env = env(ctx, run: true)
      {:ok, c} = Harness.config(env, embedding: Harness.embedding(env.script, max_inputs: 1))
      Harness.register(env, c)
      env = %{env | c: c}
      t = tenant()
      r = doc(env, t, blocks(2), chunking: [chunk_overlap: 0])
      # hold first, then submit: the running queue starts the job at once
      held = Task.async(fn -> kill_at(env, point, match) end)
      Process.sleep(50)
      submit!(env, t, r)
      Task.await(held, 60_000)
      assert %{state: :indexed} = settled(env, t, r, [:indexed, :failed]), name
      assert stored(env, t, "doc-1") == [1], name
      assert Harness.staged(env, t) == 0, name
      # the rescued job ran again (attempt 2)
      assert Enum.any?(Harness.jobs(env), fn [_, s, _, a] -> s == "completed" and a == 2 end), name
    end
  end

  test "6 the same kill during an in-flight provider call ends :embedding_unknown", ctx do
    env = env(ctx, run: true)
    t = tenant()
    r = doc(env, t, "in flight")
    Script.script(env.script, [:hang])
    me = self()

    # hold the test until the call is live, then kill the instance
    Hooks.on(env.hooks, :pending, fn _ ->
      send(me, :pending)
      :ok
    end)

    submit!(env, t, r)
    assert_receive :pending, 30_000
    Harness.poll(fn -> Script.pids(env.script) != [] end)
    [call] = Script.pids(env.script)
    oban = Oban.whereis(env.oban)
    ref = Process.monitor(call)
    Process.exit(oban, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 30_000
    Harness.poll(fn -> Registry.lookup(Oban.Registry, env.oban) == [] end)

    Harness.poll(fn ->
      Registry.select(Oban.Registry, [{{{:"$1", :_}, :_, :_}, [{:==, :"$1", env.oban}], [true]}]) ==
        []
    end)

    assert [[_, "executing", _, 1] | _] = jobs(env, "embed")
    Hooks.off(env.hooks, :pending)

    Harness.oban!(env.oban, env.p,
      queues: [{String.to_atom(env.queue), 2}],
      shutdown_grace_period: 50,
      lifeline: [rescue_after: 200, interval: 100]
    )

    assert %{state: :failed, reason: :embedding_unknown} =
             settled(env, t, r, [:failed, :indexed])

    assert [%{outcome: :unknown}] = attempts(env, t, r)
    assert length(Script.calls(env.script)) == 1
  end

  # The stored reasons, outcomes, usage, parser and vectors, and the closed version 1 reason
  # set, decoded in a fresh VM that has loaded none of the dependency modules yet.
  test "6 a fresh VM decodes every stored term before any dependency module is loaded", ctx do
    env = env(ctx)
    t = tenant()
    many = submit!(env, t, doc(env, t, xs(2), source_ref: "many", chunking: [max_chunks: 1]))
    r = submit!(env, t, doc(env, t, "fresh"))
    # prepare, then the one batch: the vectors are still staged before the index step
    Harness.drain_once(env)
    Harness.drain_once(env)
    assert %{state: :failed, reason: {:chunk, :too_many_chunks}} = status(env, t, many)
    assert %{state: :indexing} = status(env, t, r)

    stored =
      Harness.scoped!(
        t,
        "SELECT reason FROM #{KI.table(env.c, :ingests)} WHERE tenant = $1 AND reason IS NOT NULL"
      ) ++
        Harness.scoped!(
          t,
          "SELECT parser FROM #{KI.table(env.c, :ingests)} WHERE tenant = $1 AND parser IS NOT NULL"
        ) ++
        Harness.scoped!(t, "SELECT outcome FROM #{KI.table(env.c, :attempts)} WHERE tenant = $1") ++
        Harness.scoped!(t, "SELECT usage FROM #{KI.table(env.c, :attempts)} WHERE tenant = $1") ++
        Harness.scoped!(t, "SELECT embedding FROM #{KI.table(env.c, :chunks)} WHERE tenant = $1")

    stored = List.flatten(stored)
    assert length(stored) == 5

    reasons =
      Enum.map(
        ~w(not_found access_denied expired deleted too_large invalid integrity_mismatch
           commit_failed staging_expired store_unavailable caller_transaction store_damaged
           object_store_refused object_store_absent object_store_unknown)a,
        &{:artifact, &1}
      ) ++
        Enum.map(
          [{:invalid_option, :bytes}, {:invalid_option, :opts}, {:invalid_option, :unknown_option}] ++
            [{:invalid_option, :max_bytes}] ++
            ~w(unsupported_media_type too_large invalid_utf8 parse_failed unsupported_charset
               empty_text text_too_large)a,
          &{:parse, &1}
        ) ++
        Enum.map(
          [{:invalid_option, :max_chunks}] ++
            ~w(source_too_large empty_source digest_mismatch invalid_utf8 too_many_chunks
               chunker_invariant)a,
          &{:chunk, &1}
        ) ++
        Enum.map(
          ~w(credentials_unavailable invalid_request unsupported_feature too_large
             authentication_failed permission_denied throttled overloaded not_found)a,
          &{:embedding_refused, &1}
        ) ++
        Enum.map(
          ~w(invalid_request invalid_chunk source_too_large incompatible_embedding
             extension_missing text_search_too_large isolation)a,
          &{:index, &1}
        ) ++
        [:chunk_too_large, :embedding_exhausted, :embedding_unknown, :index_mismatch] ++
        [{:step_failed, :prepare}, {:step_failed, :embed}, {:step_failed, :index}] ++
        [:pending, :completed, :completed_lost, :not_dispatched, :unknown] ++
        [{:refused, :throttled}, {:refused, :overloaded}, {:refused, :credentials_unavailable}]

    bytes = stored ++ Enum.map(reasons, &KI.encode/1)
    assert fresh_decode(bytes) == Enum.map(bytes, &{:ok, KI.decode(&1)})
  end

  defp fresh_decode(bytes) do
    file = Path.join(System.tmp_dir!(), "ki-fresh-#{System.unique_integer([:positive])}")
    File.write!(file, Enum.map_join(bytes, "\n", &Base.encode16/1))

    paths =
      for p <- :code.get_path(), p = List.to_string(p), p =~ "_build", do: ["-pa", p]

    # names no atom of the stored terms, so only the Piece's own loading can create them
    code = ~S"""
    [file] = System.argv()

    file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn hex ->
      try do
        {:ok, Elzoo.KnowledgeIngest.decode(Base.decode16!(hex))}
      rescue
        _ -> :error
      end
    end)
    |> :erlang.term_to_binary()
    |> Base.encode16()
    |> IO.write()
    """

    {out, 0} =
      System.cmd(System.find_executable("elixir"), List.flatten(paths) ++ ["-e", code, file])

    File.rm!(file)
    out |> Base.decode16!() |> :erlang.binary_to_term()
  end
end
