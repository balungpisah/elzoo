# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/object_store_test_helper.exs", __DIR__)

defmodule Elzoo.ObjectStoreTest do
  # Scenarios S1-S12 and S16-S17 of the ELZ-053 work record against the pinned disposable MinIO
  # (scripts/ci-minio.py, ELZ-064). Finite observations on one server, not proofs.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Elzoo.ObjectStore, as: OS
  alias Elzoo.ObjectStoreTestHelper, as: H

  setup_all do
    # Fail closed: raises (never skips) without the ELZOO_TEST_S3_* variables.
    _ = H.env!()
    %{config: H.config!(), secret: H.secret!(), access_key: H.access_key!()}
  end

  setup do
    %{p: H.prefix()}
  end

  test "S1 put and get round trip with checksum (binary and stream)", %{config: c, p: p} do
    data = "hello object store " <> :crypto.strong_rand_bytes(64)
    key = "#{p}/a b/ü.txt"

    put = OS.put(c, key, data, content_type: "text/plain")
    assert %{status: :committed, operation: :put, store: "test-minio", bucket: _, key: ^key} = put
    assert put.bytes == byte_size(data)
    assert put.sha256 == Base.encode16(H.sha(data), case: :lower)
    assert is_binary(put.etag)

    assert %{status: :found, body: ^data, metadata: m} = OS.get(c, key)
    assert m.sha256 == put.sha256 and m.size == byte_size(data) and m.content_type == "text/plain"

    assert %{status: :found, metadata: hm} = OS.head(c, key)
    refute Map.has_key?(OS.head(c, key), :body)
    assert hm.sha256 == put.sha256

    big = :crypto.strong_rand_bytes(100_000)
    chunks = for <<chunk::binary-size(10_000) <- big>>, do: chunk

    assert %{status: :committed, bytes: 100_000} =
             OS.put(c, "#{p}/stream", {:stream, chunks, 100_000}, content_sha256: H.sha(big))

    assert %{status: :found, body: ^big} = OS.get(c, "#{p}/stream")
  end

  test "S2 a denied request is refused{denied}, never absent", %{config: c, p: p} do
    bad = H.config!(credentials: {H, :wrong_credentials, []})
    assert %{status: :committed} = OS.put(c, "#{p}/x", "x")

    for r <- [
          OS.put(bad, "#{p}/y", "y"),
          OS.get(bad, "#{p}/x"),
          OS.head(bad, "#{p}/x"),
          OS.list(bad, p),
          OS.delete(bad, "#{p}/x")
        ] do
      assert %{status: :refused, reason: :denied, origin: :provider} = r
    end

    assert %{status: :found} = OS.head(c, "#{p}/x")
  end

  test "S3 a missing bucket is refused{no_such_bucket} on every operation, never absent", %{p: p} do
    c = H.config!(bucket: "elz053-missing-#{System.unique_integer([:positive])}")

    for r <- [
          OS.put(c, "#{p}/x", "x"),
          OS.get(c, "#{p}/x"),
          OS.head(c, "#{p}/x"),
          OS.list(c, p),
          OS.delete(c, "#{p}/x")
        ] do
      assert %{status: :refused, reason: :no_such_bucket, origin: :provider} = r
    end
  end

  test "S4 a missing object is absent on get and head", %{config: c, p: p} do
    assert %{status: :absent, key: k} = OS.get(c, "#{p}/missing")
    assert k == "#{p}/missing"
    assert %{status: :absent} = OS.head(c, "#{p}/missing")
  end

  test "S5 list pagination is bounded and its continuation explicit", %{config: c, p: p} do
    for i <- 1..5, do: %{status: :committed} = OS.put(c, "#{p}/l/#{i}", "x#{i}")

    pages =
      Stream.unfold({:start, nil}, fn
        :done ->
          nil

        {_, token} ->
          r = OS.list(c, "#{p}/l/", page_size: 2, continuation: token)
          assert %{status: :listed, prefix: _, store: "test-minio"} = r
          assert length(r.keys) <= 2
          {r, if(r.truncated, do: {:next, r.continuation}, else: :done)}
      end)
      |> Enum.to_list()

    assert Enum.map(pages, & &1.truncated) == [true, true, false]
    assert List.last(pages).continuation == nil
    assert Enum.flat_map(pages, & &1.keys) == for(i <- 1..5, do: "#{p}/l/#{i}")

    assert %{status: :listed, keys: [], truncated: false} = OS.list(c, "#{p}/none/")
    assert %{status: :listed, prefix: ""} = OS.list(c, "", page_size: 1)

    # bounds and arguments are checked before dispatch
    assert %{status: :refused, reason: :invalid_request, origin: :local} =
             OS.list(c, p, page_size: c.max_page_size + 1)

    assert %{status: :refused, reason: :invalid_request} = OS.list(c, p, page_size: 0)
    assert %{status: :refused, reason: :invalid_request} = OS.list(c, p, continuation: "a b")
    assert %{status: :refused, reason: :invalid_request} = OS.list(c, <<0>>)
    assert %{status: :refused, reason: :invalid_request} = OS.list(c, nil)
  end

  test "S6 too large: refused before dispatch for bodies, adapter refusal for a get", %{p: p} do
    small = H.config!(max_object_bytes: 10)

    assert %{status: :refused, reason: :too_large, origin: :local} =
             OS.put(small, "#{p}/big", "12345678901")

    assert %{status: :refused, reason: :too_large, origin: :local} =
             OS.put(small, "#{p}/big", {:stream, ["x"], 11}, content_sha256: H.sha("x"))

    assert %{status: :absent} = OS.head(small, "#{p}/big")

    c = H.config!()
    assert %{status: :committed} = OS.put(c, "#{p}/eleven", "12345678901")
    assert %{status: :refused, reason: :too_large, origin: :adapter} = OS.get(small, "#{p}/eleven")
  end

  test "S7 interrupted upload is unknown; reconciliation reports absent or a compared object", %{
    config: c,
    p: p
  } do
    data = :crypto.strong_rand_bytes(50_000)
    sha = H.sha(data)

    # the body stops mid-way until the deadline
    stalled =
      Stream.concat(
        [binary_part(data, 0, 10_000)],
        Stream.repeatedly(fn -> Process.sleep(60_000) end)
      )

    assert %{status: :unknown, reason: :deadline} =
             OS.put(c, "#{p}/stalled", {:stream, stalled, 50_000},
               content_sha256: sha,
               deadline_ms: 800
             )

    # the body source fails mid-way
    failing =
      Stream.concat(
        [binary_part(data, 0, 10_000)],
        Stream.map([1], fn _ -> raise "source broke" end)
      )

    assert %{status: :unknown, reason: :transport} =
             OS.put(c, "#{p}/failing", {:stream, failing, 50_000}, content_sha256: sha)

    # the connection is dropped mid-body by a loopback proxy in front of the server
    port = URI.parse(c.endpoint).port
    {proxy, _} = H.stub({:proxy, port, 20_000})
    via_proxy = H.config!(endpoint: "http://127.0.0.1:#{proxy}")

    assert %{status: :unknown, reason: r} =
             OS.put(via_proxy, "#{p}/dropped", data, deadline_ms: 5_000)

    assert r in [:transport, :deadline]

    for key <- ["#{p}/stalled", "#{p}/failing", "#{p}/dropped"] do
      assert %{status: :reconciled, observation: obs} = OS.reconcile_put(c, key, sha)
      # absent is an observation, never proof of no effect; a found object is compared
      assert obs in [:absent, :match]
    end

    assert %{status: :committed} = OS.put(c, "#{p}/other", "other")
    assert %{status: :reconciled, observation: :mismatch} = OS.reconcile_put(c, "#{p}/other", sha)

    assert %{status: :reconciled, observation: :match} =
             OS.reconcile_put(c, "#{p}/other", H.sha("other"))
  end

  test "S8 checksum mismatch: provider refusal for a stream, local refusal for a binary", %{
    config: c,
    p: p
  } do
    data = String.duplicate("z", 20_000)

    assert %{status: :refused, reason: :checksum_mismatch, origin: :provider} =
             OS.put(c, "#{p}/s", {:stream, [data], 20_000}, content_sha256: H.sha("no"))

    assert %{status: :absent} = OS.head(c, "#{p}/s")

    assert %{status: :refused, reason: :checksum_mismatch, origin: :local} =
             OS.put(c, "#{p}/b", data, content_sha256: H.sha("no"))

    assert %{status: :committed} = OS.put(c, "#{p}/b", data, content_sha256: H.sha(data))
  end

  test "S9 presign: works before expiry, refused after; put presign; no I/O, redacted inspect", %{
    config: c,
    p: p,
    access_key: ak,
    secret: sk
  } do
    assert %{status: :committed} = OS.put(c, "#{p}/pre", "presigned body")
    assert {:ok, pre} = OS.presign(c, "#{p}/pre", expires_s: 60)
    assert %{status: 200, body: "presigned body"} = Req.get!(pre.url, retry: false)
    assert String.contains?(pre.url, ak)
    refute String.contains?(pre.url, sk)
    refute String.contains?(inspect(pre), ak)
    refute String.contains?(inspect(pre), "X-Amz")

    assert {:ok, short} = OS.presign(c, "#{p}/pre", expires_s: 1)
    Process.sleep(2_100)
    assert %{status: 403} = Req.get!(short.url, retry: false)

    assert {:ok, up} = OS.presign(c, "#{p}/up", method: :put, expires_s: 60)
    assert %{status: 200} = Req.put!(up.url, body: "via presign", retry: false)
    assert %{status: :found, body: "via presign"} = OS.get(c, "#{p}/up")

    assert %{status: :refused, reason: :invalid_request} =
             OS.presign(c, "#{p}/x", expires_s: c.presign_max_s + 1)

    assert %{status: :refused, reason: :invalid_request} = OS.presign(c, "#{p}/x", method: :delete)
  end

  test "S10 if_absent on an existing key is refused{precondition_failed}", %{config: c, p: p} do
    assert %{status: :committed} = OS.put(c, "#{p}/once", "1", if_absent: true)

    assert %{status: :refused, reason: :precondition_failed, origin: :provider} =
             OS.put(c, "#{p}/once", "2", if_absent: true)

    assert %{status: :found, body: "1"} = OS.get(c, "#{p}/once")

    # Devin 1: a non-boolean if_absent is refused before dispatch, never an unconditional write
    for bad <- [1, "true", :yes, nil] do
      assert %{status: :refused, reason: :invalid_request, origin: :local} =
               OS.put(c, "#{p}/once", "3", if_absent: bad)
    end

    assert %{status: :found, body: "1"} = OS.get(c, "#{p}/once")
    assert %{status: :committed} = OS.put(c, "#{p}/once", "4", if_absent: false)
    assert %{status: :found, body: "4"} = OS.get(c, "#{p}/once")
  end

  test "delete is committed on 204 for an existing and for a missing key", %{config: c, p: p} do
    assert %{status: :committed} = OS.put(c, "#{p}/d", "d")
    assert %{status: :committed, etag: nil, bytes: 0, sha256: nil} = OS.delete(c, "#{p}/d")
    assert %{status: :absent} = OS.head(c, "#{p}/d")
    assert %{status: :committed} = OS.delete(c, "#{p}/never-existed")
  end

  test "S11 the secret never appears in results, errors, inspect values or logs; the access-key ID and presigned URLs never outside a presign result",
       %{config: c, p: p, access_key: ak, secret: sk} do
    bad = H.config!(credentials: {H, :wrong_credentials, []})
    missing = H.config!(bucket: "elz053-missing-#{System.unique_integer([:positive])}")
    failing_need = H.config!(credentials: fn -> raise "need failed: " <> sk end)

    {results, log} =
      with_log([level: :debug], fn ->
        [
          OS.put(c, "#{p}/k", "v"),
          OS.get(c, "#{p}/k"),
          OS.head(c, "#{p}/k"),
          OS.list(c, p),
          OS.delete(c, "#{p}/k"),
          OS.put(bad, "#{p}/k", "v"),
          OS.get(bad, "#{p}/k"),
          OS.head(missing, "#{p}/k"),
          OS.put(c, "#{p}/k", {:stream, ["x"], 5}, content_sha256: H.sha("x"), deadline_ms: 300),
          OS.put(failing_need, "#{p}/k", "v"),
          OS.presign(failing_need, "#{p}/k"),
          OS.reconcile_put(c, "#{p}/k", H.sha("v")),
          OS.new(
            store_id: "s",
            endpoint: "ftp://x",
            bucket: "b",
            region: "r",
            credentials: fn -> :x end
          )
        ]
      end)

    assert %{status: :refused, reason: :credentials_unavailable, origin: :local} =
             Enum.at(results, 9)

    assert %{status: :refused, reason: :credentials_unavailable} = Enum.at(results, 10)

    for r <- results, do: assert(H.free_of?(r, [sk, ak]))
    refute String.contains?(log, sk)
    refute String.contains?(log, ak)

    for %{status: s} = r <- results,
        s in [:committed, :found, :absent, :listed, :refused, :unknown] do
      {:ok, envelope, _} = OS.to_delivery_result(r, %{"message_id" => "m-1"})
      assert H.free_of?(envelope, [sk, ak])
    end

    assert H.free_of?(c, [sk, ak])

    {{:ok, pre}, log2} = with_log([level: :debug], fn -> OS.presign(c, "#{p}/k") end)
    assert H.free_of?(inspect(pre), [sk, ak, pre.url])
    refute String.contains?(log2, pre.url)
  end

  test "S11 upstream limit: a consumer-installed Finch handler sees the access-key ID in the signed header, never the secret",
       %{config: c, p: p, access_key: ak, secret: sk} do
    parent = self()
    id = "elz053-finch-#{System.unique_integer([:positive])}"

    :ok = :telemetry.attach(id, [:finch, :request, :start], &__MODULE__.finch_handler/4, parent)

    try do
      assert %{status: :committed} = OS.put(c, "#{p}/t", "t")
    after
      :telemetry.detach(id)
    end

    assert_received {:finch_meta, text}
    refute String.contains?(text, sk)
    # upstream behaviour, documented as a consumer responsibility (M2)
    assert String.contains?(text, ak)
  end

  def finch_handler(_event, _measurements, meta, parent),
    do: send(parent, {:finch_meta, inspect(meta, limit: :infinity, printable_limit: :infinity)})

  test "S11 the Adapter's own source emits no log line and no telemetry event" do
    # Only this Piece's own sources: in a copied consumer, lib/ also holds other Pieces' files
    # (runtime/telemetry among them). The expected list is fixed, so a missing file fails.
    lib = Path.expand("../../lib", __DIR__)

    own = [
      "elzoo/object_store.ex",
      "elzoo/object_store/binding.ex",
      "elzoo/object_store/config.ex",
      "elzoo/object_store/presigned.ex",
      "elzoo/object_store/request.ex",
      "elzoo/object_store/result.ex"
    ]

    found =
      [
        Path.join(lib, "elzoo/object_store.ex")
        | Path.wildcard(Path.join(lib, "elzoo/object_store/**/*.ex"))
      ]
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, lib))
      |> Enum.sort()

    assert found == own

    for relative <- own do
      file = Path.join(lib, relative)
      source = File.read!(file)
      refute source =~ ~r/\bLogger\./, file
      refute source =~ ~r/:telemetry\./, file
      refute source =~ ~r/\bIO\.(puts|inspect|write)/, file
    end
  end

  test "S12 environment fallbacks of req_s3 are never used", %{config: c, p: p} do
    saved =
      Map.new(
        ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_ENDPOINT_URL_S3 AWS_REGION),
        &{&1, System.get_env(&1)}
      )

    try do
      System.put_env("AWS_ACCESS_KEY_ID", "envkey")
      System.put_env("AWS_SECRET_ACCESS_KEY", "envsecret")
      System.put_env("AWS_ENDPOINT_URL_S3", "http://127.0.0.1:1")
      System.put_env("AWS_REGION", "eu-west-9")
      assert %{status: :committed} = OS.put(c, "#{p}/env", "env")
      assert %{status: :found} = OS.head(c, "#{p}/env")
      assert {:ok, pre} = OS.presign(c, "#{p}/env")
      assert %{status: 200, body: "env"} = Req.get!(pre.url, retry: false)
      refute String.contains?(pre.url, "envkey")
    after
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  test "S15 an Effect declaration must name this capability and the operation", %{config: c, p: p} do
    command = %{
      "version" => 1,
      "kind" => "command",
      "message_id" => "m-1",
      "schema_id" => "elzoo/object-store-put",
      "schema_version" => 1,
      "producer" => %{"unit_id" => "u", "port_id" => "p"},
      "payload" => nil
    }

    decl = fn cap, op ->
      %{
        "capability_id" => cap,
        "operation" => op,
        "classification" => "untrusted",
        "command" => command
      }
    end

    assert {:ok, _} = Elzoo.Effect.validate(decl.("integration/object-store", "put"))

    assert %{status: :committed} =
             OS.put(c, "#{p}/d", "d", declaration: decl.("integration/object-store", "put"))

    assert %{status: :refused, reason: :invalid_request, origin: :local} =
             OS.put(c, "#{p}/e", "e", declaration: decl.("integration/http", "put"))

    assert %{status: :refused, reason: :invalid_request} =
             OS.put(c, "#{p}/e", "e", declaration: decl.("integration/object-store", "delete"))

    assert %{status: :refused, reason: :invalid_request} =
             OS.put(c, "#{p}/e", "e", declaration: %{})

    assert %{status: :absent} = OS.head(c, "#{p}/e")

    # Devin 5: a supplied declaration is checked by every operation, reads and presign included
    other = decl.("integration/http", "get")

    for r <- [
          OS.get(c, "#{p}/d", declaration: other),
          OS.head(c, "#{p}/d", declaration: other),
          OS.list(c, p, declaration: other),
          OS.presign(c, "#{p}/d", declaration: other),
          OS.delete(c, "#{p}/d", declaration: decl.("integration/object-store", "put")),
          OS.get(c, "#{p}/d", declaration: decl.("integration/object-store", "head"))
        ] do
      assert %{status: :refused, reason: :invalid_request, origin: :local} = r
    end

    assert %{status: :found} =
             OS.get(c, "#{p}/d", declaration: decl.("integration/object-store", "get"))

    assert %{status: :found} =
             OS.head(c, "#{p}/d", declaration: decl.("integration/object-store", "head"))

    assert %{status: :listed} =
             OS.list(c, p, declaration: decl.("integration/object-store", "list"))

    assert {:ok, _} =
             OS.presign(c, "#{p}/d", declaration: decl.("integration/object-store", "presign"))

    # re-review: a declared reconciliation after an unknown put observes the object
    data = :crypto.strong_rand_bytes(20_000)

    stalled =
      Stream.concat(
        [binary_part(data, 0, 1_000)],
        Stream.repeatedly(fn -> Process.sleep(60_000) end)
      )

    put_decl = decl.("integration/object-store", "put")

    assert %{status: :unknown, reason: :deadline} =
             OS.put(c, "#{p}/r", {:stream, stalled, 20_000},
               content_sha256: H.sha(data),
               deadline_ms: 500,
               declaration: put_decl
             )

    assert %{status: :committed} = OS.put(c, "#{p}/r", data, declaration: put_decl)

    for op <- ["reconcile_put", "put"] do
      assert %{status: :reconciled, observation: :match} =
               OS.reconcile_put(c, "#{p}/r", H.sha(data),
                 declaration: decl.("integration/object-store", op)
               )
    end

    assert %{status: :reconciled, observation: :absent} =
             OS.reconcile_put(c, "#{p}/never", H.sha(data),
               declaration: decl.("integration/object-store", "reconcile_put")
             )

    for bad <- [decl.("integration/object-store", "head"), decl.("integration/http", "put"), %{}] do
      assert %{status: :refused, reason: :invalid_request, origin: :local} =
               OS.reconcile_put(c, "#{p}/r", H.sha(data), declaration: bad)
    end
  end

  test "S16 the test binding fails closed without the S3 variables (never skips)" do
    for name <- H.vars() do
      saved = System.get_env(name)

      try do
        System.delete_env(name)
        assert_raise RuntimeError, ~r/#{name} is required.*fail closed/, fn -> H.config!() end
      after
        if saved, do: System.put_env(name, saved)
      end
    end
  end

  test "S17 invalid keys are refused before dispatch", %{config: c} do
    for key <- [
          "",
          "a//b",
          "a/./b",
          "../x",
          "x/..",
          "/lead",
          "nul" <> <<0>>,
          "ctl\n",
          <<0xFF>>,
          String.duplicate("k", 1025),
          :atom
        ] do
      assert %{status: :refused, reason: :invalid_key, origin: :local} = OS.put(c, key, "x")
      assert %{status: :refused, reason: :invalid_key} = OS.get(c, key)
      assert %{status: :refused, reason: :invalid_key} = OS.presign(c, key)
    end
  end

  test "Config: bounds, defaults and a redacting inspect", %{config: c} do
    assert c.max_object_bytes == 64 * 1024 * 1024
    assert {c.default_page_size, c.max_page_size} == {100, 1000}
    assert {c.presign_default_s, c.presign_max_s} == {900, 3600}
    assert c.default_deadline_ms == 30_000

    base = [
      store_id: "s",
      endpoint: "http://127.0.0.1:9",
      bucket: "bucket-1",
      region: "us-east-1",
      credentials: fn -> :x end
    ]

    assert {:ok, _} = OS.new(base)

    for {k, v} <- [
          store_id: "",
          endpoint: "http://u:p@host",
          endpoint: "http://h/x",
          endpoint: "ftp://h",
          bucket: "Bad_Bucket",
          bucket: "ab",
          credentials: "literal-secret",
          max_object_bytes: 5 * 1024 * 1024 * 1024 + 1,
          max_page_size: 1001,
          default_page_size: 0,
          presign_max_s: 604_801,
          presign_default_s: 0,
          default_deadline_ms: 4_294_967_296
        ] do
      assert {:error, {:invalid_config, ^k}} = OS.new(Keyword.put(base, k, v))
    end

    assert {:error, {:invalid_config, :unknown_option}} = OS.new(Keyword.put(base, :secret, "x"))
    assert {:error, {:invalid_config, :bucket}} = OS.new(Keyword.delete(base, :bucket))
    assert inspect(c) =~ "credentials=redacted"

    assert {:ok, _} =
             OS.new(
               Keyword.merge(base,
                 max_page_size: 10,
                 default_page_size: 10,
                 presign_max_s: 60,
                 presign_default_s: 60
               )
             )
  end
end
