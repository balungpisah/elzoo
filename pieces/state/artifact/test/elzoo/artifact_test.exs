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

  test "A2 unsafe tenant/artifact_id segments are refused before key construction" do
    %{art: art} = memory()
    c = caller("t1")

    for bad <- ["a/b", "..", ".", "a b", "", "x" <> String.duplicate("y", 65)] do
      assert {:error, :invalid} = Artifact.stage(art, c, bad, H.input("b"))
    end

    for bad_tenant <- ["a/b", "..", ".", " "] do
      assert {:error, :invalid} = Artifact.stage(art, caller(bad_tenant), "a1", H.input("b"))
    end
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
             Artifact.put(art, c, aid, H.input("data", access_expires_at: H.epoch() + 1_000))

    TestClock.advance(clock, 2_000)
    assert {:error, :expired} = Artifact.head(art, c, aid)
    assert {:error, :expired} = Artifact.get(art, c, aid, 1)
    assert {:error, :expired} = Artifact.versions(art, c, aid)
    assert {:error, :expired} = Artifact.delete(art, c, aid, 1)
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
             Artifact.put(art, c, aid, H.input("data", retain_until: H.epoch() + 1_000))

    assert {:error, {:invalid, :state}} = Artifact.abort(art, c, %{artifact_id: aid, version: 1})
    assert {:ok, %{object: :deleted}} = Artifact.delete(art, c, aid, 1)
    assert %{status: :absent} = Elzoo.ObjectStore.head(os, rec.object_key)
    assert {:error, :deleted} = Artifact.get(art, c, aid, 1)
    assert {:error, :deleted} = Artifact.delete(art, c, aid, 1)

    # retention expiry: committed record reaped
    aid2 = id("art")

    assert {:ok, rec2} =
             Artifact.put(art, c, aid2, H.input("data2", retain_until: H.epoch() + 1_000))

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

    assert {:ok, _} = Artifact.put(art, c, aid, H.input("data", access_expires_at: H.epoch() + 500))
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
    for file <- Path.wildcard("pieces/state/artifact/lib/**/*.ex") do
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
             Artifact.put(art, c, aid, H.input("v1", access_expires_at: H.epoch() + 500))

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

  test "L23 self-contained rows survive prefix retention; a retained version fails closed" do
    {m, _pid} = fake_memory()
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

    # the staged v1 row is gone; v1 rebuilds whole from its committed row
    assert {:ok, %{version: 2}} = Artifact.head(art, c, aid)
    assert {:ok, [%{version: 1}, %{version: 2}]} = Artifact.versions(art, c, aid)
    assert {:ok, %{bytes: "one"}} = Artifact.get(art, c, aid, 1)

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
end
