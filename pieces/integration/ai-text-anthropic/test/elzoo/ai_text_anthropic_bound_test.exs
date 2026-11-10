# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/ai_text_anthropic_test_helper.exs", __DIR__)

defmodule Elzoo.AiText.AnthropicBoundTest do
  use ExUnit.Case, async: false
  alias Elzoo.AiText.{Anthropic, AnthropicStub, Conformance}
  @cap 4_194_304

  # Chunked HTTP with a withheld terminal marker: completion is under test control,
  # so early return cannot be explained by the server having finished its body.
  defp server(body, status \\ 200, headers \\ []) do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5000)
        send(parent, {:request, self()})
        extra = Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 #{status} Stub\r\nTransfer-Encoding: chunked\r\n",
            extra,
            "\r\n"
          ])

        # Once the collector refuses, closing the socket is expected; the
        # callback measurement, rather than socket send counts, is the evidence.
        result =
          :gen_tcp.send(socket, [Integer.to_string(byte_size(body), 16), "\r\n", body, "\r\n"])

        true = result in [:ok, {:error, :closed}, {:error, :econnreset}]
        send(parent, {:body_offered, self()})

        receive do
          :finish -> :gen_tcp.send(socket, "0\r\n\r\n")
        after
          10_000 -> :ok
        end

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {pid, "http://127.0.0.1:#{port}"}
  end

  defp translated(url) do
    {:ok, t} = Anthropic.translate(Conformance.request(:text_completion, "claude-sonnet-4-5"), nil)
    # Exercise the real provider pipeline against loopback without weakening the
    # public construction-time HTTPS validator or making a live provider call.
    %{t | config: %{base_url: url}}
  end

  defp call(t), do: Anthropic.call(t, %{credential: "stub-key", receive_timeout_ms: 5000})

  test "collector counts actual received bytes and stops before body completion" do
    {server, url} = server(:binary.copy("x", @cap + 65_536))
    parent = self()

    collector = fn {:data, data} = event, {_, response} = pair ->
      prior = Process.get(:received, 0)
      Process.put(:received, prior + byte_size(data))
      result = Anthropic.bounded(event, pair)

      if elem(result, 0) == :halt do
        send(
          parent,
          {:measured, prior + byte_size(data), byte_size(data), byte_size(response.body)}
        )
      end

      result
    end

    task = Task.async(fn -> Req.get!(url, into: collector, retry: false) end)
    assert_receive {:request, ^server}, 5000
    assert_receive {:body_offered, ^server}, 5000
    assert_receive {:measured, consumed, last_chunk, retained}, 5000
    assert consumed > @cap
    assert consumed <= @cap + last_chunk
    assert retained <= @cap
    response = Task.await(task, 5000)
    assert response.private.elzoo_oversize
    assert response.body == ""
    send(server, :finish)
  end

  test "disabled collector negative control waits for the withheld marker" do
    body = :binary.copy("x", @cap + 65_536)
    {server, url} = server(body)
    task = Task.async(fn -> Req.get!(url, retry: false) end)
    assert_receive {:request, ^server}, 5000
    assert_receive {:body_offered, ^server}, 5000
    assert Task.yield(task, 100) == nil
    send(server, :finish)
    assert Task.await(task, 5000).body == body
  end

  test "provider wiring returns oversized success before the server completes" do
    {server, url} = server(:binary.copy("x", @cap + 65_536))
    task = Task.async(fn -> call(translated(url)) end)
    assert_receive {:request, ^server}, 5000
    assert_receive {:body_offered, ^server}, 5000
    assert {:ok, raw} = Task.await(task, 5000)
    assert raw.body == nil

    assert Anthropic.decode(raw, Conformance.request(:text_completion, "claude-sonnet-4-5")) ==
             {:failure, :malformed_response}

    refute_receive {:request, _}, 100
    send(server, :finish)
  end

  test "exact cap and one byte below preserve documented decoded replies" do
    request = Conformance.request(:text_completion, "claude-sonnet-4-5")
    json = Jason.encode!(AnthropicStub.message([AnthropicStub.text("ok")], "end_turn"))

    for size <- [@cap - 1, @cap] do
      body = json <> :binary.copy(" ", size - byte_size(json))
      {agent, plug} = AnthropicStub.start(fn _ -> {200, [], body} end)
      {:ok, t} = Anthropic.translate(request, %{plug: plug})
      assert {:ok, raw} = call(t)
      assert raw.body == body
      assert {:ok, %{content: "ok"}} = Anthropic.decode(raw, request)
      assert length(AnthropicStub.requests(agent)) == 1
    end
  end

  test "oversized errors preserve status fallback and retry metadata" do
    request = Conformance.request(:text_completion, "claude-sonnet-4-5")
    json = Jason.encode!(AnthropicStub.error("timeout_error"))
    body = json <> :binary.copy(" ", @cap + 1 - byte_size(json))

    for {status, outcome} <- [
          {400, {:failure, :provider_invalid_request}},
          {429, {:failure, :throttled, %{retry_after: 7}}},
          {500, {:failure, :provider_error}},
          {529, {:failure, :overloaded, %{retry_after: 7}}}
        ] do
      {agent, plug} = AnthropicStub.start(fn _ -> {status, [{"retry-after", "7"}], body} end)
      {:ok, t} = Anthropic.translate(request, %{plug: plug})
      assert {:ok, raw} = call(t)
      assert raw.body == nil
      assert Anthropic.decode(raw, request) == outcome
      assert length(AnthropicStub.requests(agent)) == 1
    end
  end

  test "content encoded bodies retain raw capture semantics" do
    request = Conformance.request(:text_completion, "claude-sonnet-4-5")
    body = :zlib.gzip(Jason.encode!(AnthropicStub.message([AnthropicStub.text("ok")], "end_turn")))

    for {status, outcome} <- [
          {200, {:failure, :malformed_response}},
          {429, {:failure, :throttled, %{retry_after: 7}}}
        ] do
      {agent, plug} =
        AnthropicStub.start(fn _ ->
          {status, [{"content-encoding", "gzip"}, {"retry-after", "7"}], body}
        end)

      {:ok, t} = Anthropic.translate(request, %{plug: plug})
      assert {:ok, raw} = call(t)
      assert raw.body == body
      assert Anthropic.decode(raw, request) == outcome
      assert length(AnthropicStub.requests(agent)) == 1
    end
  end
end
