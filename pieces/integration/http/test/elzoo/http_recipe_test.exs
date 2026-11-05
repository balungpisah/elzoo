# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.HttpRecipeTest do
  use ExUnit.Case, async: true

  defmodule TimeoutAdapter do
    def run(request), do: {request, %Req.TransportError{reason: :timeout}}
  end

  test "Req sends a real local request and returns the declared response" do
    {url, server} = serve(200, ~s({"accepted":true}))

    assert {:ok, %Req.Response{status: 200, body: ~s({"accepted":true})}} =
             Req.get(url, retry: false, redirect: false, decode_body: false, receive_timeout: 1000)

    assert Task.await(server) =~ "GET / HTTP/1.1"
  end

  test "HTTP errors remain responses; transport failures remain explicit errors" do
    {url, server} = serve(503, "unavailable")

    assert {:ok, %Req.Response{status: 503, body: "unavailable"}} =
             Req.get(url, retry: false, redirect: false, decode_body: false)

    Task.await(server)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Req.get("http://example.invalid", adapter: TimeoutAdapter, retry: false)
  end

  defp serve(status, body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        try do
          {:ok, socket} = :gen_tcp.accept(listener, 5000)

          try do
            request = headers(socket, "")

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 #{status} Test\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
              )

            request
          after
            :gen_tcp.close(socket)
          end
        after
          :gen_tcp.close(listener)
        end
      end)

    {"http://127.0.0.1:#{port}/", server}
  end

  defp headers(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 5000)
      headers(socket, buffer <> chunk)
    end
  end
end
