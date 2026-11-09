# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/object_store_test_helper.exs", __DIR__)

defmodule Elzoo.ObjectStoreStubTest do
  # S13/S14 of the ELZ-053 work record: rows the real server cannot produce on demand, against a
  # loopback stub, and the delivery mapping of every row. No S3 server is needed here.
  use ExUnit.Case, async: true

  alias Elzoo.ObjectStore, as: OS
  alias Elzoo.ObjectStore.Result
  alias Elzoo.ObjectStoreTestHelper, as: H

  defp stub_reply(status, headers, body \\ "") do
    {port, ref} = H.stub({:reply, H.response(status, headers, body)})
    {H.stub_config(port), ref}
  end

  test "S13 a 200 put without the echoed checksum is unknown{unverified}, never committed" do
    {c, _} = stub_reply(200, [{"etag", "\"abc\""}])
    assert %{status: :unknown, reason: :unverified} = OS.put(c, "k", "v")

    {c, _} = stub_reply(200, [{"x-amz-checksum-sha256", Base.encode64(H.sha("other"))}])
    assert %{status: :unknown, reason: :unverified} = OS.put(c, "k", "v")

    {c, _} =
      stub_reply(200, [{"x-amz-checksum-sha256", Base.encode64(H.sha("v"))}, {"etag", "\"e\""}])

    assert %{status: :committed, etag: "e", bytes: 1} = OS.put(c, "k", "v")
  end

  test "S13 5xx is unknown{server_error}; unexpected statuses are unknown{unexpected}" do
    {c, _} = stub_reply(500, [], "<Error><Code>InternalError</Code></Error>")
    assert %{status: :unknown, reason: :server_error} = OS.put(c, "k", "v")
    {c, _} = stub_reply(500, [])
    assert %{status: :unknown, reason: :server_error} = OS.get(c, "k")
    {c, _} = stub_reply(301, [{"location", "http://elsewhere/"}])
    assert %{status: :unknown, reason: :unexpected} = OS.get(c, "k")
    {c, _} = stub_reply(404, [], "<Error><Code>NoSuchKey</Code></Error>")
    assert %{status: :unknown, reason: :unexpected} = OS.put(c, "k", "v")
    {c, _} = stub_reply(200, [{"content-type", "application/xml"}], "<NotAList/>")
    assert %{status: :unknown} = OS.list(c, "")
  end

  test "S13 a get whose bytes do not match the stored SHA-256 is unknown{integrity}" do
    {c, _} =
      stub_reply(200, [{"x-amz-checksum-sha256", Base.encode64(H.sha("expected"))}], "tampered")

    assert %{status: :unknown, reason: :integrity} = OS.get(c, "k")
  end

  test "Devin 2: a present but malformed stored checksum is unknown{integrity}, never found" do
    for value <- ["malformed", Base.encode64("short")] do
      {c, _} = stub_reply(200, [{"x-amz-checksum-sha256", value}], "changed")
      assert %{status: :unknown, reason: :integrity} = OS.get(c, "k")
      {c, _} = stub_reply(200, [{"x-amz-checksum-sha256", value}])
      assert %{status: :unknown, reason: :integrity} = OS.head(c, "k")
      {c, _} = stub_reply(200, [{"x-amz-checksum-sha256", value}])
      assert %{status: :unknown, reason: :integrity} = OS.reconcile_put(c, "k", H.sha("changed"))
    end

    {c, _} = stub_reply(200, [], "no checksum stored")
    assert %{status: :found, metadata: %{sha256: nil}} = OS.get(c, "k")
  end

  test "Devin 3: a put poll with a matching checksum but another stored size stays pending" do
    data = "ab"
    sha = H.sha(data)

    {c, _} =
      stub_reply(200, [{"x-amz-checksum-sha256", Base.encode64(sha)}, {"content-length", "1"}])

    req = %{
      context: Elzoo.ObjectStore.Binding.context(c),
      key: String.duplicate("a", 64),
      attempt_id: "attempt-1",
      arguments: Elzoo.ObjectStore.Binding.arguments(:put, key: "k", sha256: sha, bytes: 2)
    }

    assert {:pending, %{"observation" => "size_mismatch"} = ev} =
             Elzoo.ObjectStore.Binding.Put.poll(req)

    assert :ok = Elzoo.ObjectStore.Binding.Put.authenticate({:pending, ev}, req)

    {c, _} =
      stub_reply(200, [{"x-amz-checksum-sha256", Base.encode64(sha)}, {"content-length", "2"}])

    assert %{"outcome" => "completed", "value" => %{"bytes" => 2}} =
             Elzoo.ObjectStore.Binding.Put.poll(%{
               req
               | context: Elzoo.ObjectStore.Binding.context(c)
             })
  end

  test "S13 connection refused is unknown{transport}; a silent server is unknown{deadline}" do
    c = H.stub_config(H.closed_port())
    assert %{status: :unknown, reason: :transport} = OS.put(c, "k", "v", deadline_ms: 2_000)

    {port, _} = H.stub(:silent)
    c = H.stub_config(port)
    started = System.monotonic_time(:millisecond)
    assert %{status: :unknown, reason: :deadline} = OS.put(c, "k", "v", deadline_ms: 300)
    assert System.monotonic_time(:millisecond) - started < 2_000
    {port, _} = H.stub(:silent)

    assert %{status: :unknown, reason: :deadline} =
             OS.get(H.stub_config(port), "k", deadline_ms: 300)
  end

  test "R4: a HEAD 404 without an error code is disambiguated by one bucket HEAD" do
    # The one-shot stub answers 404 to every connection: the bucket HEAD is 404 as well.
    {c, ref} = stub_reply(404, [])
    assert %{status: :refused, reason: :no_such_bucket} = OS.head(c, "k")
    assert_received {:stub_connection, ^ref}
    assert_received {:stub_connection, ^ref}

    {c, _} = stub_reply(404, [{"x-minio-error-code", "NoSuchKey"}])
    assert %{status: :absent} = OS.head(c, "k")
  end

  test "local refusals open no connection (attested no-send)" do
    {port, ref} = H.stub(:silent)
    c = H.stub_config(port, max_object_bytes: 4)

    results = [
      OS.put(c, "k", "12345"),
      OS.put(c, "k", {:stream, ["1"], 5}, content_sha256: H.sha("1")),
      OS.put(c, "k", "v", content_sha256: H.sha("other")),
      OS.put(c, "k", {:stream, ["v"], 1}),
      OS.put(c, "a//b", "v"),
      OS.put(c, "k", "v", deadline_ms: 0),
      OS.put(c, "k", "v", content_type: "bad\ntype"),
      OS.put(c, "k", "v", if_absent: 1),
      OS.put(c, "k", "v", if_absent: "true"),
      OS.list(c, "", page_size: 1001),
      OS.list(c, "", continuation: ""),
      OS.get(c, "", []),
      OS.reconcile_put(c, "k", "short"),
      OS.put(H.stub_config(port, credentials: fn -> {:ok, %{}} end), "k", "v"),
      OS.put(H.stub_config(port, credentials: fn -> exit(:boom) end), "k", "v"),
      OS.put(H.stub_config(port, credentials: fn -> throw(:boom) end), "k", "v")
    ]

    for r <- results do
      assert %{status: :refused, origin: :local} = r
      assert {"rejected", "not_dispatched", _} = Result.failure(r)
    end

    assert Enum.map(results, & &1.reason) ==
             ~w(too_large too_large checksum_mismatch invalid_request invalid_key invalid_request invalid_request invalid_request invalid_request invalid_request invalid_request invalid_key invalid_request credentials_unavailable credentials_unavailable credentials_unavailable)a

    refute_received {:stub_connection, ^ref}
  end

  test "S14 every row maps to a valid ELZ-011 delivery result" do
    base = %{operation: :put, store: "s", bucket: "b", key: "k"}

    rows =
      [
        Map.merge(base, %{status: :committed, etag: "e", bytes: 1, sha256: "ab"}),
        Map.merge(base, %{status: :committed, etag: nil, bytes: 0, sha256: nil}),
        Map.merge(base, %{
          status: :found,
          body: "secret body",
          metadata: %{etag: "e", size: 1, content_type: "t", last_modified: "x", sha256: nil}
        }),
        Map.put(base, :status, :absent),
        %{
          operation: :list,
          store: "s",
          bucket: "b",
          prefix: "p",
          status: :listed,
          keys: ["p/a"],
          truncated: true,
          continuation: "t"
        }
      ] ++
        for(
          r <- Result.refusal_reasons(),
          o <- [:local, :provider, :adapter],
          valid_refusal?(r, o),
          do: Result.refused(base, r, o)
        ) ++
        for(r <- Result.unknown_reasons(), do: Result.unknown(base, r))

    expected = fn
      %{status: s} when s in [:committed, :found, :absent, :listed] ->
        {"completed", "dispatched"}

      %{status: :refused, reason: :credentials_unavailable} ->
        {"rejected", "not_dispatched"}

      %{status: :refused, origin: :local} ->
        {"rejected", "not_dispatched"}

      %{status: :refused} ->
        {"failed", "dispatched"}

      %{status: :unknown, reason: :deadline} ->
        {"timed_out", "unknown"}

      %{status: :unknown, reason: r} when r in [:transport, :adapter_error] ->
        {"unknown", "unknown"}

      %{status: :unknown} ->
        {"unknown", "dispatched"}
    end

    for row <- rows do
      assert {:ok, env, ^row} =
               OS.to_delivery_result(row, %{
                 "message_id" => "m",
                 "attempt_id" => "a",
                 "deadline_unix_ms" => 9
               })

      assert {env["outcome"], env["dispatch"]} == expected.(row)
      assert env["correlation_id"] == "m"
      refute inspect(env) =~ "secret body"
      assert {:ok, _} = Elzoo.Envelope.validate_result(env)
    end

    assert {:error, :missing_message_id} = OS.to_delivery_result(hd(rows), %{})
    assert_raise FunctionClauseError, fn -> Result.refused(base, :invalid_request, :provider) end
    assert_raise FunctionClauseError, fn -> apply(Result, :unknown, [base, :absent]) end
  end

  defp valid_refusal?(r, o),
    do: not (r in [:invalid_request, :credentials_unavailable] and o != :local)
end
