# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/artifact_test_helper.exs", __DIR__)

defmodule Elzoo.ArtifactTest do
  @moduledoc """
  `state/artifact` scenarios on the volatile Memory Store double and the
  disposable MinIO object store (`ELZOO_TEST_S3_*`, fail closed) plus loopback
  stubs for outcomes a real server cannot produce on demand. Finite named
  scenarios, not proofs.
  """
  use ExUnit.Case, async: false

  alias Elzoo.Artifact
  alias Elzoo.Artifact.{Record, TestClock}
  alias Elzoo.Artifact.TestHelper, as: H
  alias Elzoo.Artifact.TestHelper, as: S3

  @cure :"Cure.Elzoo.Artifact"
  @source File.read!(Path.expand("../../cure/elzoo/artifact.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
  @laws ~w(absent_principal_denies missing_scope_denies terms_passed_then_expiry
           live_before_permits expired_at_refuses expired_after_refuses
           staged_commit_commits staged_abort_deletes staged_delete_refuses staged_reap_deletes
           committed_commit_stays committed_delete_deletes committed_reap_deletes
           committed_abort_refuses deleted_refuses)

  defp law_line(law) do
    @source
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, "fn #{law}("))
    |> Kernel.+(1)
  end

  defp s3?, do: S3.s3?()

  defp memory(opts \\ []) do
    object_store =
      Keyword.get_lazy(opts, :object_store, fn ->
        if s3?(), do: S3.config!(), else: S3.stub_config(S3.closed_port())
      end)

    H.memory(Keyword.put(opts, :object_store, object_store))
  end

  defp caller(tenant, opts \\ []), do: H.caller(tenant, opts)

  defp id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # ── construction and validation ─────────────────────────────────────

  test "A1 construction validates bindings and bounds" do
    assert {:error, {:invalid, :store}} =
             Artifact.new(store: nil, object_store: S3.stub_config(S3.closed_port()))

    m = H.memory(object_store: S3.stub_config(S3.closed_port()))
    assert {:error, {:invalid, :object_store}} = Artifact.new(store: m.store, object_store: nil)

    assert {:error, {:invalid, :max_metadata_bytes}} =
             Artifact.new(
               store: m.store,
               object_store: S3.stub_config(S3.closed_port()),
               max_metadata_bytes: 0
             )

    assert {:error, {:invalid, :hash_format}} =
             Artifact.new(
               store: m.store,
               object_store: S3.stub_config(S3.closed_port()),
               hash_format: 0
             )

    assert {:error, {:invalid, :staging_ttl_ms}} =
             Artifact.new(
               store: m.store,
               object_store: S3.stub_config(S3.closed_port()),
               staging_ttl_ms: 0
             )
  end

  test "A2 every entry point refuses malformed callers and subjects before effects" do
    {m, fake} = fake_memory()
    art = %{m.art | store: {Elzoo.Artifact.EffectGuard, self()}}
    c = caller("t1")

    for bad <- [
          nil,
          %{},
          Map.delete(c, :principal),
          Map.delete(c, :scopes),
          %{c | principal: nil},
          %{c | scopes: nil},
          %{c | scopes: [nil]}
        ] do
      assert_invalid_subject(art, bad, "a1", 1)
      assert {:error, :invalid} = Artifact.list(art, bad, 10, nil)
    end

    for bad <- [nil, 1, "a/b", "..", ".", "a b", "", "x" <> String.duplicate("y", 65)] do
      assert_invalid_subject(art, c, bad, 1)
      assert_invalid_subject(art, %{c | tenant: bad}, "a1", 1)
      assert {:error, :invalid} = Artifact.list(art, %{c | tenant: bad}, 10, nil)
    end

    for bad <- [nil, 0, -1, 1.0, "1", %{}] do
      assert {:error, :invalid} = Artifact.commit(art, c, "a1", bad)
      assert {:error, :invalid} = Artifact.get(art, c, "a1", bad)
      assert {:error, :invalid} = Artifact.delete(art, c, "a1", bad)
      assert {:error, :invalid} = Artifact.abort(art, c, %{artifact_id: "a1", version: bad})
      assert {:error, :invalid} = Artifact.status(art, c, %{artifact_id: "a1", version: bad})
    end

    for bad <- [nil, %{}, %{artifact_id: "a1"}, %{version: 1}] do
      assert {:error, :invalid} = Artifact.abort(art, c, bad)
      assert {:error, :invalid} = Artifact.status(art, c, bad)
    end

    assert {:error, :invalid} = Artifact.stage(art, c, "a1", nil)
    assert {:error, :invalid} = Artifact.put(art, c, "a1", nil)
    assert {:error, :invalid} = Artifact.list(art, c, 0, nil)
    assert {:error, :invalid} = Artifact.list(art, c, 10, -1)
    refute_received :artifact_store_effect
    assert H.fake_requests(fake) == []
  end

  defp assert_invalid_subject(art, c, aid, version) do
    results = [
      Artifact.stage(art, c, aid, H.input("b")),
      Artifact.put(art, c, aid, H.input("b")),
      Artifact.new_version(art, c, aid, H.input("b")),
      Artifact.head(art, c, aid),
      Artifact.versions(art, c, aid),
      Artifact.reap(art, c, aid),
      Artifact.commit(art, c, aid, version),
      Artifact.get(art, c, aid, version),
      Artifact.delete(art, c, aid, version),
      Artifact.abort(art, c, %{artifact_id: aid, version: version}),
      Artifact.status(art, c, %{artifact_id: aid, version: version})
    ]

    assert Enum.all?(results, &(&1 == {:error, :invalid})), inspect(results)
  end

  test "A3 too_large and metadata bound" do
    %{art: art} = memory(max_bytes: 4)
    assert {:error, :too_large} = Artifact.stage(art, caller("t1"), "a1", H.input("12345"))

    assert {:error, :too_large} =
             Artifact.stage(
               art,
               caller("t1"),
               "a1",
               H.input("1234", metadata: %{"k" => String.duplicate("v", 600)})
             )
  end

  # ── lifecycle against MinIO ──────────────────────────────────────────

  test "L1 put/head/get/versions roundtrip" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art} = memory()
    c = caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, rec} = Artifact.put(art, c, aid, H.input("hello"))
    assert rec.version == 1 and rec.state == :committed
    assert {:ok, rec} = Artifact.head(art, c, aid)
    assert rec.sha256 == Record.content_hash(1, "hello")
    assert {:ok, %{bytes: "hello", record: ^rec}} = Artifact.get(art, c, aid, :head)
    assert {:ok, [%{version: 1}]} = Artifact.versions(art, c, aid)
  end

  test "L2 new_version increments and head follows" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art} = memory()
    c = caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, %{version: 1}} = Artifact.put(art, c, aid, H.input("one"))
    assert {:ok, %{version: 2}} = Artifact.new_version(art, c, aid, H.input("two"))
    assert {:ok, %{version: 2}} = Artifact.head(art, c, aid)
    assert {:ok, %{bytes: "one"}} = Artifact.get(art, c, aid, 1)
    assert {:ok, [%{version: 1}, %{version: 2}]} = Artifact.versions(art, c, aid)
    assert {:error, :not_found} = Artifact.new_version(art, c, id("missing"), H.input("x"))
  end

  test "L3 cross-tenant lookup is :not_found, never :access_denied" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art} = memory()
    a = caller("ta-#{id("t")}")
    b = caller("tb-#{id("t")}")
    aid = id("art")

    assert {:ok, _} = Artifact.put(art, a, aid, H.input("data"))
    assert {:error, :not_found} = Artifact.head(art, b, aid)
    assert {:error, :not_found} = Artifact.get(art, b, aid, 1)
    assert {:error, :not_found} = Artifact.versions(art, b, aid)
    assert {:error, :not_found} = Artifact.status(art, b, %{artifact_id: aid, version: 1})
  end

  test "L4 recorded access terms deny principal and scope; a hash never grants access" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art} = memory()
    c = caller("t-#{id("t")}")
    aid = id("art")
    access = %{tenant: c.tenant, principals: ["alice"], scopes: ["read"]}

    assert {:ok, _} = Artifact.put(art, c, aid, H.input("data", access: access))

    assert {:error, :access_denied} =
             Artifact.head(art, caller(c.tenant, principal: "bob", scopes: ["read"]), aid)

    assert {:error, :access_denied} =
             Artifact.head(art, caller(c.tenant, principal: "alice", scopes: []), aid)

    assert {:error, :access_denied} =
             Artifact.status(art, c, %{artifact_id: aid, version: 1})

    # Knowing the content hash does not help the denied caller.
    assert {:error, :access_denied} =
             Artifact.get(art, caller(c.tenant, principal: "bob", scopes: ["read"]), aid, 1)

    assert {:ok, %{version: 1}} =
             Artifact.head(art, caller(c.tenant, principal: "alice", scopes: ["read"]), aid)
  end

  test "L5 expired access is :expired on every read path" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art, clock: clock} = memory()
    c = caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, _} =
             Artifact.put(
               art,
               c,
               aid,
               H.input("data", access_expires_at_unix_ms: H.epoch() + 1_000)
             )

    TestClock.advance(clock, 2_000)
    assert {:error, :expired} = Artifact.head(art, c, aid)
    assert {:error, :expired} = Artifact.get(art, c, aid, 1)
    assert {:error, :expired} = Artifact.versions(art, c, aid)
    assert {:error, :expired} = Artifact.delete(art, c, aid, 1)
    assert {:error, :expired} = Artifact.status(art, c, %{artifact_id: aid, version: 1})
    assert {:ok, %{entries: []}} = Artifact.list(art, c, 10, nil)
  end

  test "L6 tampered bytes are an integrity_mismatch, never served" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art, object_store: os} = memory()
    c = caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, rec} = Artifact.put(art, c, aid, H.input("good"))
    assert %{status: :committed} = Elzoo.ObjectStore.put(os, rec.object_key, "evil")

    assert {:error, {:integrity_mismatch, %{expected: expected}}} = Artifact.get(art, c, aid, 1)
    assert expected == rec.sha256
  end

  test "L7 commit refuses absent object evidence" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art, object_store: os} = memory()
    c = caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, rec} = Artifact.stage(art, c, aid, H.input("data"))
    assert %{status: :committed} = Elzoo.ObjectStore.delete(os, rec.object_key)
    assert {:error, {:commit_failed, %{evidence: :absent}}} = Artifact.commit(art, c, aid, 1)

    assert {:ok, %{record: %{state: :staging}}} =
             Artifact.status(art, c, %{artifact_id: aid, version: 1})
  end

  test "L8 unknown put persists uncertain staging; status exposes it; no blind re-put" do
    {port, _ref} = S3.stub(:silent)
    %{art: art} = memory(object_store: S3.stub_config(port, default_deadline_ms: 300))
    c = caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, rec} = Artifact.stage(art, c, aid, H.input("data"))
    assert rec.upload == :uncertain and rec.state == :staging

    assert {:ok, %{record: %{upload: :uncertain}, object: {:unknown, _}}} =
             Artifact.status(art, c, %{artifact_id: aid, version: 1})

    assert {:error, {:object_store_unknown, _}} = Artifact.commit(art, c, aid, 1)
  end

  test "L9 staging past its ttl is :staging_expired" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art, clock: clock} = memory(staging_ttl_ms: 1_000)
    c = caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, _} = Artifact.stage(art, c, aid, H.input("data"))
    TestClock.advance(clock, 1_500)
    assert {:error, :staging_expired} = Artifact.commit(art, c, aid, 1)
  end

  test "L10 abort deletes the record and best-effort the bytes" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art, object_store: os} = memory()
    c = caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, rec} = Artifact.stage(art, c, aid, H.input("data"))

    assert {:ok, %{record: %{state: :deleted}, object: :deleted}} =
             Artifact.abort(art, c, %{artifact_id: aid, version: 1})

    assert %{status: :absent} = Elzoo.ObjectStore.head(os, rec.object_key)
    assert {:error, :deleted} = Artifact.abort(art, c, %{artifact_id: aid, version: 1})
  end

  test "L11 delete and reap honor retention" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art, clock: clock, object_store: os} = memory()
    c = caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, rec} =
             Artifact.put(art, c, aid, H.input("data", retain_until_unix_ms: H.epoch() + 1_000))

    assert {:error, {:invalid, :state}} = Artifact.abort(art, c, %{artifact_id: aid, version: 1})
    assert {:ok, %{object: :deleted}} = Artifact.delete(art, c, aid, 1)
    assert %{status: :absent} = Elzoo.ObjectStore.head(os, rec.object_key)
    assert {:error, :deleted} = Artifact.get(art, c, aid, 1)
    assert {:error, :deleted} = Artifact.delete(art, c, aid, 1)

    # retention expiry: committed record reaped
    aid2 = id("art")

    assert {:ok, rec2} =
             Artifact.put(art, c, aid2, H.input("data2", retain_until_unix_ms: H.epoch() + 1_000))

    TestClock.advance(clock, 2_000)
    assert {:ok, %{reaped: [1], object: %{1 => :deleted}}} = Artifact.reap(art, c, aid2)
    assert %{status: :absent} = Elzoo.ObjectStore.head(os, rec2.object_key)
    assert {:error, :deleted} = Artifact.get(art, c, aid2, 1)
    assert {:ok, %{reaped: []}} = Artifact.reap(art, c, aid2)
  end

  test "L12 expired-access records are reaped too" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art, clock: clock} = memory()
    c = caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, _} =
             Artifact.put(art, c, aid, H.input("data", access_expires_at_unix_ms: H.epoch() + 500))

    TestClock.advance(clock, 1_000)
    assert {:error, :expired} = Artifact.head(art, c, aid)
    assert {:ok, %{reaped: [1]}} = Artifact.reap(art, c, aid)
  end

  test "L13 list is tenant-scoped, bounded and access-filtered" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art} = memory()
    c = caller("t-#{id("t")}")
    other = caller("t-#{id("t")}")

    for i <- 1..3,
        do: assert({:ok, _} = Artifact.put(art, c, "art-#{i}-#{id("x")}", H.input("b#{i}")))

    assert {:ok, %{entries: entries, cursor: nil}} = Artifact.list(art, c, 10, nil)
    assert length(entries) == 3
    assert {:ok, %{entries: []}} = Artifact.list(art, other, 10, nil)

    # bounded page
    assert {:ok, %{entries: first, cursor: cur}} = Artifact.list(art, c, 2, nil)
    assert length(first) == 2 and is_integer(cur)
    assert {:ok, %{entries: rest}} = Artifact.list(art, c, 2, cur)
    assert length(rest) >= 1

    denied_id = id("denied")
    expired_id = id("expired")

    assert {:ok, _} =
             Artifact.put(
               art,
               c,
               denied_id,
               H.input("private", access: %{tenant: c.tenant, principals: ["alice"], scopes: :any})
             )

    assert {:ok, _} =
             Artifact.put(
               art,
               c,
               expired_id,
               H.input("expired", access_expires_at_unix_ms: H.epoch())
             )

    assert {:ok, %{entries: filtered, cursor: nil}} = Artifact.list(art, c, 100, nil)
    assert MapSet.new(filtered, & &1.artifact_id) == MapSet.new(entries, & &1.artifact_id)
    refute Enum.any?(filtered, &(&1.artifact_id in [denied_id, expired_id]))
    assert {:error, :access_denied} = Artifact.status(art, c, %{artifact_id: denied_id, version: 1})
    assert {:error, :expired} = Artifact.status(art, c, %{artifact_id: expired_id, version: 1})
  end

  test "L14 hash_format is stored and verification uses the record's format" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art1, store: store} = memory(hash_format: 1)
    c = caller("t-#{id("t")}")
    aid = id("art")

    assert {:ok, r1} = Artifact.put(art1, c, aid, H.input("data"))
    assert r1.hash_format == 1 and r1.sha256 == Record.content_hash(1, "data")

    # A declared migration: a second construction stamps format 2; the old
    # record still verifies under its stored format, never reinterpreted.
    {:ok, clock} = TestClock.start_link(H.epoch())

    {:ok, art2} =
      Artifact.new(
        store: store,
        object_store: S3.config!(),
        clock: {:manual, clock},
        hash_format: 2
      )

    assert {:ok, r2} = Artifact.new_version(art2, c, aid, H.input("data"))
    assert r2.hash_format == 2 and r2.sha256 == Record.content_hash(2, "data")
    assert r2.sha256 != r1.sha256
    assert {:ok, %{bytes: "data"}} = Artifact.get(art2, c, aid, 1)
    assert {:ok, %{bytes: "data"}} = Artifact.get(art2, c, aid, 2)
  end

  test "L15 no credential or byte content in results, errors, inspect or events" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art} = memory()
    c = caller("t-#{id("t")}")
    secret = S3.secret!()

    assert {:ok, rec} = Artifact.put(art, c, id("art"), H.input("secret-bytes"))
    text = inspect(rec, limit: :infinity, printable_limit: :infinity, structs: false)
    refute String.contains?(text, secret)
    refute String.contains?(text, "secret-bytes")

    # the Piece source never reads the environment
    lib = Path.expand("../../lib/elzoo", __DIR__)

    files =
      Path.wildcard(Path.join(lib, "artifact.ex")) ++
        Path.wildcard(Path.join(lib, "artifact/**/*.ex"))

    assert length(files) >= 3
    assert Enum.any?(files, &(Path.basename(&1) == "artifact.ex"))

    for file <- files do
      refute File.read!(file) =~ "System.get_env"
    end
  end

  test "L16 telemetry events are emitted with bounded metadata" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art} = memory()
    c = caller("t-#{id("t")}")
    aid = id("art")

    test_pid = self()

    :telemetry.attach_many(
      {:artifact_test, self()},
      Elzoo.Artifact.Telemetry.events(),
      fn event, measurements, metadata, _ ->
        send(test_pid, {:ev, event, measurements, metadata})
      end,
      nil
    )

    assert {:ok, _} = Artifact.put(art, c, aid, H.input("data"))
    assert {:ok, %{object: :deleted}} = Artifact.delete(art, c, aid, 1)

    assert_received {:ev, [:elzoo, :artifact, :staged], %{size_bytes: 4, version: 1}, meta1}
    assert meta1.artifact_id == aid and meta1.upload == :committed
    assert_received {:ev, [:elzoo, :artifact, :committed], %{size_bytes: 4, version: 1}, _}

    assert_received {:ev, [:elzoo, :artifact, :deleted], %{version: 1},
                     %{cause: :delete, object: :deleted}}

    :telemetry.detach({:artifact_test, self()})
  end

  test "L17 integrity_failure event fires on mismatch" do
    if not s3?(), do: raise("ELZOO_TEST_S3_* required (fail closed)")
    %{art: art, object_store: os} = memory()
    c = caller("t-#{id("t")}")
    aid = id("art")
    test_pid = self()

    :telemetry.attach(
      {:artifact_test2, self()},
      [:elzoo, :artifact, :integrity_failure],
      fn event, m, d, _ -> send(test_pid, {:ev, event, m, d}) end,
      nil
    )

    assert {:ok, rec} = Artifact.put(art, c, aid, H.input("good"))
    assert %{status: :committed} = Elzoo.ObjectStore.put(os, rec.object_key, "evil")
    assert {:error, {:integrity_mismatch, _}} = Artifact.get(art, c, aid, 1)
    assert_received {:ev, [:elzoo, :artifact, :integrity_failure], %{version: 1}, %{via: :get}}
    :telemetry.detach({:artifact_test2, self()})
  end

  test "L18 laws compile and audit clean; four negative controls are rejected" do
    assert {:module, @cure} = Code.ensure_loaded(@cure)
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(report, key) == [])

    assert report.absurd == 0
    exports = @cure.module_info(:exports) |> Enum.map(&elem(&1, 0))
    for law <- @laws, do: assert(String.to_atom(law) in exports, "law #{law} not exported")
    IO.puts("ELZ-096 laws compiled: #{length(@laws)}")

    negatives = [
      {"PermitExpired", "expired_after_refuses", "StampAfter() -> AccessExpired()",
       "StampAfter() -> AccessPermit()"},
      {"DeniedTermsPermit", "absent_principal_denies", "not principal_present -> AccessDenied()",
       "not principal_present -> AccessPermit()"},
      {"StagingDeletePermits", "staged_delete_refuses",
       "EvReap() -> GoTo(VDeleted())\n          EvDelete() -> RefuseInvalid()",
       "EvReap() -> GoTo(VDeleted())\n          EvDelete() -> GoTo(VCommitted())"},
      {"FalseTransition", "committed_abort_refuses",
       "step(VCommitted(), EvAbort()), RefuseInvalid()) =\n    reflexive(RefuseInvalid())",
       "step(VCommitted(), EvAbort()), GoTo(VCommitted())) =\n    reflexive(GoTo(VCommitted()))"}
    ]

    for {name, law, from, to} <- negatives do
      assert String.contains?(@source, from), "negative #{name}: pattern missing"

      wrong =
        @source
        |> String.replace("mod Elzoo.Artifact", "mod Elzoo." <> name)
        |> String.replace(from, to)

      assert {:error,
              {:codegen_error, {:source_context, {:conversion_failure, _, _}, %{line: line}}}} =
               Cure.Compiler.compile_and_load(wrong, source_roots: @roots)

      assert line in [law_line(law), law_line(law) + 1],
             "negative #{name} failed at line #{line}, law #{law} at #{law_line(law)}"

      IO.puts("ELZ-096 negative rejected in #{law}: #{name}")
    end
  end

  test "L19 pure decision tables match the law-covered Cure tables" do
    cure = :"Cure.Elzoo.Artifact"

    assert apply(cure, :decide, [true, true, :StampBefore]) == :AccessPermit
    assert apply(cure, :decide, [false, true, :StampBefore]) == :AccessDenied
    assert apply(cure, :decide, [false, true, :StampAfter]) == :AccessDenied
    assert apply(cure, :decide, [true, false, :StampBefore]) == :AccessDenied
    assert apply(cure, :decide, [true, true, :StampSame]) == :AccessExpired
    assert apply(cure, :decide, [true, true, :StampAfter]) == :AccessExpired

    assert apply(cure, :step, [:VStaging, :EvCommit]) == {:GoTo, :VCommitted}
    assert apply(cure, :step, [:VStaging, :EvDelete]) == :RefuseInvalid
    assert apply(cure, :step, [:VCommitted, :EvAbort]) == :RefuseInvalid
    assert apply(cure, :step, [:VDeleted, :EvCommit]) == :RefuseDeleted
    assert apply(cure, :step, [:VCommitted, :EvCommit]) == {:GoTo, :VCommitted}
  end

  # ── review fixes: append gate, per-version filtering, retention, damage,
  #    cleanup retry and list propagation (FakeS3 + Memory Store) ────────

  defp fake_memory do
    {config, pid} = H.fake_s3()
    {H.memory(object_store: config), pid}
  end

  test "L20 new_version and commit enforce the committed head's recorded access" do
    {m, _pid} = fake_memory()
    %{art: art} = m
    t = "t-#{id("t")}"
    owner = caller(t, principal: "alice", scopes: ["read"])
    denied = caller(t, principal: "mallory", scopes: ["read"])
    aid = id("art")

    access = %{tenant: t, principals: ["alice"], scopes: ["read"]}
    assert {:ok, _} = Artifact.put(art, caller(t), aid, H.input("v1", access: access))

    # the early gate refuses before any byte is staged
    assert {:error, :access_denied} = Artifact.new_version(art, denied, aid, H.input("evil"))
    assert {:ok, %{version: 1}} = Artifact.head(art, owner, aid)

    # the hard gate at commit covers the manual stage+commit bypass
    assert {:ok, staged} = Artifact.stage(art, denied, aid, H.input("evil"))
    assert staged.state == :staging and staged.version == 2
    assert {:error, :access_denied} = Artifact.commit(art, denied, aid, 2)
    assert {:ok, %{version: 1, state: :committed}} = Artifact.head(art, owner, aid)

    # the head-authorized caller appends; the orphaned staging keeps v2, so
    # the new head is v3 — version numbers are never reused
    assert {:ok, %{version: 3}} = Artifact.new_version(art, owner, aid, H.input("v3"))
    assert {:ok, %{version: 3}} = Artifact.head(art, owner, aid)
  end

  test "L21 an expired committed head gates appends with :expired" do
    {m, _pid} = fake_memory()
    %{art: art, clock: clock} = m
    t = "t-#{id("t")}"
    c = caller(t)
    aid = id("art")

    assert {:ok, _} =
             Artifact.put(art, c, aid, H.input("v1", access_expires_at_unix_ms: H.epoch() + 500))

    assert {:ok, staged} = Artifact.stage(art, c, aid, H.input("v2"))
    TestClock.advance(clock, 1_000)

    assert {:error, :expired} = Artifact.new_version(art, c, aid, H.input("v3"))
    assert {:error, :expired} = Artifact.commit(art, c, aid, staged.version)
    assert {:error, :expired} = Artifact.head(art, c, aid)
  end

  test "L22 versions filters each record by its own recorded terms" do
    {m, _pid} = fake_memory()
    %{art: art} = m
    t = "t-#{id("t")}"
    aid = id("art")
    alice = caller(t, principal: "alice", scopes: ["read"])
    bob = caller(t, principal: "bob", scopes: ["read"])

    # v1 is alice-only; v2 — committed by alice, the head-authorized caller —
    # widens to alice+bob under the documented rule
    assert {:ok, _} =
             Artifact.put(
               art,
               caller(t),
               aid,
               H.input("v1", access: %{tenant: t, principals: ["alice"], scopes: ["read"]})
             )

    assert {:ok, %{version: 2}} =
             Artifact.new_version(
               art,
               alice,
               aid,
               H.input("v2", access: %{tenant: t, principals: ["alice", "bob"], scopes: ["read"]})
             )

    assert {:ok, [v1, v2]} = Artifact.versions(art, alice, aid)
    assert v1.version == 1 and v2.version == 2

    # bob passes the head gate; v1's own terms deny him and it is omitted
    # entirely — terms, keys and metadata are never disclosed
    assert {:ok, [only]} = Artifact.versions(art, bob, aid)
    assert only.version == 2
    assert {:error, :access_denied} = Artifact.get(art, bob, aid, 1)
    assert {:ok, %{bytes: "v2"}} = Artifact.get(art, bob, aid, 2)
  end

  test "L23 prefix, fully retained and retained highest-version histories fail closed" do
    {m, fake} = fake_memory()
    %{art: art, store: store} = m
    t = "t-#{id("t")}"
    c = caller(t)
    aid = id("art")
    stream = Record.stream(t, aid)

    assert {:ok, _} = Artifact.put(art, c, aid, H.input("one"))
    assert {:ok, _} = Artifact.put(art, c, aid, H.input("two"))
    # stream rows: 1 staged v1, 2 committed v1, 3 staged v2, 4 committed v2

    H.checkpoint(store, stream)
    H.retain!(store, stream, 1)

    # Each surviving row is still self-contained, but that does not establish
    # that another version or a later lifecycle transition was not retained.
    {rows, _} = H.stream_rows(store, stream)
    folded = Record.fold(rows, Map.put(H.fold(), :limits, H.limits()))
    assert folded.head.version == 2
    assert Map.keys(folded.versions) |> Enum.sort() == [1, 2]
    assert folded.versions[1].sha256 == Record.content_hash(1, "one")
    assert_history_refused(m, fake, c, aid, :incomplete_prefix)

    H.retain!(store, stream, 2)

    # every v1 row is retained: the fold is a partial view and must fail
    # closed on every path, never treated as absent or reused
    for op <- [
          Artifact.head(art, c, aid),
          Artifact.get(art, c, aid, 2),
          Artifact.versions(art, c, aid),
          Artifact.status(art, c, %{artifact_id: aid, version: 2})
        ] do
      assert {:error, {:store_damaged, :incomplete_prefix}} = op
    end

    assert {:error, {:store_damaged, :incomplete_prefix}} =
             Artifact.stage(art, c, aid, H.input("three"))

    assert {:error, {:store_damaged, :incomplete_prefix}} =
             Artifact.new_version(art, c, aid, H.input("three"))

    assert_history_refused(m, fake, c, aid, :incomplete_prefix)
    H.retain!(store, stream, 4)
    assert_history_refused(m, fake, c, aid, :incomplete_prefix)

    # Out-of-order commits can retain the highest version without leaving a
    # gap in the surviving version numbers: v1 is all that remains at seq4.
    aid2 = id("art")
    assert {:ok, _} = Artifact.stage(art, c, aid2, H.input("v1"))
    assert {:ok, _} = Artifact.stage(art, c, aid2, H.input("v2"))
    assert {:ok, _} = Artifact.commit(art, c, aid2, 2)
    assert {:ok, _} = Artifact.commit(art, c, aid2, 1)
    stream2 = Record.stream(t, aid2)
    H.checkpoint(store, stream2)
    H.retain!(store, stream2, 3)
    assert_history_refused(m, fake, c, aid2, :incomplete_prefix)
  end

  defp assert_history_refused(m, fake, c, aid, expected) do
    requests = H.fake_requests(fake)
    before = :sys.get_state(m.memory) |> Map.take([:records, :heads])

    results = [
      Artifact.head(m.art, c, aid),
      Artifact.get(m.art, c, aid, 1),
      Artifact.versions(m.art, c, aid),
      Artifact.status(m.art, c, %{artifact_id: aid, version: 1}),
      Artifact.list(m.art, c, 100, nil),
      Artifact.stage(m.art, c, aid, H.input("next")),
      Artifact.put(m.art, c, aid, H.input("next")),
      Artifact.new_version(m.art, c, aid, H.input("next")),
      Artifact.commit(m.art, c, aid, 1),
      Artifact.abort(m.art, c, %{artifact_id: aid, version: 1}),
      Artifact.delete(m.art, c, aid, 1),
      Artifact.reap(m.art, c, aid)
    ]

    for result <- results do
      assert {:error, {:store_damaged, detail}} = result
      if expected != :any, do: assert(detail == expected)
    end

    assert H.fake_requests(fake) == requests
    assert :sys.get_state(m.memory) |> Map.take([:records, :heads]) == before
  end

  test "L24 an unreadable persisted row fails every operation closed" do
    {m, _pid} = fake_memory()
    %{art: art, store: store} = m
    t = "t-#{id("t")}"
    c = caller(t)
    aid = id("art")
    stream = Record.stream(t, aid)

    assert {:ok, _} = Artifact.put(art, c, aid, H.input("data"))

    # corrupt the committed row's payload: its digest no longer matches
    :ok = H.corrupt_row(store, stream, 2, %{payload: "corrupted-payload"})

    for op <- [
          Artifact.head(art, c, aid),
          Artifact.get(art, c, aid, 1),
          Artifact.versions(art, c, aid),
          Artifact.status(art, c, %{artifact_id: aid, version: 1})
        ] do
      assert {:error, {:store_damaged, %{first: {:unreadable, 2}}}} = op
    end

    # staging and version allocation must not treat damaged state as absent
    assert {:error, {:store_damaged, %{first: {:unreadable, 2}}}} =
             Artifact.stage(art, c, aid, H.input("next"))

    assert {:error, {:store_damaged, %{first: {:unreadable, 2}}}} =
             Artifact.new_version(art, c, aid, H.input("next"))
  end

  test "L25 failed object deletion is retried by reap's cleanup sweep" do
    {m, pid} = fake_memory()
    %{art: art, object_store: os} = m
    t = "t-#{id("t")}"
    c = caller(t)

    # :refused on delete leaves bytes behind; reap's sweep retries them
    aid1 = id("art")
    assert {:ok, r1} = Artifact.put(art, c, aid1, H.input("one"))
    H.fake_fail(pid, :delete, 403)

    assert {:ok, %{record: %{state: :deleted}, object: :refused}} =
             Artifact.delete(art, c, aid1, 1)

    assert %{status: :found} = Elzoo.ObjectStore.head(os, r1.object_key)

    H.fake_heal(pid)

    assert {:ok, %{reaped: [], object: %{}, cleanup: %{1 => :deleted}}} =
             Artifact.reap(art, c, aid1)

    assert %{status: :absent} = Elzoo.ObjectStore.head(os, r1.object_key)

    # :unknown retries the same way through abort
    aid2 = id("art")
    assert {:ok, s2} = Artifact.stage(art, c, aid2, H.input("two"))
    H.fake_fail(pid, :delete, 500)

    assert {:ok, %{record: %{state: :deleted}, object: :unknown}} =
             Artifact.abort(art, c, %{artifact_id: aid2, version: 1})

    assert %{status: :found} = Elzoo.ObjectStore.head(os, s2.object_key)

    H.fake_heal(pid)

    assert {:ok, %{reaped: [], cleanup: %{1 => :deleted}}} = Artifact.reap(art, c, aid2)
    assert %{status: :absent} = Elzoo.ObjectStore.head(os, s2.object_key)
  end

  test "L26 list propagates storage failures instead of returning a partial page" do
    {m, _pid} = fake_memory()
    %{art: art, store: store} = m
    t = "t-#{id("t")}"
    c = caller(t)

    aid_ok = id("art")
    aid_bad = id("art")
    assert {:ok, _} = Artifact.put(art, c, aid_ok, H.input("ok"))
    assert {:ok, _} = Artifact.put(art, c, aid_bad, H.input("bad"))

    # a damaged artifact stream fails the whole page, never a skipped entry
    :ok = H.corrupt_row(store, Record.stream(t, aid_bad), 2, %{payload: "corrupted"})
    assert {:error, {:store_damaged, %{first: {:unreadable, 2}}}} = Artifact.list(art, c, 10, nil)
  end

  test "L27 a damaged index row or unavailable store fails list closed" do
    {m, _pid} = fake_memory()
    %{art: art, store: store} = m
    t = "t-#{id("t")}"
    c = caller(t)
    aid = id("art")
    assert {:ok, _} = Artifact.put(art, c, aid, H.input("data"))

    # a row of an unrelated kind on the index stream is ignored
    index_stream = Record.index_stream(t)
    {:ok, head} = Elzoo.DurableLog.Store.read(store, :head, [index_stream])

    {:ok, rows, request} =
      Record.rows(index_stream, head.revision, [{"added", 1, ~s({"n":1})}], H.fold(), H.limits())

    {:committed, _} =
      Elzoo.DurableLog.Store.write(store, :append, [index_stream, head.revision, rows, []], request)

    assert {:ok, %{entries: [%{artifact_id: ^aid}]}} = Artifact.list(art, c, 10, nil)

    # corrupt the tenant index row itself
    :ok = H.corrupt_row(store, index_stream, 1, %{payload: "corrupted"})
    assert {:error, {:store_damaged, _}} = Artifact.list(art, c, 10, nil)
  end

  test "L28 an unavailable store fails list with :store_unavailable" do
    {m, _pid} = fake_memory()
    %{art: art, store: store} = m
    t = "t-#{id("t")}"
    c = caller(t)
    assert {:ok, _} = Artifact.put(art, c, id("art"), H.input("data"))

    :ok = Elzoo.DurableLog.Memory.fault(store, :read, :unavailable)
    assert {:error, :store_unavailable} = Artifact.list(art, c, 10, nil)
  end

  test "L29 missing or malformed lifecycle positions fail closed before any object effect" do
    for damage <- [
          :missing,
          :nil_sequence,
          :malformed_row,
          :duplicate,
          :out_of_order,
          :wrong_stream,
          :truncated
        ] do
      {m, fake} = fake_memory()
      c = caller("history")
      aid = "damaged"
      stream = Record.stream(c.tenant, aid)
      assert {:ok, old} = Artifact.put(m.art, c, aid, H.input("deleted-bytes"))
      H.fake_fail(fake, :delete, 403)
      assert {:ok, %{object: :refused}} = Artifact.delete(m.art, c, aid, 1)
      H.fake_heal(fake)
      assert {:ok, _} = Artifact.put(m.art, c, aid, H.input("live"))
      assert Map.has_key?(H.fake_objects(fake), old.object_key)

      case damage do
        :missing ->
          :sys.replace_state(m.memory, fn state ->
            %{state | records: Map.delete(state.records, {stream, 3})}
          end)

        :nil_sequence ->
          :ok = H.corrupt_row(m.store, stream, 3, %{sequence: nil})

        :malformed_row ->
          :sys.replace_state(m.memory, fn state ->
            %{state | records: Map.put(state.records, {stream, 3}, :malformed)}
          end)

        :duplicate ->
          :ok = H.corrupt_row(m.store, stream, 3, %{sequence: 2})

        :out_of_order ->
          :ok = H.corrupt_row(m.store, stream, 3, %{sequence: 4})

        :wrong_stream ->
          :ok = H.corrupt_row(m.store, stream, 3, %{stream: "artifact/history/other"})

        :truncated ->
          :sys.replace_state(m.memory, fn state ->
            %{state | records: Map.delete(state.records, {stream, 5})}
          end)
      end

      assert_history_refused(m, fake, c, aid, :any)
    end
  end

  test "L30 stage reserves the largest lifecycle payload including timestamp width" do
    {os, fake} = H.fake_s3()
    limits = %{H.limits() | max_record_bytes: 4_096}
    {:ok, mem} = Elzoo.DurableLog.Memory.start_link(fold: H.fold(), limits: limits)
    store = Elzoo.DurableLog.Memory.store(mem)
    {:ok, clock} = TestClock.start_link(9)

    {:ok, art} =
      Artifact.new(
        store: store,
        object_store: os,
        clock: {:manual, clock},
        max_metadata_bytes: 4_096,
        staging_ttl_ms: 100
      )

    c = caller("boundary")

    assert {:ok, proto} =
             Artifact.stage(art, c, "prototype", %{bytes: "data", metadata: %{"pad" => ""}})

    probe = %{
      proto
      | artifact_id: "size",
        object_key: Record.object_key(c.tenant, "size", 1, proto.sha256)
    }

    base = byte_size(Record.payload(probe))
    requests = H.fake_requests(fake)

    # The old guard admitted 4095 bytes, then refused the 4097-byte commit.
    assert {:error, :too_large} =
             Artifact.stage(art, c, "size", %{
               bytes: "data",
               metadata: %{"pad" => String.duplicate("x", 4_095 - base)}
             })

    assert H.fake_requests(fake) == requests
    assert {[], %{revision: 0}} = H.stream_rows(store, Record.stream(c.tenant, "size"))

    # A +2-only guard still misses the 9 -> 10 clock-width change. Reserve
    # all valid signed-bigint timestamp widths, for committed and deleted rows.
    assert {:error, :too_large} =
             Artifact.stage(art, c, "size", %{
               bytes: "data",
               metadata: %{"pad" => String.duplicate("x", 4_094 - base)}
             })

    assert H.fake_requests(fake) == requests

    widest =
      byte_size(Record.payload(%{probe | state: :committed, state_at: 9_223_372_036_854_775_807}))

    assert {:ok, staged} =
             Artifact.stage(art, c, "size", %{
               bytes: "data",
               metadata: %{"pad" => String.duplicate("x", 4_096 - widest)}
             })

    assert byte_size(
             Record.payload(%{staged | state: :committed, state_at: 9_223_372_036_854_775_807})
           ) == 4_096

    TestClock.set(clock, 10)
    assert {:ok, committed} = Artifact.commit(art, c, "size", 1)
    assert committed.state == :committed
    assert {:ok, %{record: %{state: :deleted}}} = Artifact.delete(art, c, "size", 1)

    TestClock.set(clock, 9)

    assert {:ok, last} =
             Artifact.stage(art, c, "size", %{
               bytes: "data",
               metadata: %{"pad" => String.duplicate("x", 4_096 - widest)}
             })

    TestClock.set(clock, 9_223_372_036_854_775_807)

    assert {:ok, final} =
             Artifact.commit(
               %{art | staging_ttl_ms: 9_223_372_036_854_775_807},
               c,
               "size",
               last.version
             )

    assert byte_size(Record.payload(final)) == 4_096
  end

  test "L31 published timestamp keys roundtrip exactly and drive expiry and retention" do
    {m, fake} = fake_memory()
    c = caller("timestamps")
    expiry = H.epoch() + 100
    retain = H.epoch() + 200
    input = %{bytes: "data", access_expires_at_unix_ms: expiry, retain_until_unix_ms: retain}
    assert {:ok, rec} = Artifact.put(m.art, c, "named", input)
    assert rec.created_at_unix_ms == H.epoch()
    assert rec.access_expires_at_unix_ms == expiry
    assert rec.retain_until_unix_ms == retain
    refute Map.has_key?(rec, :created_at)
    refute Map.has_key?(rec, :access_expires_at)
    refute Map.has_key?(rec, :retain_until)
    {rows, _} = H.stream_rows(m.store, Record.stream(c.tenant, "named"))

    for row <- rows do
      data = Jason.decode!(row.payload)
      assert data["created_at_unix_ms"] == H.epoch()
      assert data["access_expires_at_unix_ms"] == expiry
      assert data["retain_until_unix_ms"] == retain
      refute Map.has_key?(data, "created_at")
      refute Map.has_key?(data, "access_expires_at")
      refute Map.has_key?(data, "retain_until")
      assert {:record, decoded} = Record.event(row, Map.put(H.fold(), :limits, H.limits()))
      assert decoded.access_expires_at_unix_ms == expiry
      assert decoded.retain_until_unix_ms == retain

      for key <- ["created_at_unix_ms", "access_expires_at_unix_ms", "retain_until_unix_ms"] do
        broken = %{row | payload: data |> Map.delete(key) |> Jason.encode!()}
        broken = %{broken | digest: Elzoo.DurableLog.digest(broken)}
        assert :unreadable = Record.event(broken, Map.put(H.fold(), :limits, H.limits()))
      end
    end

    assert {:ok, ^rec} = Artifact.head(m.art, c, "named")
    assert {:ok, %{record: ^rec}} = Artifact.get(m.art, c, "named", 1)

    assert {:ok, retained} =
             Artifact.put(m.art, c, "retained", %{bytes: "retain", retain_until_unix_ms: retain})

    assert retained.access_expires_at_unix_ms == :never
    TestClock.set(m.clock, expiry)
    assert {:error, :expired} = Artifact.head(m.art, c, "named")
    assert {:error, :expired} = Artifact.status(m.art, c, %{artifact_id: "named", version: 1})
    assert {:ok, %{reaped: [1]}} = Artifact.reap(m.art, c, "named")
    assert {:ok, %{reaped: []}} = Artifact.reap(m.art, c, "retained")
    TestClock.set(m.clock, retain)
    assert {:ok, %{reaped: [1]}} = Artifact.reap(m.art, c, "retained")
    refute Map.has_key?(H.fake_objects(fake), retained.object_key)
  end

  test "L32 commit rejects mismatched object checksum and leaves staging unchanged" do
    {m, _fake} = fake_memory()
    c = caller("mismatch")
    assert {:ok, rec} = Artifact.stage(m.art, c, "wrong", H.input("good"))
    assert %{status: :committed} = Elzoo.ObjectStore.put(m.object_store, rec.object_key, "evil")
    before = H.stream_rows(m.store, Record.stream(c.tenant, "wrong"))

    assert {:error, {:commit_failed, %{evidence: :object_mismatch}}} =
             Artifact.commit(m.art, c, "wrong", 1)

    assert H.stream_rows(m.store, Record.stream(c.tenant, "wrong")) == before

    assert {:ok, %{record: ^rec, object: :mismatch}} =
             Artifact.status(m.art, c, %{artifact_id: "wrong", version: 1})
  end

  test "L33 a real CAS race refuses the losing commit and preserves its staging row" do
    {m, _fake} = fake_memory()
    c = caller("cas")
    aid = "race"
    stream = Record.stream(c.tenant, aid)
    assert {:ok, staged} = Artifact.stage(m.art, c, aid, H.input("data"))
    {staged_rows, _} = H.stream_rows(m.store, stream)
    # commit samples its clock after load; the competing append is real Store
    # CAS between that load and commit's write, without sleeps or fake replies.
    racing = %{
      m.art
      | clock: fn ->
          H.append_foreign!(m.store, stream)
          H.epoch()
        end
    }

    assert {:error, {:commit_failed, %{expected: 1, observed: 2}}} =
             Artifact.commit(racing, c, aid, 1)

    assert {rows, %{revision: 2}} = H.stream_rows(m.store, stream)
    assert Enum.take(rows, 1) == staged_rows
    assert Enum.map(rows, & &1.kind) == [Record.staged(), "foreign"]

    assert {:ok, %{record: ^staged, object: :verified}} =
             Artifact.status(m.art, c, %{artifact_id: aid, version: 1})

    assert {:ok, %{state: :committed}} = Artifact.commit(m.art, c, aid, 1)
  end

  test "L34 sequence coverage spans pages and stops at the sampled committed revision" do
    {m, fake} = fake_memory()
    c = caller("pages")
    aid = "large"
    stream = Record.stream(c.tenant, aid)
    assert {:ok, rec} = Artifact.put(m.art, c, aid, H.input("data"))
    for _ <- 1..1_001, do: H.append_foreign!(m.store, stream)
    assert {:ok, ^rec} = Artifact.head(m.art, c, aid)
    # A valid index kind in an artifact stream remains a benign foreign row.
    H.append_foreign!(m.store, stream, Record.index_kind(), Record.index_payload(aid, H.epoch()))
    assert {:ok, ^rec} = Artifact.head(m.art, c, aid)
    # A concurrent append after the head sample is outside this snapshot; the
    # next read sees it. Neither operation falsely diagnoses missing history.
    wrapped = {Elzoo.Artifact.AppendOnRead, %{inner: m.store, stream: stream}}
    assert {:ok, ^rec} = Artifact.head(%{m.art | store: wrapped}, c, aid)

    :sys.replace_state(m.memory, fn state ->
      %{state | records: Map.delete(state.records, {stream, 1_002})}
    end)

    assert_history_refused(m, fake, c, aid, :any)
  end
end
