# SPDX-License-Identifier: Apache-2.0
# Reduced proposal probe only: this is not a production Adapter or a rearm law.
ExUnit.start(seed: 0)

defmodule Elz011Probe do
  @limit 1024
  def limit, do: @limit

  def normalize(map) when is_map(map) do
    with 1 <- map["version"],
         key when is_binary(key) <- map["key"],
         true <- byte_size(key) in 1..128 and String.valid?(key),
         digest when is_binary(digest) <- map["digest"],
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         kind when is_binary(kind) <- map["kind"],
         true <- byte_size(kind) in 1..64 and String.valid?(kind),
         ack when is_boolean(ack) <- map["ack"] do
      {:ok,
       %{
         "version" => 1,
         "key" => key,
         "digest" => digest,
         "kind" => kind,
         "kind_class" => if(kind == "publication", do: "known", else: "opaque"),
         "ack" => ack,
         "trust" => "untrusted"
       }}
    else
      _ -> {:error, :receipt_schema}
    end
  end

  def normalize(_), do: {:error, :receipt_schema}

  def request(provider, url, body, timeout \\ 500)

  def request(:req, url, body, timeout) do
    Req.request(
      url: url,
      method: :put,
      body: body,
      headers: [{"content-type", "application/json"}],
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      raw: true,
      receive_timeout: timeout,
      connect_options: [timeout: timeout],
      into: fn {:data, chunk}, {req, resp} ->
        if byte_size(resp.body) + byte_size(chunk) <= @limit,
          do: {:cont, {req, %{resp | body: resp.body <> chunk}}},
          else: {:halt, {req, %{resp | body: :over_limit}}}
      end
    )
    |> case do
      {:ok, %{body: :over_limit}} -> {:error, :body_limit}
      {:ok, %{status: s, body: b}} -> {:ok, s, b}
      {:error, _} -> {:error, :transport}
    end
  end

  def request(:finch, url, body, timeout) do
    Finch.build(:put, url, [{"content-type", "application/json"}], body)
    |> Finch.stream_while(
      Elz011Probe.Finch,
      %{status: nil, body: "", over: false},
      fn
        {:status, status}, acc ->
          {:cont, %{acc | status: status}}

        {:data, chunk}, acc ->
          if byte_size(acc.body) + byte_size(chunk) <= @limit,
            do: {:cont, %{acc | body: acc.body <> chunk}},
            else: {:halt, %{acc | over: true}}

        _, acc ->
          {:cont, acc}
      end,
      receive_timeout: timeout
    )
    |> case do
      {:ok, %{over: true}} -> {:error, :body_limit}
      {:ok, %{status: s, body: b}} -> {:ok, s, b}
      {:error, _, _acc} -> {:error, :transport}
      {:error, _} -> {:error, :transport}
    end
  end

  # One counted wire request followed by an observation window for hidden retries.
  # A local fixture, not a real provider's idempotency/authentication implementation.
  def server(status, response, opts \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      Task.async(fn ->
        try do
          {:ok, socket} = :gen_tcp.accept(listener, 3000)
          {headers, body} = read_request(socket, "")
          send(parent, {:wire_request, self(), headers, body})

          case Keyword.get(opts, :mode, :respond) do
            :respond ->
              extra =
                if status == 307, do: "location: http://127.0.0.1:#{port}/redirected\r\n", else: ""

              :gen_tcp.send(
                socket,
                "HTTP/1.1 #{status} Test\r\n#{extra}content-type: application/json\r\ncontent-length: #{byte_size(response)}\r\nconnection: close\r\n\r\n#{response}"
              )

            :hold ->
              receive do
                :release -> :ok
              after
                1000 -> :ok
              end

            :drop_ack ->
              :ok
          end

          :gen_tcp.close(socket)

          case :gen_tcp.accept(listener, 120) do
            {:error, :timeout} ->
              1

            {:ok, duplicate} ->
              :gen_tcp.close(duplicate)
              2
          end
        after
          :gen_tcp.close(listener)
        end
      end)

    {"http://127.0.0.1:#{port}/publication", server}
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        [_, size] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
        {headers, read_body(socket, body, String.to_integer(size))}

      _ ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 3000)
        read_request(socket, bytes <> more)
    end
  end

  defp read_body(_, body, n) when byte_size(body) >= n, do: body

  defp read_body(socket, body, n) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 3000)
    read_body(socket, body <> more, n)
  end
end

defmodule Elz011BoundaryProbeTest do
  use ExUnit.Case, async: false

  setup_all do
    {:ok, _} = Application.ensure_all_started(:req)
    start_supervised!({Finch, name: Elz011Probe.Finch})
    :ok
  end

  for provider <- [:req, :finch] do
    @provider provider
    test "#{provider}: actual PUT 200/503/307 is one send and redirects/retries stay disabled" do
      for status <- [200, 503, 307] do
        {url, server} = Elz011Probe.server(status, ~s({"ack":true}))
        assert {:ok, ^status, ~s({"ack":true})} = Elz011Probe.request(@provider, url, "{}", 500)
        assert_receive {:wire_request, _, headers, "{}"}
        assert headers =~ "PUT /publication HTTP/1.1"
        assert Task.await(server) == 1
      end
    end

    test "#{provider}: callback bounds response bytes at limit and limit plus one" do
      for size <- [Elz011Probe.limit(), Elz011Probe.limit() + 1] do
        bytes = String.duplicate("x", size)
        {url, server} = Elz011Probe.server(200, bytes)
        result = Elz011Probe.request(@provider, url, "{}", 500)

        if size == Elz011Probe.limit(),
          do: assert(result == {:ok, 200, bytes}),
          else: assert(result == {:error, :body_limit})

        assert Task.await(server) == 1
      end
    end

    test "#{provider}: lost acknowledgement does not prove no dispatch or cause a hidden retry" do
      {url, server} = Elz011Probe.server(200, "", mode: :drop_ack)

      assert {:error, :transport} =
               Elz011Probe.request(@provider, url, "{\"secret\":\"value\"}", 100)

      assert_receive {:wire_request, _, _, "{\"secret\":\"value\"}"}
      assert Task.await(server) == 1
    end

    test "#{provider}: receive timeout happens after server receipt and leaves dispatch uncertain" do
      {url, server} = Elz011Probe.server(200, "", mode: :hold)
      assert {:error, :transport} = Elz011Probe.request(@provider, url, "{}", 30)
      assert_receive {:wire_request, _, _, "{}"}
      send(server.pid, :release)
      assert Task.await(server) == 1
    end

    test "#{provider}: killing local caller cannot retract a received HTTP effect" do
      {url, server} = Elz011Probe.server(200, "", mode: :hold)
      {pid, ref} = spawn_monitor(fn -> Elz011Probe.request(@provider, url, "{}", 500) end)
      assert_receive {:wire_request, _, _, "{}"}, 2000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      send(server.pid, :release)
      assert Task.await(server) == 1
    end
  end

  defp receipt,
    do: %{
      "version" => 1,
      "key" => "logical",
      "digest" => String.duplicate("a", 64),
      "kind" => "publication",
      "ack" => true
    }

  test "normalization drops unknown fields, preserves opaque kinds, and is idempotent" do
    for kind <- ["publication", "future-kind", "☃"], ack <- [true, false] do
      raw =
        Map.merge(receipt(), %{
          "kind" => kind,
          "ack" => ack,
          "secret" => "redacted",
          "trust" => "trusted"
        })

      assert {:ok, normalized} = Elz011Probe.normalize(raw)
      refute Map.has_key?(normalized, "secret")
      assert normalized["kind"] == kind
      assert normalized["trust"] == "untrusted"
      assert normalized["kind_class"] == if(kind == "publication", do: "known", else: "opaque")
      assert Elz011Probe.normalize(normalized) == {:ok, normalized}
    end
  end

  test "acknowledgement authority is rejected rather than inferred from truthy values or missing keys" do
    for value <- [nil, "true", 1, %{}, [], :true_atom] do
      assert {:error, :receipt_schema} = Elz011Probe.normalize(Map.put(receipt(), "ack", value))
    end

    assert {:error, :receipt_schema} = Elz011Probe.normalize(Map.delete(receipt(), "ack"))

    for bad <- [
          nil,
          [],
          :atom,
          "json",
          7,
          %{receipt() | "version" => 1.0},
          %{receipt() | "kind" => <<255>>}
        ] do
      assert {:error, :receipt_schema} = Elz011Probe.normalize(bad)
    end
  end

  test "wire-key normalization never interns novel keys or kinds" do
    # Second source: pluggy_ai key_transform.ex L19-L29, commit a0d334941af63a82b019a979178bd863c06d133d.
    key = "elz011_wire_#{System.unique_integer([:positive])}"
    kind = key <> "_kind"
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(kind) end

    assert {:ok, _} =
             Elz011Probe.normalize(Map.merge(receipt(), %{key => "ignored", "kind" => kind}))

    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(kind) end
  end

  test "finite negative controls expose retaining unknown fields and trusting provider claims" do
    raw = Map.merge(receipt(), %{"secret" => "redacted", "trust" => "trusted"})
    {:ok, safe} = Elz011Probe.normalize(raw)
    retain_mutant = Map.merge(raw, safe)
    trust_mutant = Map.put(safe, "trust", raw["trust"])
    refute retain_mutant == safe
    assert Map.has_key?(retain_mutant, "secret")
    refute trust_mutant["trust"] == "untrusted"
  end
end
