# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.TestBinding do
  use Elzoo.DataStream.Binding, id: "stream-test", provider_account: "workspace-test"
end

defmodule Elzoo.DataStream.Fixture do
  alias Elzoo.DataStream.{JSON, TestBinding}

  def effect(overrides \\ %{}, payload \\ %{}) do
    %{
      "capability_id" => "delivery/data-stream",
      "operation" => "generate_stream",
      "classification" => "untrusted",
      "command" =>
        Map.merge(
          %{
            "version" => 1,
            "message_id" => "message-1",
            "schema_id" => "elzoo/anthropic-text-stream-request",
            "schema_version" => 1,
            "kind" => "command",
            "producer" => %{"unit_id" => "research", "port_id" => "text"},
            "payload" =>
              JSON.encode(
                Map.merge(
                  %{
                    "model" => "claude-sonnet-5",
                    "messages" => [%{"role" => "user", "content" => "private prompt"}],
                    "max_tokens" => 32
                  },
                  payload
                )
              ),
            "idempotency_key" => "logical-1",
            "deadline_unix_ms" => System.system_time(:millisecond) + 60_000
          },
          overrides
        )
    }
  end

  def settings(extra \\ []) do
    {:ok, pid} =
      Elzoo.DurableLog.Memory.start_link(
        fold: Elzoo.EffectIntent.fold(TestBinding),
        limits: Elzoo.EffectIntent.limits()
      )

    store = Elzoo.DurableLog.Memory.store(pid)

    {:ok, host_pid} =
      Elzoo.DurableLog.Memory.start_link(
        fold: Elzoo.EffectIntent.StoreHost.fold(),
        limits: Elzoo.EffectIntent.StoreHost.limits()
      )

    host =
      {Elzoo.EffectIntent.StoreHost,
       %{store: Elzoo.DurableLog.Memory.store(host_pid), authorize: fn _, _ -> :fresh end}}

    Keyword.merge(
      [
        tenant: "tenant-test",
        binding: TestBinding,
        store: store,
        host: host,
        allow_volatile: true,
        credentials: fn -> {:ok, "test-key"} end,
        models: ["claude-sonnet-5"],
        total_timeout_ms: 3_000,
        receive_timeout_ms: 1_000,
        ack_timeout_ms: 500
      ],
      extra
    )
  end

  def start(usage \\ %{"input_tokens" => 2, "output_tokens" => 2}) do
    %{
      "type" => "message_start",
      "message" => %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-5",
        "content" => [],
        "stop_reason" => nil,
        "stop_sequence" => nil,
        "usage" => usage
      }
    }
  end

  def delta(usage \\ %{"output_tokens" => 5}, finish \\ "end_turn"),
    do: %{"type" => "message_delta", "delta" => %{"stop_reason" => finish}, "usage" => usage}

  def stop, do: %{"type" => "message_stop"}

  def text(text \\ "private output"),
    do: [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => 0}
    ]

  def wire(events),
    do:
      Enum.map_join(events, fn m ->
        "event: " <> m["type"] <> "\ndata: " <> JSON.encode(m) <> "\n\n"
      end)

  def complete, do: wire([start()] ++ text() ++ [delta(), stop()])
  def ack(frame), do: {:ack, frame.callback_ref, frame.seq}

  def terminal(handle, timeout \\ 4_000) do
    receive do
      {:data_stream_terminal, ref, t} when ref == handle.ref -> t
    after
      timeout -> raise "terminal notification missing"
    end
  end
end

defmodule Elzoo.DataStream.Peer do
  @moduledoc false
  # One owned acceptor and its accepted socket per fixture. Leaving a chunked
  # response unfinished distinguishes local read halt from normal EOF reuse.
  def start(parent, respond, tls \\ nil) do
    {mod, listener} =
      case tls do
        nil ->
          {:ok, l} =
            :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

          {:gen_tcp, l}

        {cert, key} ->
          {:ok, _} = Application.ensure_all_started(:ssl)

          {:ok, l} =
            :ssl.listen(0, [
              :binary,
              active: false,
              reuseaddr: true,
              ip: {127, 0, 0, 1},
              certfile: String.to_charlist(cert),
              keyfile: String.to_charlist(key),
              alpn_preferred_protocols: ["h2", "http/1.1"]
            ])

          {:ssl, l}
      end

    {:ok, {_, port}} = if mod == :ssl, do: :ssl.sockname(listener), else: :inet.sockname(listener)
    id = make_ref()
    pid = spawn_link(fn -> accept(mod, listener, parent, id, respond) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
      apply(mod, :close, [listener])
    end)

    origin = if mod == :ssl, do: "https://localhost:#{port}", else: "http://127.0.0.1:#{port}"
    %{pid: pid, id: id, origin: origin}
  end

  defp accept(mod, l, parent, id, respond) do
    case connection(mod, l) do
      {:ok, socket} ->
        {:ok, raw} = read_headers(mod, socket, "")
        [headers, tail] = :binary.split(raw, "\r\n\r\n")

        size =
          case Regex.run(~r/\r\ncontent-length: ([0-9]+)/i, headers) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        {:ok, body} = read_body(mod, socket, tail, size)
        send(parent, {:stream_request, id, self(), headers, body})
        if mod == :ssl, do: send(parent, {:alpn, id, :ssl.negotiated_protocol(socket)})
        respond.(mod, socket)
        result = apply(mod, :recv, [socket, 0, 3_000])
        send(parent, {:peer_close, id, result})
        apply(mod, :close, [socket])
        accept(mod, l, parent, id, respond)

      _ ->
        :ok
    end
  end

  defp connection(:gen_tcp, l), do: :gen_tcp.accept(l)

  defp connection(:ssl, l) do
    with {:ok, s} <- :ssl.transport_accept(l), do: :ssl.handshake(s, 3_000)
  end

  defp read_headers(mod, s, acc) do
    if String.contains?(acc, "\r\n\r\n"),
      do: {:ok, acc},
      else: with({:ok, b} <- apply(mod, :recv, [s, 0, 3_000]), do: read_headers(mod, s, acc <> b))
  end

  defp read_body(_mod, _s, b, n) when byte_size(b) >= n, do: {:ok, binary_part(b, 0, n)}

  defp read_body(mod, s, b, n),
    do: with({:ok, rest} <- apply(mod, :recv, [s, n - byte_size(b), 3_000]), do: {:ok, b <> rest})

  def response(mod, s, body, status \\ 200, headers \\ [{"content-type", "text/event-stream"}]) do
    lines = Enum.map_join(headers, fn {k, v} -> k <> ": " <> v <> "\r\n" end)

    :ok =
      apply(mod, :send, [
        s,
        "HTTP/1.1 #{status} Test\r\n" <> lines <> "transfer-encoding: chunked\r\n\r\n"
      ])

    if body != "", do: chunk(mod, s, body)
    :ok
  end

  def chunk(mod, s, body),
    do: apply(mod, :send, [s, Integer.to_string(byte_size(body), 16) <> "\r\n" <> body <> "\r\n"])
end
