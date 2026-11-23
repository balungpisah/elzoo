# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/recipe_store_test_helper.exs", __DIR__)

defmodule Elzoo.RecipeStoreGenerationTest do
  @moduledoc """
  The generation groups of `state/recipe-store` (ELZ-358): a full tenant
  stream is carried into a new generation that holds only the live state.
  `dual` scenarios run on the Memory Store and on the ready PostgreSQL Store
  (`ELZOO_TEST_DATABASE_URL`, a schema of its own for each test) over the
  disposable S3 test server (`ELZOO_TEST_S3_*`); the others name the Memory
  Store. A missing service fails the run: nothing is skipped. Expected rows and
  states are written out here from the rules of the task, not taken from the
  Piece.
  """
  use ExUnit.Case, async: false
  import Elzoo.RecipeStore.DualCase

  alias Elzoo.{Artifact, RecipeStore}
  alias Elzoo.RecipeStore.TestHelper, as: H
  alias Elzoo.RecipeStore.TestRepo

  @moduletag backend: :memory
  @moduletag timeout: 900_000

  setup_all do
    {:ok, repo} = TestRepo.start_link(url: H.url!())
    Process.unlink(repo)
    on_exit(fn -> Supervisor.stop(repo) end)
    H.database_guard!(TestRepo)
    H.object_store!()
    :ok
  end

  setup %{backend: backend} do
    store =
      case backend do
        :memory ->
          H.memory_store()

        :postgres ->
          prefix = H.schema!(TestRepo)
          on_exit(fn -> H.drop!(TestRepo, prefix) end)
          H.pg_store(prefix)
      end

    tenant = H.tenant()
    %{store: store, tenant: tenant, c: H.caller(tenant)}
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp m(id, extra \\ []), do: Map.new([{"v", 1}, {"identity", id}] ++ extra)
  defp j(id, extra \\ []), do: Jason.encode!(m(id, extra))
  defp header(from, k), do: %{"from" => from, "records" => k, "v" => 1}

  defp put!(rs, c, package) do
    {:ok, identity} = RecipeStore.put(rs, c, package)
    identity
  end

  defp revision(store, stream) do
    {:ok, head} = Elzoo.DurableLog.Store.read(store, :head, [stream])
    head.revision
  end

  defp batch!(store, stream, kind, payloads) do
    for chunk <- Enum.chunk_every(payloads, 500),
        do: :ok = H.append!(store, stream, kind, chunk)

    :ok
  end

  # Settled pin and unpin pairs of `id` (and one unpin of a never-pinned Run ID
  # when the count is odd) until `stream` holds `total` records.
  defp settle!(store, stream, id, total) do
    n = total - revision(store, stream)
    runs = for i <- 1..div(n, 2)//1, do: j(id, [{"run_id", "settled-#{i}"}])
    batch!(store, stream, "recipe_pinned", runs)
    batch!(store, stream, "recipe_unpinned", runs)

    if rem(n, 2) == 1,
      do: batch!(store, stream, "recipe_unpinned", [j(id, [{"run_id", "settled-odd"}])])

    assert revision(store, stream) == total
  end

  defp entry(id, flags),
    do: Map.merge(%{identity: id, checked: false, pins: 0, published: false, deleted: false}, flags)

  # Group 1's generation 1: A checked 7 and published; B checked 9 then 3, live
  # pins r-2 and r-1 and a settled pair r-0; C checked 5 and marked deleted; D
  # stored only; then settled filler to 10,000 records.
  defp group1!(store, rs, c, tenant) do
    [a, b, cc, d] = ids = for n <- ~w(a b c d), do: put!(rs, c, H.package(name: n))
    s1 = H.stream(tenant)

    :ok =
      batch!(store, s1, "recipe_checked", [
        j(a, [{"upper_cost", 7}]),
        j(b, [{"upper_cost", 9}]),
        j(b, [{"upper_cost", 3}]),
        j(cc, [{"upper_cost", 5}])
      ])

    :ok = batch!(store, s1, "recipe_pinned", for(r <- ~w(r-2 r-1 r-0), do: j(b, [{"run_id", r}])))
    :ok = batch!(store, s1, "recipe_unpinned", [j(b, [{"run_id", "r-0"}])])
    :ok = batch!(store, s1, "recipe_deleted", [j(cc)])
    :ok = batch!(store, s1, "recipe_published", [j(a)])
    settle!(store, s1, d, 10_000)
    ids
  end

  defp group1_versions([a, b, cc, d]),
    do: [
      entry(a, %{checked: true, published: true}),
      entry(b, %{checked: true, pins: 2}),
      entry(cc, %{checked: true, deleted: true}),
      entry(d, %{})
    ]

  # The carry of group 1's state, written out from the rules.
  defp group1_carry([a, b, cc, d]),
    do: [
      {"recipe_carried", header(1, 11)},
      {"recipe_stored", m(a)},
      {"recipe_checked", m(a, [{"upper_cost", 7}])},
      {"recipe_stored", m(b)},
      {"recipe_checked", m(b, [{"upper_cost", 3}])},
      {"recipe_pinned", m(b, [{"run_id", "r-1"}])},
      {"recipe_pinned", m(b, [{"run_id", "r-2"}])},
      {"recipe_stored", m(cc)},
      {"recipe_checked", m(cc, [{"upper_cost", 5}])},
      {"recipe_deleted", m(cc)},
      {"recipe_stored", m(d)},
      {"recipe_published", m(a)}
    ]

  # A fold written in the test: versions with flags, latest upper cost and pin
  # set, stored order and the published pointer.
  defp fold(rows) do
    touch = fn s, id, f ->
      case s.versions do
        %{^id => v} -> %{s | versions: Map.put(s.versions, id, f.(v))}
        _ -> s
      end
    end

    Enum.reduce(rows, %{order: [], versions: %{}, published: nil}, fn
      {"recipe_stored", %{"identity" => id}}, s ->
        if Map.has_key?(s.versions, id),
          do: s,
          else: %{
            s
            | order: s.order ++ [id],
              versions:
                Map.put(s.versions, id, %{
                  checked: false,
                  cost: nil,
                  pins: MapSet.new(),
                  deleted: false
                })
          }

      {"recipe_checked", %{"identity" => id, "upper_cost" => cost}}, s ->
        touch.(s, id, &%{&1 | checked: true, cost: cost})

      {"recipe_deleted", %{"identity" => id}}, s ->
        touch.(s, id, &%{&1 | deleted: true})

      {"recipe_pinned", %{"identity" => id, "run_id" => r}}, s ->
        touch.(s, id, &%{&1 | pins: MapSet.put(&1.pins, r)})

      {"recipe_unpinned", %{"identity" => id, "run_id" => r}}, s ->
        touch.(s, id, &%{&1 | pins: MapSet.delete(&1.pins, r)})

      {"recipe_published", %{"identity" => id}}, s ->
        %{s | published: id}
    end)
  end

  defp project(state),
    do:
      for(
        id <- state.order,
        do:
          entry(id, %{
            checked: state.versions[id].checked,
            pins: MapSet.size(state.versions[id].pins),
            published: id == state.published,
            deleted: state.versions[id].deleted
          })
      )

  defp expected_carry(state, from) do
    facts =
      Enum.flat_map(state.order, fn id ->
        v = state.versions[id]

        [{"recipe_stored", m(id)}] ++
          if(v.checked, do: [{"recipe_checked", m(id, [{"upper_cost", v.cost}])}], else: []) ++
          if(v.deleted, do: [{"recipe_deleted", m(id)}], else: []) ++
          for(r <- Enum.sort(v.pins), do: {"recipe_pinned", m(id, [{"run_id", r}])})
      end) ++
        if(state.published, do: [{"recipe_published", m(state.published)}], else: [])

    [{"recipe_carried", header(from, length(facts))} | facts]
  end

  # Every stream of the tenant that a test may touch, for "nothing was written".
  defp snapshot(store, tenant, n \\ 4), do: for(g <- 1..n, do: H.rows(store, H.stream(tenant, g)))

  defp once do
    {:ok, agent} = Agent.start_link(fn -> true end)
    fn -> Agent.get_and_update(agent, &{&1, false}) end
  end

  # ── 1 ────────────────────────────────────────────────────────────────

  describe "carry_keeps_live_state" do
    dual "a change on a full generation writes generation 2 with only the live state",
         %{store: store, c: c, tenant: tenant} do
      %{rs: rs} = H.build(store)
      [a, b, cc, d] = ids = group1!(store, rs, c, tenant)
      pkg_a = H.package(name: "a")

      assert {:ok, group1_versions(ids)} == RecipeStore.versions(rs, c)
      assert {:ok, ^a} = RecipeStore.published(rs, c)
      assert {:ok, ^pkg_a} = RecipeStore.get(rs, c, a)

      assert {:ok, :pinned} = RecipeStore.pin(rs, c, d, "d-1")

      assert H.rows(store, H.stream(tenant, 2)) ==
               group1_carry(ids) ++ [{"recipe_pinned", m(d, [{"run_id", "d-1"}])}]

      assert revision(store, H.stream(tenant)) == 10_000

      [va, vb, vc, vd] = group1_versions(ids)
      assert {:ok, [va, vb, vc, %{vd | pins: 1}]} == RecipeStore.versions(rs, c)
      assert {:ok, ^a} = RecipeStore.published(rs, c)
      assert {:ok, ^pkg_a} = RecipeStore.get(rs, c, a)

      # Only the carried pins hold B; A is published; C stays deleted.
      assert {:error, :pinned} = RecipeStore.delete(rs, c, b)
      assert {:error, :published} = RecipeStore.delete(rs, c, a)
      assert {:error, :deleted} = RecipeStore.put(rs, c, H.package(name: "c"))
      assert {:ok, [_, _, %{identity: ^cc, deleted: true}, _]} = RecipeStore.versions(rs, c)

      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, b, "r-1")

      assert List.last(H.rows(store, H.stream(tenant, 2))) ==
               {"recipe_unpinned", m(b, [{"run_id", "r-1"}])}

      assert {:ok, [_, %{identity: ^b, pins: 1}, _, _]} = RecipeStore.versions(rs, c)
      assert revision(store, H.stream(tenant)) == 10_000
      assert revision(store, H.stream(tenant, 3)) == 0
    end
  end

  # ── 2 ────────────────────────────────────────────────────────────────

  describe "carry_equals_fold" do
    @tag backend: :memory
    test "50 seeded random sequences: the carry folds to the state of the full generation" do
      for seed <- 1..50 do
        :rand.seed(:exsss, {seed, 358, 1})
        store = H.memory_store()
        tenant = H.tenant()
        c = H.caller(tenant)
        %{rs: rs} = H.build(store)
        packages = for i <- 1..:rand.uniform(6), do: H.package(name: "p-#{i}")
        runs = for i <- 1..:rand.uniform(8), do: "r-#{i}"

        for _ <- 1..40 do
          package = Enum.random(packages)
          id = package["identity"]
          run = Enum.random(runs)

          case :rand.uniform(7) do
            n when n in [1, 2] ->
              RecipeStore.put(rs, c, package)

            3 ->
              costs = [
                %{"callable" => "main", "node" => "fetch", "estimate" => :rand.uniform(50)},
                %{"callable" => "main", "node" => "review", "estimate" => 2}
              ]

              RecipeStore.check(rs, c, id, H.facts(%{"costs" => costs}))

            4 ->
              RecipeStore.publish(rs, c, id)

            5 ->
              RecipeStore.pin(rs, c, id, run)

            6 ->
              RecipeStore.unpin(rs, c, id, run)

            7 ->
              RecipeStore.delete(rs, c, id)
          end
        end

        s1 = H.stream(tenant)
        settle!(store, s1, hd(packages)["identity"], 10_000)
        state = fold(H.rows(store, s1))
        assert {:ok, before} = RecipeStore.versions(rs, c)
        assert before == project(state)
        assert {:ok, published} = RecipeStore.published(rs, c)
        assert published == state.published

        extra = H.package(name: "extra")
        assert {:ok, eid} = RecipeStore.put(rs, c, extra)

        assert [{"recipe_carried", %{"records" => k} = head} | rest] =
                 H.rows(store, H.stream(tenant, 2))

        assert {carried, [{"recipe_stored", %{"identity" => ^eid}}]} = Enum.split(rest, k)
        assert head == header(1, length(carried)), "seed #{seed}"
        assert fold(carried) == state, "seed #{seed}"
        assert [{"recipe_carried", head} | carried] == expected_carry(state, 1), "seed #{seed}"

        assert {:ok, before ++ [entry(eid, %{})]} == RecipeStore.versions(rs, c)
        assert {:ok, published} == RecipeStore.published(rs, c)
        assert revision(store, s1) == 10_000
      end
    end
  end

  # ── 3 ────────────────────────────────────────────────────────────────

  defp bound(g), do: 2 * Enum.find(0..64, &(Integer.pow(2, &1) >= g + 1)) + 2

  describe "live_generation_search" do
    @tag backend: :memory
    test "versions/2 reads generation G with at most 2·⌈log₂(G + 1)⌉ + 2 head reads; a pin appends there",
         %{store: store} do
      {:ok, heads} = Agent.start_link(fn -> 0 end)
      %{rs: rs} = H.build(store, head_hook: fn _ -> Agent.update(heads, &(&1 + 1)) end)

      for g <- [1, 2, 3, 4, 5, 8, 9, 16, 17] do
        tenant = H.tenant()
        c = H.caller(tenant)
        id = put!(rs, c, H.package())
        sg = H.stream(tenant, g)

        # Generations 2 to G − 1 need only be non-empty; generation G is complete.
        for n <- 2..(g - 1)//1,
            do:
              :ok =
                H.append!(store, H.stream(tenant, n), "recipe_carried", [
                  Jason.encode!(header(n - 1, 0))
                ])

        if g > 1,
          do: :ok = H.append!(store, sg, "recipe_carried", [Jason.encode!(header(g - 1, 2))])

        if g > 1, do: :ok = H.append!(store, sg, "recipe_stored", [j(id)])
        :ok = H.append!(store, sg, "recipe_pinned", [j(id, [{"run_id", "live"}])])

        Agent.update(heads, fn _ -> 0 end)
        assert {:ok, [entry(id, %{pins: 1})]} == RecipeStore.versions(rs, c), "G = #{g}"
        assert Agent.get(heads, & &1) <= bound(g), "G = #{g}: #{Agent.get(heads, & &1)} head reads"

        assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "p")
        assert List.last(H.rows(store, sg)) == {"recipe_pinned", m(id, [{"run_id", "p"}])}
        assert revision(store, H.stream(tenant, g + 1)) == 0

        # A full last generation makes the next pin write generation G + 1.
        settle!(store, sg, id, 10_000)
        assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "q")

        assert H.rows(store, H.stream(tenant, g + 1)) == [
                 {"recipe_carried", header(g, 3)},
                 {"recipe_stored", m(id)},
                 {"recipe_pinned", m(id, [{"run_id", "live"}])},
                 {"recipe_pinned", m(id, [{"run_id", "p"}])},
                 {"recipe_pinned", m(id, [{"run_id", "q"}])}
               ],
               "G = #{g}"

        assert revision(store, sg) == 10_000
      end
    end
  end

  # ── 4 ────────────────────────────────────────────────────────────────

  describe "stopped_carry" do
    # The carry of group 1's state, 12 records, takes four appends of at most 3.
    defp small_batches(store, hook),
      do: H.build(store, log_hook: hook, log_limits: %{H.limits() | max_batch_size: 3})

    defp seen_hook(test_pid, g2, reply_for) do
      fn stream, expected, records ->
        if stream == g2, do: send(test_pid, {:append, expected, length(records)})
        reply_for.(stream, expected, records)
      end
    end

    defp seen do
      receive do
        {:append, expected, n} -> [{expected, n} | seen()]
      after
        0 -> []
      end
    end

    dual "an indeterminate second batch: reads give generation 1; the next change appends only what is missing",
         %{store: store, c: c, tenant: tenant} do
      g2 = H.stream(tenant, 2)
      fire = once()

      hook =
        seen_hook(self(), g2, fn s, expected, _ ->
          if s == g2 and expected == 3 and fire.(),
            do: {:reply, {:indeterminate, %{cause: :timeout}}},
            else: :pass
        end)

      %{rs: rs} = small_batches(store, hook)
      [a, _, _, d] = ids = group1!(store, rs, c, tenant)
      carry = group1_carry(ids)

      assert {:error, :indeterminate} = RecipeStore.pin(rs, c, d, "d-1")
      assert seen() == [{0, 3}, {3, 3}]
      assert H.rows(store, g2) == Enum.take(carry, 3)

      written = snapshot(store, tenant)
      assert {:ok, group1_versions(ids)} == RecipeStore.versions(rs, c)
      assert {:ok, ^a} = RecipeStore.published(rs, c)
      pkg_a = H.package(name: "a")
      assert {:ok, ^pkg_a} = RecipeStore.get(rs, c, a)
      assert snapshot(store, tenant) == written

      assert {:ok, :pinned} = RecipeStore.pin(rs, c, d, "d-2")
      assert seen() == [{3, 3}, {6, 3}, {9, 3}, {12, 1}]
      assert H.rows(store, g2) == carry ++ [{"recipe_pinned", m(d, [{"run_id", "d-2"}])}]
      assert revision(store, H.stream(tenant)) == 10_000
    end

    dual "a reply lost after the batch committed: the next change appends only what is still missing",
         %{store: store, c: c, tenant: tenant} do
      g2 = H.stream(tenant, 2)
      fire = once()
      {module, _} = store

      hook =
        seen_hook(self(), g2, fn s, expected, records ->
          if s == g2 and expected == 3 and fire.() do
            {:committed, 6} = module.append(store, s, expected, records, [])
            {:reply, {:indeterminate, %{cause: :timeout}}}
          else
            :pass
          end
        end)

      %{rs: rs} = small_batches(store, hook)
      [_, _, _, d] = ids = group1!(store, rs, c, tenant)
      carry = group1_carry(ids)

      assert {:error, :indeterminate} = RecipeStore.pin(rs, c, d, "d-1")
      assert H.rows(store, g2) == Enum.take(carry, 6)
      assert {:ok, group1_versions(ids)} == RecipeStore.versions(rs, c)
      assert seen() == [{0, 3}, {3, 3}]

      assert {:ok, :pinned} = RecipeStore.pin(rs, c, d, "d-2")
      assert seen() == [{6, 3}, {9, 3}, {12, 1}]
      assert H.rows(store, g2) == carry ++ [{"recipe_pinned", m(d, [{"run_id", "d-2"}])}]
    end

    dual "a conflicting writer completes the carry; the paused change reads again and appends after it",
         %{store: store, c: c, tenant: tenant} do
      g2 = H.stream(tenant, 2)
      hook = H.pause_once(self(), fn s, expected, _ -> s == g2 and expected == 3 end)
      %{rs: rs} = small_batches(store, hook)
      [_, _, _, d] = ids = group1!(store, rs, c, tenant)

      first = Task.async(fn -> RecipeStore.pin(rs, c, d, "d-1") end)
      assert_receive {:paused, pid}, 30_000
      assert H.rows(store, g2) == Enum.take(group1_carry(ids), 3)
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, d, "d-2")
      send(pid, :go)
      assert {:ok, :pinned} = Task.await(first, 60_000)

      assert H.rows(store, g2) ==
               group1_carry(ids) ++
                 [
                   {"recipe_pinned", m(d, [{"run_id", "d-2"}])},
                   {"recipe_pinned", m(d, [{"run_id", "d-1"}])}
                 ]

      [va, vb, vc, vd] = group1_versions(ids)
      assert {:ok, [va, vb, vc, %{vd | pins: 2}]} == RecipeStore.versions(rs, c)
    end

    dual "a written prefix that differs from the carry is {:log, :malformed}; a put writes no bytes",
         %{store: store, c: c, tenant: tenant} do
      g2 = H.stream(tenant, 2)
      %{rs: rs} = small_batches(store, fn _, _, _ -> :pass end)
      [a, _, _, d] = ids = group1!(store, rs, c, tenant)

      :ok = H.append!(store, g2, "recipe_carried", [Jason.encode!(header(1, 11))])
      :ok = H.append!(store, g2, "recipe_stored", [j(a)])
      :ok = H.append!(store, g2, "recipe_checked", [j(a, [{"upper_cost", 8}])])
      written = snapshot(store, tenant)

      assert {:error, {:log, :malformed}} = RecipeStore.pin(rs, c, d, "d-1")
      assert snapshot(store, tenant) == written

      %{rs: refusing, art: art} = H.build(store, object_store: H.absent_bucket_object_store!())
      late = H.package(name: "late")
      assert {:error, {:log, :malformed}} = RecipeStore.put(refusing, c, late)
      assert {:error, :not_found} = Artifact.versions(art, c, H.artifact_id(late["identity"]))
      assert snapshot(store, tenant) == written

      # The incomplete generation 2 is not live: a read answers from generation 1.
      assert {:ok, group1_versions(ids)} == RecipeStore.versions(rs, c)
    end
  end

  # ── 5 ────────────────────────────────────────────────────────────────

  describe "one_order_across_a_carry" do
    defp full_with_free_version!(store, rs, c, tenant) do
      id = put!(rs, c, H.package(name: "v"))
      settle!(store, H.stream(tenant), id, 10_000)
      id
    end

    defp first_carry_batch?(tenant),
      do: fn s, expected, _ -> s == H.stream(tenant, 2) and expected == 0 end

    dual "the pin arrives first across the carry: the delete is :pinned",
         %{store: store, c: c, tenant: tenant} do
      %{rs: rs, art: art} =
        H.build(store, log_hook: H.pause_once(self(), first_carry_batch?(tenant)))

      id = full_with_free_version!(store, rs, c, tenant)

      del = Task.async(fn -> RecipeStore.delete(rs, c, id) end)
      assert_receive {:paused, pid}, 30_000
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "run-1")
      send(pid, :go)

      assert {:error, :pinned} = Task.await(del, 60_000)
      assert {:ok, [entry(id, %{pins: 1})]} == RecipeStore.versions(rs, c)
      assert {:ok, [%{state: :committed}]} = Artifact.versions(art, c, H.artifact_id(id))
    end

    dual "the delete arrives first across the carry: the pin is :deleted",
         %{store: store, c: c, tenant: tenant} do
      %{rs: rs, art: art} =
        H.build(store, log_hook: H.pause_once(self(), first_carry_batch?(tenant)))

      id = full_with_free_version!(store, rs, c, tenant)

      pin = Task.async(fn -> RecipeStore.pin(rs, c, id, "run-1") end)
      assert_receive {:paused, pid}, 30_000
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)
      send(pid, :go)

      assert {:error, :deleted} = Task.await(pin, 60_000)
      assert {:ok, [entry(id, %{deleted: true})]} == RecipeStore.versions(rs, c)
      assert {:ok, [%{state: :deleted}]} = Artifact.versions(art, c, H.artifact_id(id))
    end

    dual "10 concurrent rounds on full generations: exactly one of pin and delete succeeds",
         %{store: store} do
      %{rs: rs, art: art} = H.build(store)

      for round <- 1..10 do
        tenant = H.tenant()
        c = H.caller(tenant)
        id = full_with_free_version!(store, rs, c, tenant)

        [pin, del] =
          [
            Task.async(fn -> RecipeStore.pin(rs, c, id, "run-1") end),
            Task.async(fn -> RecipeStore.delete(rs, c, id) end)
          ]
          |> Task.await_many(60_000)

        {:ok, versions} = RecipeStore.versions(rs, c)
        assert revision(store, H.stream(tenant)) == 10_000

        case {pin, del} do
          {{:ok, :pinned}, {:error, :pinned}} ->
            assert versions == [entry(id, %{pins: 1})]
            assert {:ok, [%{state: :committed}]} = Artifact.versions(art, c, H.artifact_id(id))

          {{:error, :deleted}, {:ok, :deleted}} ->
            assert versions == [entry(id, %{deleted: true})]
            assert {:ok, [%{state: :deleted}]} = Artifact.versions(art, c, H.artifact_id(id))

          other ->
            flunk("not exactly one winner in round #{round}: #{inspect(other)}")
        end
      end
    end
  end

  # ── 6 ────────────────────────────────────────────────────────────────

  describe "frozen_full_generation" do
    dual "an unpin carries a full generation while a pin waits with an older carry; the unpin is kept",
         %{store: store, c: c, tenant: tenant} do
      s1 = H.stream(tenant)
      g2 = H.stream(tenant, 2)

      hook =
        H.pause_once(self(), fn s, expected, _ -> s == g2 and expected == 0 end)

      %{rs: rs} = H.build(store, log_hook: hook)
      id = put!(rs, c, H.package())
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "live-1")
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "live-2")
      settle!(store, s1, id, 10_000)

      # X computed the carry of generation 1 (live-1 and live-2) and waits.
      x = Task.async(fn -> RecipeStore.pin(rs, c, id, "x") end)
      assert_receive {:paused, pid}, 30_000
      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, id, "live-1")
      send(pid, :go)
      assert {:ok, :pinned} = Task.await(x, 60_000)

      rows = H.rows(store, g2)

      assert rows == [
               {"recipe_carried", header(1, 3)},
               {"recipe_stored", m(id)},
               {"recipe_pinned", m(id, [{"run_id", "live-1"}])},
               {"recipe_pinned", m(id, [{"run_id", "live-2"}])},
               {"recipe_unpinned", m(id, [{"run_id", "live-1"}])},
               {"recipe_pinned", m(id, [{"run_id", "x"}])}
             ]

      assert fold(tl(rows)).versions[id].pins == MapSet.new(["live-2", "x"])
      assert {:ok, [entry(id, %{pins: 2})]} == RecipeStore.versions(rs, c)
      assert revision(store, s1) == 10_000
    end
  end

  # ── 7 ────────────────────────────────────────────────────────────────

  describe "stream_full_only_for_a_large_live_state" do
    # A checked version with `pins` live pins, then settled filler to 10,000:
    # its carry is 1 + 2 + pins records.
    defp live_state!(store, rs, c, tenant, pins) do
      s1 = H.stream(tenant)
      pkg = H.package()
      id = put!(rs, c, pkg)
      {:ok, _} = RecipeStore.check(rs, c, id, H.facts())
      :ok = batch!(store, s1, "recipe_pinned", for(i <- 1..pins, do: j(id, [{"run_id", "p-#{i}"}])))
      settle!(store, s1, id, 10_000)
      {id, pkg}
    end

    @tag backend: :memory
    test "a carry of exactly 5,000 records is written", %{store: store, c: c, tenant: tenant} do
      %{rs: rs} = H.build(store)
      {id, _} = live_state!(store, rs, c, tenant, 4_997)

      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "new")

      rows = H.rows(store, H.stream(tenant, 2))
      assert hd(rows) == {"recipe_carried", header(1, 4_999)}
      assert length(rows) == 5_001
      assert List.last(rows) == {"recipe_pinned", m(id, [{"run_id", "new"}])}
      assert {:ok, [entry(id, %{checked: true, pins: 4_998})]} == RecipeStore.versions(rs, c)
    end

    @tag backend: :memory
    test "a carry of 5,001 records refuses each change that appends with :stream_full; nothing is written",
         %{store: store, c: c, tenant: tenant} do
      %{rs: rs, art: rs_art} = H.build(store)
      # A free version (stored only): header 1 + free 1 + id 2 + 4,997 pins = 5,001.
      free = put!(rs, c, H.package(name: "free"))
      {id, pkg} = live_state!(store, rs, c, tenant, 4_997)
      written = snapshot(store, tenant)

      assert {:error, :stream_full} = RecipeStore.delete(rs, c, free)
      assert {:ok, [%{state: :committed}]} = Artifact.versions(rs_art, c, H.artifact_id(free))
      assert {:error, :stream_full} = RecipeStore.pin(rs, c, id, "new")
      assert {:error, :stream_full} = RecipeStore.unpin(rs, c, id, "p-1")
      assert {:error, :stream_full} = RecipeStore.check(rs, c, id, H.facts())
      assert {:error, :stream_full} = RecipeStore.publish(rs, c, id)

      %{rs: refusing, art: art} = H.build(store, object_store: H.absent_bucket_object_store!())
      late = H.package(name: "late")
      assert {:error, :stream_full} = RecipeStore.put(refusing, c, late)
      assert {:error, :not_found} = Artifact.versions(art, c, H.artifact_id(late["identity"]))
      assert snapshot(store, tenant) == written
      assert revision(store, H.stream(tenant, 2)) == 0

      # A change that appends nothing, and each read, still works.
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "p-1")
      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, id, "never-pinned")
      assert {:ok, ^id} = RecipeStore.put(rs, c, pkg)
      assert {:error, :pinned} = RecipeStore.delete(rs, c, id)

      assert {:ok, [entry(free, %{}), entry(id, %{checked: true, pins: 4_997})]} ==
               RecipeStore.versions(rs, c)

      assert {:ok, nil} = RecipeStore.published(rs, c)
      assert {:ok, ^pkg} = RecipeStore.get(rs, c, id)
      assert snapshot(store, tenant) == written
    end
  end

  # ── 9 ────────────────────────────────────────────────────────────────

  describe "malformed_carry" do
    @tag backend: :memory
    test "a misplaced or malformed carry header is {:log, :malformed} for a read and a change; nothing is written",
         %{store: store} do
      %{rs: rs} = H.build(store)
      carried = &Jason.encode!/1

      cases = [
        {"a recipe_carried record in generation 1",
         [{1, "recipe_carried", carried.(header(0, 0))}]},
        {"recipe_carried as record 2 of a complete generation 2",
         [
           {2, "recipe_carried", carried.(header(1, 1))},
           {2, "recipe_carried", carried.(header(1, 0))}
         ]},
        {"generation 2 begins with another kind", [{2, "stored"}]},
        {"from 0", [{2, "recipe_carried", carried.(header(0, 1))}, {2, "stored"}]},
        {"from 2", [{2, "recipe_carried", carried.(header(2, 1))}, {2, "stored"}]},
        {"records -1", [{2, "recipe_carried", carried.(header(1, -1))}, {2, "stored"}]},
        {"records 1.5", [{2, "recipe_carried", carried.(header(1, 1.5))}, {2, "stored"}]},
        {"records absent",
         [{2, "recipe_carried", carried.(%{"from" => 1, "v" => 1})}, {2, "stored"}]}
      ]

      for {name, writes} <- cases do
        tenant = H.tenant()
        c = H.caller(tenant)
        id = put!(rs, c, H.package())

        for write <- writes do
          case write do
            {g, "stored"} -> :ok = H.append!(store, H.stream(tenant, g), "recipe_stored", [j(id)])
            {g, kind, payload} -> :ok = H.append!(store, H.stream(tenant, g), kind, [payload])
          end
        end

        written = snapshot(store, tenant)
        assert {:error, {:log, :malformed}} = RecipeStore.versions(rs, c), name
        assert {:error, {:log, :malformed}} = RecipeStore.published(rs, c), name
        assert {:error, {:log, :malformed}} = RecipeStore.get(rs, c, id), name
        assert {:error, {:log, :malformed}} = RecipeStore.pin(rs, c, id, "run-1"), name
        assert {:error, {:log, :malformed}} = RecipeStore.delete(rs, c, id), name
        assert snapshot(store, tenant) == written, name
      end
    end
  end
end
