# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/recipe_store_test_helper.exs", __DIR__)

defmodule Elzoo.RecipeStoreTest do
  @moduledoc """
  The ten named groups of `state/recipe-store` (ELZ-171). Each scenario runs on
  the Memory Store and on the ready PostgreSQL Store (`ELZOO_TEST_DATABASE_URL`,
  a schema of its own for each test) over the disposable S3 test server
  (`ELZOO_TEST_S3_*`). A missing service fails the run: nothing is skipped.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Elzoo.RecipeStore.DualCase

  alias Elzoo.{Artifact, RecipeStore}
  alias Elzoo.RecipeStore.TestHelper, as: H
  alias Elzoo.RecipeStore.TestRepo

  @moduletag backend: :memory

  setup_all do
    {:ok, repo} = TestRepo.start_link(url: H.url!())
    Process.unlink(repo)
    # The module that started the Repo stops it: an idle pool must not outlive its module.
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
    %{store: store, tenant: tenant, c: H.caller(tenant), stream: H.stream(tenant)}
  end

  defp put!(rs, c, package) do
    {:ok, identity} = RecipeStore.put(rs, c, package)
    identity
  end

  defp pass!(rs, c, identity) do
    {:ok, %{identity: ^identity}} = RecipeStore.check(rs, c, identity, H.facts())
    identity
  end

  defp checked!(rs, c, package), do: put!(rs, c, package) |> then(&pass!(rs, c, &1))

  defp kind_count(store, stream, kind), do: length(H.kinds(store, stream, kind))

  defp artifact_versions(art, c, identity),
    do: Artifact.versions(art, c, H.artifact_id(identity))

  defp tenant_append?(s, records, kind),
    do: H.tenant_stream?(s) and Enum.any?(records, &(&1.kind == kind))

  # Records, for each append to an artifact stream, whether it deletes a
  # version and whether the tenant stream held the mark then.
  defp mark_probe(store, stream) do
    {:ok, probe} = Agent.start_link(fn -> %{armed: false, seen: []} end)

    hook = fn s, _expected, records ->
      if H.artifact_stream?(s) do
        deleting = Enum.any?(records, &(&1.kind == "artifact_deleted"))
        marked = Enum.any?(H.rows(store, stream), &match?({"recipe_deleted", _}, &1))
        Agent.update(probe, &%{&1 | seen: [{deleting, marked} | &1.seen]})

        if deleting and Agent.get_and_update(probe, &{&1.armed, %{&1 | armed: false}}),
          do: {:reply, {:rejected, :invalid_revision}},
          else: :pass
      else
        :pass
      end
    end

    {probe, hook}
  end

  # ── 1 ────────────────────────────────────────────────────────────────

  describe "immutable_versions" do
    dual "put then get gives the same map; access expiry and retention are :never",
         %{store: store, c: c, stream: stream} do
      %{rs: rs, art: art} = H.build(store)
      pkg = H.package()
      id = put!(rs, c, pkg)
      assert id == pkg["identity"]
      assert {:ok, ^pkg} = RecipeStore.get(rs, c, id)

      assert {:ok, %{record: %{access_expires_at_unix_ms: :never, retain_until_unix_ms: :never}}} =
               Artifact.get(art, c, H.artifact_id(id), :head)

      assert [%{"identity" => ^id}] = H.kinds(store, stream, "recipe_stored")
    end

    dual "the same package twice gives one version and one stored record",
         %{store: store, c: c, stream: stream} do
      %{rs: rs, art: art} = H.build(store)
      pkg = H.package()
      id = put!(rs, c, pkg)
      assert {:ok, ^id} = RecipeStore.put(rs, c, pkg)
      assert {:ok, [%{version: 1}]} = artifact_versions(art, c, id)
      assert kind_count(store, stream, "recipe_stored") == 1
      assert [{"recipe_stored", _}] = H.rows(store, stream)
    end

    dual "put of a deleted identity is :deleted and adds no artifact version",
         %{store: store, c: c} do
      %{rs: rs, art: art} = H.build(store)
      pkg = H.package()
      id = put!(rs, c, pkg)
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)
      assert {:error, :deleted} = RecipeStore.put(rs, c, pkg)
      assert {:ok, [%{version: 1, state: :deleted}]} = artifact_versions(art, c, id)
    end

    dual "a put whose stored append failed once is completed by a second put",
         %{store: store, c: c, stream: stream} do
      hook = H.refuse_once(fn s, _, recs -> tenant_append?(s, recs, "recipe_stored") end)
      %{rs: rs, art: art} = H.build(store, log_hook: hook)
      pkg = H.package()
      id = pkg["identity"]

      assert {:error, {:log, :invalid_revision}} = RecipeStore.put(rs, c, pkg)
      assert [] = H.rows(store, stream)
      assert {:error, :not_found} = RecipeStore.get(rs, c, id)

      assert {:ok, ^id} = RecipeStore.put(rs, c, pkg)
      assert {:ok, ^pkg} = RecipeStore.get(rs, c, id)
      assert kind_count(store, stream, "recipe_stored") == 1
      assert {:ok, [_, _]} = artifact_versions(art, c, id)
    end

    dual "two concurrent puts of one package give one stored record; get gives the map whatever the artifact versions",
         %{store: store, c: c, stream: stream} do
      hook = H.pause_once(self(), fn s, _, _ -> H.artifact_stream?(s) end)
      %{rs: rs, art: art} = H.build(store, artifact_hook: hook)
      pkg = H.package()
      id = pkg["identity"]

      # The first put read the empty stream and waits before its artifact write.
      first = Task.async(fn -> RecipeStore.put(rs, c, pkg) end)
      assert_receive {:paused, pid}, 10_000
      assert {:ok, ^id} = RecipeStore.put(rs, c, pkg)
      send(pid, :go)
      assert {:ok, ^id} = Task.await(first, 30_000)

      assert kind_count(store, stream, "recipe_stored") == 1
      assert {:ok, ^pkg} = RecipeStore.get(rs, c, id)
      assert {:ok, versions} = artifact_versions(art, c, id)
      assert length(versions) == 2
      assert Enum.all?(versions, &(&1.state == :committed))
    end

    dual "a put that loses against a concurrent delete is :deleted and leaves no committed artifact version",
         %{store: store, c: c, stream: stream} do
      hook = H.pause_once(self(), fn s, _, _ -> H.artifact_stream?(s) end)
      %{rs: rs, art: art} = H.build(store, artifact_hook: hook)
      pkg = H.package()
      id = pkg["identity"]

      first = Task.async(fn -> RecipeStore.put(rs, c, pkg) end)
      assert_receive {:paused, pid}, 10_000
      # Meanwhile the same package is stored and deleted.
      assert {:ok, ^id} = RecipeStore.put(rs, c, pkg)
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)
      send(pid, :go)

      assert {:error, :deleted} = Task.await(first, 30_000)
      assert kind_count(store, stream, "recipe_stored") == 1
      assert {:ok, versions} = artifact_versions(art, c, id)
      assert versions != []
      assert Enum.all?(versions, &(&1.state == :deleted))
      assert {:error, :deleted} = RecipeStore.get(rs, c, id)
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)
    end

    dual "a changed package gives another identity and both stay readable",
         %{store: store, c: c} do
      %{rs: rs} = H.build(store)
      a = H.package()
      b = H.package(version: "2")
      refute a["identity"] == b["identity"]
      ida = put!(rs, c, a)
      idb = put!(rs, c, b)
      assert {:ok, ^a} = RecipeStore.get(rs, c, ida)
      assert {:ok, ^b} = RecipeStore.get(rs, c, idb)
      assert {:ok, [%{identity: ^ida}, %{identity: ^idb}]} = RecipeStore.versions(rs, c)
    end

    dual "a malformed package is :invalid_package and writes nothing",
         %{store: store, c: c, stream: stream} do
      %{rs: rs} = H.build(store)
      good = H.package()

      for bad <- [
            %{},
            "not a map",
            nil,
            Map.put(good, "identity", "recipe-package-v1:sha256:" <> String.duplicate("0", 64)),
            Map.put(good, "extra", 1),
            Map.delete(good, "graph"),
            %{good | "name" => "other-name"}
          ] do
        assert {:error, :invalid_package} = RecipeStore.put(rs, c, bad)
      end

      assert [] = H.rows(store, stream)
    end

    dual "bytes that do not match the identity are :integrity_mismatch",
         %{store: store, c: c} do
      %{rs: rs, art: art} = H.build(store)
      pkg = H.package()
      id = put!(rs, c, pkg)
      aid = H.artifact_id(id)
      input = fn bytes -> %{bytes: bytes, media_type: "application/json"} end

      # A newer artifact version, written around this Piece, holds another package.
      assert {:ok, _} = Artifact.put(art, c, aid, input.(Jason.encode!(H.package(version: "2"))))
      assert {:error, :integrity_mismatch} = RecipeStore.get(rs, c, id)

      assert {:ok, _} = Artifact.put(art, c, aid, input.("not json"))
      assert {:error, :integrity_mismatch} = RecipeStore.get(rs, c, id)
      assert {:error, :integrity_mismatch} = RecipeStore.check(rs, c, id, H.facts())
    end
  end

  # ── 2 ────────────────────────────────────────────────────────────────

  describe "only_checked_is_published" do
    dual "an unchecked, a refused and an unknown version are not published; a passing check publishes",
         %{store: store, c: c, stream: stream} do
      %{rs: rs} = H.build(store)
      id = put!(rs, c, H.package())
      unknown = "recipe-package-v1:sha256:" <> String.duplicate("a", 64)

      assert {:error, :not_checked} = RecipeStore.publish(rs, c, id)
      assert {:error, :not_found} = RecipeStore.publish(rs, c, unknown)

      before = H.rows(store, stream)

      assert {:refused, [%{path: ["permissions", 0], code: :permission_not_granted}]} =
               RecipeStore.check(rs, c, id, H.refusing_facts())

      assert {:error, :invalid_facts} = RecipeStore.check(rs, c, id, %{})
      assert H.rows(store, stream) == before
      assert {:error, :not_checked} = RecipeStore.publish(rs, c, id)
      assert {:ok, [%{checked: false}]} = RecipeStore.versions(rs, c)

      assert {:ok, %{identity: ^id, unit: "token", upper_cost: 42}} =
               RecipeStore.check(rs, c, id, H.facts())

      assert [%{"identity" => ^id, "upper_cost" => 42}] = H.kinds(store, stream, "recipe_checked")
      assert {:ok, [%{checked: true}]} = RecipeStore.versions(rs, c)
      assert {:ok, %{published: ^id, previous: nil}} = RecipeStore.publish(rs, c, id)
      assert {:ok, ^id} = RecipeStore.published(rs, c)
    end

    dual "a recorded pass is not undone by a later refused check", %{store: store, c: c} do
      %{rs: rs} = H.build(store)
      id = checked!(rs, c, H.package())
      assert {:refused, _} = RecipeStore.check(rs, c, id, H.refusing_facts())
      assert {:ok, %{published: ^id}} = RecipeStore.publish(rs, c, id)
    end
  end

  # ── 3 ────────────────────────────────────────────────────────────────

  describe "go_back" do
    dual "publish A, B, A: the pointer and each previous are correct and all stay readable",
         %{store: store, c: c} do
      %{rs: rs} = H.build(store)
      pa = H.package(name: "a")
      pb = H.package(name: "b")
      a = checked!(rs, c, pa)
      b = checked!(rs, c, pb)

      assert {:ok, nil} = RecipeStore.published(rs, c)
      assert {:ok, %{published: ^a, previous: nil}} = RecipeStore.publish(rs, c, a)
      assert {:ok, ^a} = RecipeStore.published(rs, c)
      assert {:ok, %{published: ^b, previous: ^a}} = RecipeStore.publish(rs, c, b)
      assert {:ok, ^b} = RecipeStore.published(rs, c)
      assert {:ok, %{published: ^a, previous: ^b}} = RecipeStore.publish(rs, c, a)
      assert {:ok, ^a} = RecipeStore.published(rs, c)

      assert {:ok, ^pa} = RecipeStore.get(rs, c, a)
      assert {:ok, ^pb} = RecipeStore.get(rs, c, b)
    end

    dual "publishing the published version changes nothing", %{store: store, c: c, stream: stream} do
      %{rs: rs} = H.build(store)
      a = checked!(rs, c, H.package())
      assert {:ok, %{published: ^a, previous: nil}} = RecipeStore.publish(rs, c, a)
      before = H.rows(store, stream)
      assert {:ok, %{published: ^a, previous: ^a}} = RecipeStore.publish(rs, c, a)
      assert H.rows(store, stream) == before
    end
  end

  # ── 4 ────────────────────────────────────────────────────────────────

  describe "two_publishes_one_order" do
    dual "a publish that reads before another publish commits is decided again; the pointer is the later record",
         %{store: store, c: c, stream: stream} do
      hook =
        H.pause_once(self(), fn s, _, recs -> tenant_append?(s, recs, "recipe_published") end)

      %{rs: rs} = H.build(store, log_hook: hook)
      a = checked!(rs, c, H.package(name: "a"))
      b = checked!(rs, c, H.package(name: "b"))

      first = Task.async(fn -> RecipeStore.publish(rs, c, a) end)
      assert_receive {:paused, pid}, 10_000
      assert {:ok, %{published: ^b, previous: nil}} = RecipeStore.publish(rs, c, b)
      send(pid, :go)

      assert {:ok, %{published: ^a, previous: ^b}} = Task.await(first, 30_000)
      assert [%{"identity" => ^b}, %{"identity" => ^a}] = H.kinds(store, stream, "recipe_published")
      assert {:ok, ^a} = RecipeStore.published(rs, c)
    end

    dual "two concurrent publishes are ok or contended, in one order, and the pointer equals the later record",
         %{store: store, c: c, stream: stream} do
      %{rs: rs} = H.build(store)
      a = checked!(rs, c, H.package(name: "a"))
      b = checked!(rs, c, H.package(name: "b"))

      results =
        [a, b]
        |> Enum.map(&Task.async(fn -> RecipeStore.publish(rs, c, &1) end))
        |> Task.await_many(30_000)

      assert Enum.all?(results, &(match?({:ok, _}, &1) or &1 == {:error, :contended}))
      published = H.kinds(store, stream, "recipe_published")
      assert published != []
      assert {:ok, last} = RecipeStore.published(rs, c)
      assert last == List.last(published)["identity"]

      # The result `previous` of each ok follows the order of the records.
      oks = for {:ok, %{published: p, previous: prev}} <- results, do: {p, prev}
      assert length(oks) == length(published)

      assert Enum.sort(Enum.map(oks, &elem(&1, 0))) ==
               Enum.sort(Enum.map(published, & &1["identity"]))
    end

    dual "with a Store that always conflicts the result is :contended after 3 tries",
         %{store: store, c: c} do
      {:ok, state} = Agent.start_link(fn -> %{on: false, appends: 0} end)

      hook = fn s, expected, recs ->
        if H.tenant_stream?(s) and Agent.get(state, & &1.on) and
             Enum.any?(recs, &(&1.kind == "recipe_published")) do
          Agent.update(state, &%{&1 | appends: &1.appends + 1})
          {:reply, {:conflict, %{expected: expected, observed: expected + 1}}}
        else
          :pass
        end
      end

      %{rs: rs} = H.build(store, log_hook: hook)
      a = checked!(rs, c, H.package())
      Agent.update(state, &%{&1 | on: true})

      assert {:error, :contended} = RecipeStore.publish(rs, c, a)
      assert Agent.get(state, & &1.appends) == 3
      assert {:ok, nil} = RecipeStore.published(rs, c)
    end

    dual "an indeterminate append is :indeterminate and is not tried again",
         %{store: store, c: c} do
      {:ok, state} = Agent.start_link(fn -> %{on: false, appends: 0} end)

      hook = fn s, _expected, recs ->
        if H.tenant_stream?(s) and Agent.get(state, & &1.on) and
             Enum.any?(recs, &(&1.kind == "recipe_published")) do
          Agent.update(state, &%{&1 | appends: &1.appends + 1})
          {:reply, {:indeterminate, %{cause: :timeout}}}
        else
          :pass
        end
      end

      %{rs: rs} = H.build(store, log_hook: hook)
      a = checked!(rs, c, H.package())
      Agent.update(state, &%{&1 | on: true})

      assert {:error, :indeterminate} = RecipeStore.publish(rs, c, a)
      assert Agent.get(state, & &1.appends) == 1
    end
  end

  # ── 5 ────────────────────────────────────────────────────────────────

  describe "pinned_is_not_deleted" do
    dual "delete of a pinned version is :pinned; after unpin it succeeds",
         %{store: store, c: c, stream: stream} do
      %{rs: rs, art: art} = H.build(store)
      id = put!(rs, c, H.package())

      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "run-1")
      before = H.rows(store, stream)
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "run-1")
      assert H.rows(store, stream) == before

      assert {:error, :pinned} = RecipeStore.delete(rs, c, id)
      assert {:ok, [%{state: :committed}]} = artifact_versions(art, c, id)
      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, id, "run-1")
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)
    end

    dual "delete of the published version is :published; a pin is reported before it",
         %{store: store, c: c} do
      %{rs: rs} = H.build(store)
      id = checked!(rs, c, H.package())
      assert {:ok, _} = RecipeStore.publish(rs, c, id)
      assert {:error, :published} = RecipeStore.delete(rs, c, id)
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "run-1")
      assert {:error, :pinned} = RecipeStore.delete(rs, c, id)
    end

    dual "two Runs pin one version: it is deletable only after both unpin",
         %{store: store, c: c, stream: stream} do
      %{rs: rs} = H.build(store)
      id = put!(rs, c, H.package())
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "run-1")
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "run-2")
      assert {:ok, [%{pins: 2}]} = RecipeStore.versions(rs, c)

      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, id, "run-1")
      assert {:error, :pinned} = RecipeStore.delete(rs, c, id)

      before = H.rows(store, stream)
      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, id, "run-1")
      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, id, "never-pinned")
      assert H.rows(store, stream) == before

      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, id, "run-2")
      assert {:ok, [%{pins: 0}]} = RecipeStore.versions(rs, c)
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)
    end

    dual "get, pin, check and publish of a deleted version are :deleted; its unpin is ok",
         %{store: store, c: c} do
      %{rs: rs} = H.build(store)
      id = checked!(rs, c, H.package())
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)

      assert {:error, :deleted} = RecipeStore.get(rs, c, id)
      assert {:error, :deleted} = RecipeStore.pin(rs, c, id, "run-1")
      assert {:error, :deleted} = RecipeStore.check(rs, c, id, H.facts())
      assert {:error, :deleted} = RecipeStore.publish(rs, c, id)
      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, id, "run-1")

      assert {:ok, [%{identity: ^id, deleted: true, checked: true, pins: 0}]} =
               RecipeStore.versions(rs, c)
    end

    dual "the refusal order is not_found, deleted, not_checked, pinned, published",
         %{store: store, c: c} do
      %{rs: rs} = H.build(store)
      unchecked = put!(rs, c, H.package(name: "u"))
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, unchecked)
      # deleted before not_checked
      assert {:error, :deleted} = RecipeStore.publish(rs, c, unchecked)
      # pinned before published
      live = checked!(rs, c, H.package(name: "l"))
      assert {:ok, _} = RecipeStore.publish(rs, c, live)
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, live, "run-1")
      assert {:error, :pinned} = RecipeStore.delete(rs, c, live)
      # an unchecked version is deletable
      other = put!(rs, c, H.package(name: "o"))
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, other)
    end
  end

  # ── 6 ────────────────────────────────────────────────────────────────

  describe "pin_and_delete_one_winner" do
    dual "arrival order: the pin commits first, the delete is :pinned",
         %{store: store, c: c} do
      hook = H.pause_once(self(), fn s, _, recs -> tenant_append?(s, recs, "recipe_deleted") end)
      %{rs: rs, art: art} = H.build(store, log_hook: hook)
      id = put!(rs, c, H.package())

      # The delete reads the version unpinned and waits before its append.
      del = Task.async(fn -> RecipeStore.delete(rs, c, id) end)
      assert_receive {:paused, pid}, 10_000
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "run-1")
      send(pid, :go)

      assert {:error, :pinned} = Task.await(del, 30_000)
      assert {:ok, [%{pins: 1, deleted: false}]} = RecipeStore.versions(rs, c)
      assert {:ok, _} = RecipeStore.get(rs, c, id)
      assert {:ok, [%{state: :committed}]} = artifact_versions(art, c, id)
    end

    dual "arrival order: the delete commits first, the pin is :deleted",
         %{store: store, c: c} do
      hook = H.pause_once(self(), fn s, _, recs -> tenant_append?(s, recs, "recipe_pinned") end)
      %{rs: rs, art: art} = H.build(store, log_hook: hook)
      id = put!(rs, c, H.package())

      pin = Task.async(fn -> RecipeStore.pin(rs, c, id, "run-1") end)
      assert_receive {:paused, pid}, 10_000
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)
      send(pid, :go)

      assert {:error, :deleted} = Task.await(pin, 30_000)
      assert {:ok, [%{pins: 0, deleted: true}]} = RecipeStore.versions(rs, c)
      assert {:error, :deleted} = RecipeStore.get(rs, c, id)
      assert {:ok, [%{state: :deleted}]} = artifact_versions(art, c, id)
    end

    dual "20 concurrent rounds: exactly one of pin and delete succeeds and the state agrees",
         %{store: store, c: c} do
      %{rs: rs, art: art} = H.build(store)

      outcomes =
        for round <- 1..20 do
          id = put!(rs, c, H.package(name: "round-#{round}"))

          [pin, del] =
            [
              Task.async(fn -> RecipeStore.pin(rs, c, id, "run-1") end),
              Task.async(fn -> RecipeStore.delete(rs, c, id) end)
            ]
            |> Task.await_many(30_000)

          {:ok, versions} = RecipeStore.versions(rs, c)
          entry = Enum.find(versions, &(&1.identity == id))

          case {pin, del} do
            {{:ok, :pinned}, {:error, :pinned}} ->
              assert %{pins: 1, deleted: false} = entry
              assert {:ok, _} = RecipeStore.get(rs, c, id)
              assert {:ok, [%{state: :committed}]} = artifact_versions(art, c, id)
              :pin

            {{:error, :deleted}, {:ok, :deleted}} ->
              assert %{pins: 0, deleted: true} = entry
              assert {:error, :deleted} = RecipeStore.get(rs, c, id)
              assert {:ok, [%{state: :deleted}]} = artifact_versions(art, c, id)
              :delete

            other ->
              flunk("not exactly one winner in round #{round}: #{inspect(other)}")
          end
        end

      assert length(outcomes) == 20
    end
  end

  # ── 7 ────────────────────────────────────────────────────────────────

  describe "delete_mark_before_artifact" do
    dual "a refused artifact append leaves the mark; the version reads :deleted; a second delete completes",
         %{store: store, c: c, stream: stream} do
      {probe, hook} = mark_probe(store, stream)
      %{rs: rs, art: art} = H.build(store, artifact_hook: hook)
      id = put!(rs, c, H.package())
      Agent.update(probe, &%{&1 | armed: true})

      assert {:error, {:delete_incomplete, {:commit_failed, %{rejected: :invalid_revision}}}} =
               RecipeStore.delete(rs, c, id)

      assert [%{"identity" => ^id}] = H.kinds(store, stream, "recipe_deleted")
      assert {:ok, [%{identity: ^id, deleted: true}]} = RecipeStore.versions(rs, c)
      assert {:error, :deleted} = RecipeStore.get(rs, c, id)
      assert {:ok, [%{state: :committed}]} = artifact_versions(art, c, id)

      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)
      assert {:ok, [%{state: :deleted}]} = artifact_versions(art, c, id)
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)
      assert length(H.kinds(store, stream, "recipe_deleted")) == 1

      deletes = for {true, marked} <- Agent.get(probe, & &1.seen), do: marked
      assert deletes != [] and Enum.all?(deletes, & &1)
    end

    dual "a recipe artifact with two versions has none committed after one delete",
         %{store: store, c: c, stream: stream} do
      {probe, art_hook} = mark_probe(store, stream)
      log_hook = H.refuse_once(fn s, _, recs -> tenant_append?(s, recs, "recipe_stored") end)
      %{rs: rs, art: art} = H.build(store, artifact_hook: art_hook, log_hook: log_hook)
      pkg = H.package()
      id = pkg["identity"]

      assert {:error, {:log, :invalid_revision}} = RecipeStore.put(rs, c, pkg)
      assert {:ok, ^id} = RecipeStore.put(rs, c, pkg)
      assert {:ok, [%{state: :committed}, %{state: :committed}]} = artifact_versions(art, c, id)

      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)
      assert {:ok, [%{state: :deleted}, %{state: :deleted}]} = artifact_versions(art, c, id)

      deletes = for {true, marked} <- Agent.get(probe, & &1.seen), do: marked
      assert length(deletes) == 2 and Enum.all?(deletes, & &1)
    end

    dual "a pinned or published version has no artifact record deleted and no mark",
         %{store: store, c: c, stream: stream} do
      {probe, hook} = mark_probe(store, stream)
      %{rs: rs, art: art} = H.build(store, artifact_hook: hook)
      id = checked!(rs, c, H.package())
      assert {:ok, _} = RecipeStore.publish(rs, c, id)
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "run-1")
      assert {:error, :pinned} = RecipeStore.delete(rs, c, id)
      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, id, "run-1")
      assert {:error, :published} = RecipeStore.delete(rs, c, id)

      assert [] = H.kinds(store, stream, "recipe_deleted")
      assert [] = for({true, _} = seen <- Agent.get(probe, & &1.seen), do: seen)
      assert {:ok, [%{state: :committed}]} = artifact_versions(art, c, id)
    end
  end

  # ── 8 ────────────────────────────────────────────────────────────────

  describe "reap_keeps_recipes" do
    dual "Artifact.reap with the clock far in the future removes no version",
         %{store: store, c: c} do
      log_hook = H.refuse_once(fn s, _, recs -> tenant_append?(s, recs, "recipe_stored") end)
      %{rs: rs, art: art} = H.build(store, log_hook: log_hook)
      pkg = H.package()
      id = pkg["identity"]
      assert {:error, {:log, _}} = RecipeStore.put(rs, c, pkg)
      assert {:ok, ^id} = RecipeStore.put(rs, c, pkg)

      far = %{art | clock: fn -> 4_000_000_000_000 end}
      assert {:ok, %{reaped: []}} = Artifact.reap(far, c, H.artifact_id(id))
      assert {:ok, [%{state: :committed}, %{state: :committed}]} = artifact_versions(art, c, id)
      assert {:ok, ^pkg} = RecipeStore.get(rs, c, id)
    end
  end

  # ── 9 ────────────────────────────────────────────────────────────────

  describe "tenant_isolation" do
    dual "another tenant sees none of a tenant's versions and changes nothing",
         %{store: store, c: c, stream: stream} do
      %{rs: rs} = H.build(store)
      other = H.caller(H.tenant(), principal: "someone-else")

      # tenant A: stored, checked, pinned, published and deleted versions
      stored = put!(rs, c, H.package(name: "stored"))
      checked = checked!(rs, c, H.package(name: "checked"))
      pinned = put!(rs, c, H.package(name: "pinned"))
      published = checked!(rs, c, H.package(name: "published"))
      deleted = put!(rs, c, H.package(name: "deleted"))
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, pinned, "run-1")
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, pinned, "run-2")
      assert {:ok, %{previous: nil}} = RecipeStore.publish(rs, c, published)
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, deleted)

      before = H.rows(store, stream)

      for id <- [stored, checked, pinned, published, deleted] do
        assert {:error, :not_found} = RecipeStore.get(rs, other, id)
        assert {:error, :not_found} = RecipeStore.check(rs, other, id, H.facts())
        assert {:error, :not_found} = RecipeStore.publish(rs, other, id)
        assert {:error, :not_found} = RecipeStore.pin(rs, other, id, "run-1")
        assert {:error, :not_found} = RecipeStore.delete(rs, other, id)
        assert {:ok, :unpinned} = RecipeStore.unpin(rs, other, id, "run-1")
      end

      assert {:ok, []} = RecipeStore.versions(rs, other)
      assert {:ok, nil} = RecipeStore.published(rs, other)
      assert [] = H.rows(store, H.stream(other.tenant))

      assert H.rows(store, stream) == before
      assert {:ok, ^published} = RecipeStore.published(rs, c)

      assert {:ok,
              [
                %{identity: ^stored, checked: false, pins: 0, published: false, deleted: false},
                %{identity: ^checked, checked: true, pins: 0, published: false, deleted: false},
                %{identity: ^pinned, checked: false, pins: 2, published: false, deleted: false},
                %{identity: ^published, checked: true, pins: 0, published: true, deleted: false},
                %{identity: ^deleted, checked: false, pins: 0, published: false, deleted: true}
              ]} = RecipeStore.versions(rs, c)
    end

    dual "two tenants may store the same package", %{store: store, c: c} do
      %{rs: rs} = H.build(store)
      other = H.caller(H.tenant())
      pkg = H.package()
      id = put!(rs, c, pkg)
      assert {:ok, ^id} = RecipeStore.put(rs, other, pkg)
      assert {:ok, :deleted} = RecipeStore.delete(rs, c, id)
      assert {:ok, ^pkg} = RecipeStore.get(rs, other, id)
      assert {:error, :deleted} = RecipeStore.get(rs, c, id)
    end
  end

  # ── 10 ───────────────────────────────────────────────────────────────

  describe "bounds_and_redaction" do
    @tag backend: :memory
    test "a tenant stream of 10,000 records refuses each change that appends with :stream_full",
         %{store: store, c: c, stream: stream} do
      %{rs: rs, art: art} = H.build(store)
      id = checked!(rs, c, H.package())

      filler =
        for n <- 1..9_996,
            do: Jason.encode!(%{"v" => 1, "identity" => id, "run_id" => "filler-#{n}"})

      for chunk <- Enum.chunk_every(filler, 500),
          do: :ok = H.append!(store, stream, "recipe_unpinned", chunk)

      assert {:ok, %{published: ^id}} = RecipeStore.publish(rs, c, id)
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "run-1")
      assert {:ok, head} = Elzoo.DurableLog.Store.read(store, :head, [stream])
      assert head.revision == 10_000

      other = H.package(name: "late")
      assert {:error, :stream_full} = RecipeStore.pin(rs, c, id, "run-2")
      assert {:error, :stream_full} = RecipeStore.unpin(rs, c, id, "run-1")
      assert {:error, :stream_full} = RecipeStore.check(rs, c, id, H.facts())
      assert {:error, :stream_full} = RecipeStore.put(rs, c, other)
      # nothing was written for the refused put
      assert {:error, :not_found} = artifact_versions(art, c, other["identity"])

      # a call that appends nothing, and each read, still works
      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, "run-1")
      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, id, "never-pinned")
      assert {:ok, %{previous: ^id}} = RecipeStore.publish(rs, c, id)
      assert {:ok, ^id} = RecipeStore.put(rs, c, H.package())
      assert {:ok, [%{identity: ^id, pins: 1, published: true}]} = RecipeStore.versions(rs, c)
      assert {:ok, ^id} = RecipeStore.published(rs, c)
      assert {:error, :pinned} = RecipeStore.delete(rs, c, id)
      assert {:ok, _} = RecipeStore.get(rs, c, id)
    end

    dual "a Run ID is 1 to 128 bytes and each malformed operand is {:invalid, field}",
         %{store: store, c: c} do
      %{rs: rs} = H.build(store)
      id = put!(rs, c, H.package())
      long = String.duplicate("r", 128)

      assert {:ok, :pinned} = RecipeStore.pin(rs, c, id, long)
      assert {:ok, :unpinned} = RecipeStore.unpin(rs, c, id, long)

      for run <- ["", long <> "r", String.duplicate("é", 65), <<255>>, "a\0b", nil, 1, :run] do
        assert {:error, {:invalid, :run_id}} = RecipeStore.pin(rs, c, id, run)
        assert {:error, {:invalid, :run_id}} = RecipeStore.unpin(rs, c, id, run)
      end

      bad_ids = [
        "",
        nil,
        :id,
        "recipe-package-v1:sha256:" <> String.duplicate("A", 64),
        "recipe-package-v1:sha256:" <> String.duplicate("a", 63),
        "recipe-package-v1:sha256:" <> String.duplicate("a", 64) <> "\n",
        String.duplicate("a", 64)
      ]

      for bad <- bad_ids do
        assert {:error, {:invalid, :identity}} = RecipeStore.get(rs, c, bad)
        assert {:error, {:invalid, :identity}} = RecipeStore.check(rs, c, bad, H.facts())
        assert {:error, {:invalid, :identity}} = RecipeStore.publish(rs, c, bad)
        assert {:error, {:invalid, :identity}} = RecipeStore.pin(rs, c, bad, "run-1")
        assert {:error, {:invalid, :identity}} = RecipeStore.unpin(rs, c, bad, "run-1")
        assert {:error, {:invalid, :identity}} = RecipeStore.delete(rs, c, bad)
      end

      bad_callers = [
        nil,
        %{},
        %{c | tenant: ""},
        %{c | tenant: String.duplicate("t", 65)},
        %{c | tenant: "a/b"},
        %{c | tenant: ".."},
        %{c | tenant: :atom},
        %{c | principal: 1},
        %{c | scopes: "scope"},
        %{c | scopes: [1]}
      ]

      for bad <- bad_callers do
        assert {:error, {:invalid, :caller}} = RecipeStore.put(rs, bad, H.package())
        assert {:error, {:invalid, :caller}} = RecipeStore.get(rs, bad, id)
        assert {:error, {:invalid, :caller}} = RecipeStore.check(rs, bad, id, H.facts())
        assert {:error, {:invalid, :caller}} = RecipeStore.publish(rs, bad, id)
        assert {:error, {:invalid, :caller}} = RecipeStore.published(rs, bad)
        assert {:error, {:invalid, :caller}} = RecipeStore.pin(rs, bad, id, "run-1")
        assert {:error, {:invalid, :caller}} = RecipeStore.unpin(rs, bad, id, "run-1")
        assert {:error, {:invalid, :caller}} = RecipeStore.delete(rs, bad, id)
        assert {:error, {:invalid, :caller}} = RecipeStore.versions(rs, bad)
      end

      for bad <- [nil, %{}, {:store, 1}] do
        assert {:error, {:invalid, :store}} = RecipeStore.put(bad, c, H.package())
        assert {:error, {:invalid, :store}} = RecipeStore.versions(bad, c)
      end
    end

    dual "new/1 takes exactly an artifact handle and a ready Store with the kinds",
         %{store: store} do
      %{rs: rs, art: art} = H.build(store)
      assert %RecipeStore{} = rs

      assert Map.keys(RecipeStore.kinds()) |> Enum.sort() ==
               ~w(recipe_checked recipe_deleted recipe_pinned recipe_published recipe_stored recipe_unpinned)

      assert Enum.all?(Map.values(RecipeStore.kinds()), &(&1 == :non_state_bearing))
      assert {:error, {:invalid, :opts}} = RecipeStore.new([])
      assert {:error, {:invalid, :opts}} = RecipeStore.new(artifact: art)
      assert {:error, {:invalid, :opts}} = RecipeStore.new(artifact: art, log: store, extra: 1)
      assert {:error, {:invalid, :opts}} = RecipeStore.new(%{artifact: art, log: store})
      assert {:error, {:invalid, :artifact}} = RecipeStore.new(artifact: :art, log: store)
      assert {:error, {:invalid, :log}} = RecipeStore.new(artifact: art, log: :store)

      assert {:error, {:invalid, :log}} =
               RecipeStore.new(artifact: art, log: {Elzoo.DurableLog.Memory, %{}})

      assert {:error, {:invalid, :log}} =
               RecipeStore.new(artifact: art, log: {Elzoo.DurableLog.Memory, [1, 2]})

      # a Store whose fold lacks the kinds of this Piece
      {module, opts} = store
      bare = update_in(opts, [:fold, :kinds], &Map.drop(&1, Map.keys(RecipeStore.kinds())))
      assert {:error, {:invalid, :log}} = RecipeStore.new(artifact: art, log: {module, bare})
      # a Store whose fold lacks schema version 1
      no_version = put_in(opts, [:fold, :versions], [2])
      assert {:error, {:invalid, :log}} = RecipeStore.new(artifact: art, log: {module, no_version})
    end

    dual "a sentinel text in a package never appears in an error, a log or a telemetry event",
         %{store: store, c: c} do
      sentinel = "SENTINEL-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      pkg = H.package(skills: [H.skill(sentinel)])
      id = pkg["identity"]
      handler = "recipe-store-redaction-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler,
          Artifact.Telemetry.events(),
          &__MODULE__.forward/4,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      log =
        capture_log(fn ->
          %{rs: rs} = H.build(store)
          small = H.build(store, max_bytes: 10).rs

          results = [
            RecipeStore.put(small, c, pkg),
            RecipeStore.put(rs, c, Map.put(pkg, "extra", sentinel)),
            RecipeStore.put(rs, c, put_in(pkg, ["skills", Access.at(0), "body"], sentinel <> "x")),
            RecipeStore.put(rs, c, pkg),
            RecipeStore.check(rs, c, id, H.refusing_facts()),
            RecipeStore.check(rs, c, id, %{sentinel => sentinel}),
            RecipeStore.check(rs, c, id, H.facts()),
            RecipeStore.pin(rs, c, id, "run-1"),
            RecipeStore.delete(rs, c, id),
            RecipeStore.unpin(rs, c, id, "run-1"),
            RecipeStore.delete(rs, c, id),
            RecipeStore.get(rs, c, id),
            RecipeStore.pin(rs, c, id, "run-1"),
            RecipeStore.versions(rs, c)
          ]

          assert [
                   {:error, {:artifact, :too_large}},
                   {:error, :invalid_package},
                   {:error, :invalid_package},
                   {:ok, ^id},
                   {:refused, _},
                   {:error, :invalid_facts},
                   {:ok, _},
                   {:ok, :pinned},
                   {:error, :pinned},
                   {:ok, :unpinned},
                   {:ok, :deleted},
                   {:error, :deleted},
                   {:error, :deleted},
                   {:ok, _}
                 ] = results

          refute inspect(results, limit: :infinity, printable_limit: :infinity) =~ sentinel

          # a failing Store read and a failing append carry no package content either
          failing = fn _s, _e, _r -> {:reply, {:rejected, :record_too_large}} end
          %{rs: failing_rs} = H.build(store, log_hook: failing)

          refused =
            RecipeStore.put(failing_rs, c, H.package(skills: [H.skill(sentinel)], name: "other"))

          assert {:error, {:log, :record_too_large}} = refused
          refute inspect(refused) =~ sentinel
        end)

      refute log =~ sentinel
      events = for {:telemetry, _, _, _} = event <- flush_telemetry(), do: event
      assert events != []
      refute inspect(events, limit: :infinity, printable_limit: :infinity) =~ sentinel
    end

    test "the checked example runs on the Memory Store", %{store: _} do
      path = Path.expand("../../examples/recipe_store.exs", __DIR__)

      {result, _} =
        Code.eval_string(File.read!(path), [object_store: H.object_store!()], file: path)

      assert result == :ok
    end
  end

  def forward(event, measurements, metadata, test_pid),
    do: send(test_pid, {:telemetry, event, measurements, metadata})

  defp flush_telemetry(acc \\ []) do
    receive do
      {:telemetry, _, _, _} = event -> flush_telemetry([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
