# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ProviderStream.Peer do
  @moduledoc false
  # A Piece-local loopback peer over real HTTP/1.1. It reports each request to
  # the test, lets `respond` write the response, then reports what it sees from
  # the client: `{:error, :closed}` when the client closed the connection.
  def start(respond) do
    parent = self()
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)
    origin = "http://127.0.0.1:#{port}"
    pid = spawn_link(fn -> accept(l, parent, origin, respond) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(l)
    end)

    origin
  end

  # Each message carries the origin, so a test reads the peer it means.
  defp accept(l, parent, origin, respond) do
    {:ok, s} = :gen_tcp.accept(l)
    {:ok, raw} = read_head(s, "")
    [head, tail] = :binary.split(raw, "\r\n\r\n")
    [_, n] = Regex.run(~r/\r\ncontent-length: ([0-9]+)/i, head)
    {:ok, body} = read_body(s, tail, String.to_integer(n))
    send(parent, {:request, origin, head, body})
    respond.(s)
    send(parent, {:peer_close, origin, :gen_tcp.recv(s, 0, 10_000)})
    :gen_tcp.close(s)
    accept(l, parent, origin, respond)
  end

  defp read_head(s, acc) do
    if String.contains?(acc, "\r\n\r\n"),
      do: {:ok, acc},
      else: with({:ok, b} <- :gen_tcp.recv(s, 0, 5_000), do: read_head(s, acc <> b))
  end

  defp read_body(_s, b, n) when byte_size(b) >= n, do: {:ok, binary_part(b, 0, n)}

  defp read_body(s, b, n),
    do: with({:ok, rest} <- :gen_tcp.recv(s, n - byte_size(b), 5_000), do: {:ok, b <> rest})

  def head(s, status \\ 200) do
    :ok =
      :gen_tcp.send(
        s,
        "HTTP/1.1 #{status} Test\r\ncontent-type: text/event-stream\r\n" <>
          "request-id: req_loopback_1\r\ntransfer-encoding: chunked\r\n\r\n"
      )
  end

  def chunk(s, bytes),
    do: :gen_tcp.send(s, Integer.to_string(byte_size(bytes), 16) <> "\r\n" <> bytes <> "\r\n")

  def finish(s), do: :gen_tcp.send(s, "0\r\n\r\n")
end

defmodule Elzoo.ProviderStream.Fixture do
  @moduledoc false
  alias Elzoo.ProviderStream.Peer

  @dir Path.expand("../fixtures/openrouter-anthropic", __DIR__)

  def read(name), do: File.read!(Path.join(@dir, name))

  # The recorded request body as sent, without the member that pinned the route.
  def upstream(name),
    do: read(name <> ".upstream.json") |> Jason.decode!() |> Map.delete("provider")

  def settings(extra \\ []) do
    parent = self()

    Keyword.merge(
      [
        credentials: fn ->
          send(parent, :credentials_read)
          {:ok, "test-key"}
        end,
        models: ["claude-haiku-5-5"],
        total_timeout_ms: 5_000,
        receive_timeout_ms: 2_000,
        ack_timeout_ms: 1_000,
        max_result_bytes: 1_048_576
      ],
      extra
    )
  end

  # A sink that acknowledges each frame at once.
  def acking_sink do
    parent = self()

    fn frame ->
      send(parent, {:offered, frame})
      {:ack, frame.callback_ref, frame.seq}
    end
  end

  # A sink that holds each frame until the test releases it.
  def holding_sink do
    parent = self()

    fn frame ->
      send(parent, {:held, frame, self()})

      receive do
        :release -> {:ack, frame.callback_ref, frame.seq}
      end
    end
  end

  # Releases n held frames one by one. While a frame is held, no other frame
  # may be offered within `window.(frame)` milliseconds.
  def release(0, _window), do: []

  def release(n, window) do
    receive do
      {:held, frame, pid} ->
        receive do
          {:held, other, _} -> raise "frame #{other.seq} offered while #{frame.seq} was held"
        after
          window.(frame) -> send(pid, :release)
        end

        [frame | release(n - 1, window)]
    after
      2_000 -> raise "frame missing"
    end
  end

  def run(payload, sink, settings, origin) do
    Task.async(fn ->
      Elzoo.ProviderStream.run(payload, sink, settings, {:loopback, origin, nil})
    end)
  end

  # The whole recorded stream as one chunk, then the end of the body.
  def whole(bytes) do
    fn s ->
      Peer.head(s)
      Peer.chunk(s, bytes)
      Peer.finish(s)
    end
  end

  # The bytes, then the response stays open: only the client can close it.
  def open(bytes) do
    fn s ->
      Peer.head(s)
      Peer.chunk(s, bytes)
    end
  end

  def offered do
    receive do
      {:offered, frame} -> [frame | offered()]
    after
      0 -> []
    end
  end

  # The raw bytes up to and including the n-th event block of `type`.
  def through(bytes, type, n) do
    blocks = String.split(bytes, "\n\n", trim: true)

    {kept, _} =
      Enum.reduce_while(blocks, {[], 0}, fn b, {acc, seen} ->
        seen = if String.contains?(b, ~s("type":"#{type}")), do: seen + 1, else: seen
        if seen == n, do: {:halt, {[b | acc], seen}}, else: {:cont, {[b | acc], seen}}
      end)

    kept |> Enum.reverse() |> Enum.map_join(&(&1 <> "\n\n"))
  end
end
