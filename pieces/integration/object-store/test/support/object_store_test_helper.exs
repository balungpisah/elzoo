# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ObjectStoreTestHelper do
  @moduledoc """
  Test binding for `integration/object-store`. The MinIO tests fail closed: without every
  `ELZOO_TEST_S3_*` variable (the disposable server of scripts/ci-minio.py, ELZ-064) they raise,
  never skip. The credential Need of the test reads those variables; the Piece itself never
  reads the environment. A loopback stub covers rows the real server cannot produce on demand.
  """

  @vars ~w(ELZOO_TEST_S3_URL ELZOO_TEST_S3_BUCKET ELZOO_TEST_S3_ACCESS_KEY_ID ELZOO_TEST_S3_SECRET_ACCESS_KEY ELZOO_TEST_S3_REGION)

  def vars, do: @vars

  @doc "The disposable server's settings, or a raise naming the missing variable (fail closed)."
  def env! do
    Map.new(@vars, fn name ->
      case System.get_env(name) do
        v when is_binary(v) and v != "" ->
          {name, v}

        _ ->
          raise "#{name} is required: the object-store tests fail closed against the disposable " <>
                  "S3 server (scripts/ci-minio.py, ELZ-064); they are never skipped"
      end
    end)
  end

  def secret!, do: env!()["ELZOO_TEST_S3_SECRET_ACCESS_KEY"]
  def access_key!, do: env!()["ELZOO_TEST_S3_ACCESS_KEY_ID"]

  @doc "The test's credential Need (an MFA reference; the values never enter the Config)."
  def credentials do
    e = env!()

    {:ok,
     %{
       access_key_id: e["ELZOO_TEST_S3_ACCESS_KEY_ID"],
       secret_access_key: e["ELZOO_TEST_S3_SECRET_ACCESS_KEY"]
     }}
  end

  def wrong_credentials do
    {:ok, %{access_key_id: access_key!(), secret_access_key: "wrong-" <> secret!()}}
  end

  def config!(overrides \\ []) do
    e = env!()

    {:ok, c} =
      Elzoo.ObjectStore.new(
        Keyword.merge(
          [
            store_id: "test-minio",
            endpoint: e["ELZOO_TEST_S3_URL"],
            bucket: e["ELZOO_TEST_S3_BUCKET"],
            region: e["ELZOO_TEST_S3_REGION"],
            credentials: {__MODULE__, :credentials, []}
          ],
          overrides
        )
      )

    c
  end

  def prefix, do: "elz053-#{System.unique_integer([:positive])}-#{System.os_time(:millisecond)}"

  def sha(data), do: :crypto.hash(:sha256, data)

  @doc "Assert that `term` (inspected without limits) contains none of `needles`."
  def free_of?(term, needles) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity, structs: true)
    raw = inspect(term, limit: :infinity, printable_limit: :infinity, structs: false)
    Enum.all?(needles, &(not String.contains?(text, &1) and not String.contains?(raw, &1)))
  end

  # ---- loopback stub

  @doc """
  Start a one-shot loopback server. `mode`:
  `{:reply, raw_response}` reads the request head (and the declared body) and answers;
  `:silent` reads and never answers; `{:proxy, port, cut_after}` forwards the first
  `cut_after` request bytes to `127.0.0.1:port`, then closes both sides.
  Every accepted connection is reported to `owner` as `{:stub_connection, ref}`.
  Returns `{port, ref}`.
  """
  def stub(mode, owner \\ self()) do
    ref = make_ref()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      accept_loop(listen, mode, owner, ref)
    end)
    |> then(&:gen_tcp.controlling_process(listen, &1))

    {port, ref}
  end

  defp accept_loop(listen, mode, owner, ref) do
    case :gen_tcp.accept(listen, 30_000) do
      {:ok, socket} ->
        send(owner, {:stub_connection, ref})
        spawn(fn -> serve(socket, mode) end) |> then(&:gen_tcp.controlling_process(socket, &1))
        accept_loop(listen, mode, owner, ref)

      _ ->
        :gen_tcp.close(listen)
    end
  end

  defp serve(socket, {:reply, response}) do
    _ = read_request(socket)
    :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp serve(socket, :silent) do
    _ = read_request(socket)
    Process.sleep(60_000)
    :gen_tcp.close(socket)
  end

  defp serve(socket, {:proxy, port, cut_after}) do
    {:ok, upstream} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    forward(socket, upstream, cut_after)
    :gen_tcp.close(upstream)
    :gen_tcp.close(socket)
  end

  defp forward(_from, _to, left) when left <= 0, do: :ok

  defp forward(from, to, left) do
    case :gen_tcp.recv(from, 0, 10_000) do
      {:ok, data} ->
        chunk = binary_part(data, 0, min(byte_size(data), left))
        :ok = :gen_tcp.send(to, chunk)
        forward(from, to, left - byte_size(chunk))

      _ ->
        :ok
    end
  end

  defp read_request(socket, acc \\ "") do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        length =
          case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        read_body(socket, byte_size(body), length)

      [_] ->
        case :gen_tcp.recv(socket, 0, 10_000) do
          {:ok, data} -> read_request(socket, acc <> data)
          _ -> :ok
        end
    end
  end

  defp read_body(_socket, have, want) when have >= want, do: :ok

  defp read_body(socket, have, want) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, data} -> read_body(socket, have + byte_size(data), want)
      _ -> :ok
    end
  end

  @doc "A raw HTTP/1.1 response; a `content-length` given in `headers` replaces the computed one."
  def response(status, headers, body \\ "") do
    reason = %{200 => "OK", 204 => "No Content", 404 => "Not Found", 500 => "Internal Server Error"}
    head = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

    "HTTP/1.1 #{status} #{Map.get(reason, status, "Status")}\r\n" <>
      head <>
      if(List.keymember?(headers, "content-length", 0),
        do: "",
        else: "content-length: #{byte_size(body)}\r\n"
      ) <> "connection: close\r\n\r\n" <> body
  end

  @doc "A config pointing at a loopback stub (fake credential; never the test server's)."
  def stub_config(port, overrides \\ []) do
    {:ok, c} =
      Elzoo.ObjectStore.new(
        Keyword.merge(
          [
            store_id: "stub",
            endpoint: "http://127.0.0.1:#{port}",
            bucket: "stub-bucket",
            region: "us-east-1",
            credentials: fn ->
              {:ok, %{access_key_id: "STUBKEYID", secret_access_key: "stub-secret-value"}}
            end
          ],
          overrides
        )
      )

    c
  end

  @doc "A loopback port with nothing listening (bound, then closed)."
  def closed_port do
    {:ok, s} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(s)
    :gen_tcp.close(s)
    port
  end
end
