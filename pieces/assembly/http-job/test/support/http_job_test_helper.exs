# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.HttpJob.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.HttpJob.TestMigration do
  use Ecto.Migration

  def up do
    Oban.Migration.up(prefix: prefix())
    Elzoo.DurableLog.Postgres.Migration.up()
  end
end

defmodule Elzoo.HttpJob.TestBinding do
  # Test-only fixed descriptor per sequential fixture; production uses the macro.
  def __effect_intent_binding__, do: :persistent_term.get(__MODULE__)
end

defmodule Elzoo.HttpJob.Fixture do
  @secret "fixture-only-secret"
  def mac(v),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        @secret,
        Jason.encode!([v["key"], v["digest"], v["ack"], v["kind"], v["status"]])
      )
      |> Base.encode16(case: :lower)

  def authenticate(v, _), do: if(v["signature"] == mac(v), do: :ok, else: :error)

  def completion(key, body, attempt) do
    v = %{
      "version" => 1,
      "key" => key,
      "digest" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
      "kind" => "publication",
      "ack" => true,
      "trust" => "untrusted",
      "status" => 200
    }

    v = Map.put(v, "signature", mac(v))

    %{
      "version" => 1,
      "message_id" => key,
      "correlation_id" => key,
      "attempt_id" => key <> "/attempt/" <> Integer.to_string(attempt),
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value_schema_id" => "elzoo/publication-receipt",
      "value_schema_version" => 1,
      "value" => v
    }
  end

  def start do
    {:ok, state} = Agent.start_link(fn -> %{mode: :success, calls: [], body: nil} end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, tasks} = Task.Supervisor.start_link(max_children: 32)
    server = spawn_link(fn -> accept(listener, state, tasks) end)

    %{
      state: state,
      listener: listener,
      server: server,
      tasks: tasks,
      origin: "http://127.0.0.1:#{port}"
    }
  end

  def stop(f) do
    :gen_tcp.close(f.listener)
    Process.unlink(f.server)
    Process.exit(f.server, :kill)
    if Process.alive?(f.tasks), do: Supervisor.stop(f.tasks)
    if Process.alive?(f.state), do: Agent.stop(f.state)
  end

  def mode(f, mode), do: Agent.update(f.state, &%{&1 | mode: mode})
  def calls(f), do: Agent.get(f.state, &Enum.reverse(&1.calls))

  defp accept(l, a, tasks) do
    case :gen_tcp.accept(l) do
      {:ok, s} ->
        {:ok, pid} =
          Task.Supervisor.start_child(tasks, fn ->
            receive do
              {:socket, socket} -> serve(socket, a)
            end
          end)

        :ok = :gen_tcp.controlling_process(s, pid)
        send(pid, {:socket, s})
        accept(l, a, tasks)

      _ ->
        :ok
    end
  end

  defp read(s, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [h, b] ->
        n =
          case Regex.run(~r/content-length:\s*(\d+)/i, h) do
            [_, x] -> String.to_integer(x)
            _ -> 0
          end

        {h, body(s, b, n)}

      _ ->
        {:ok, b} = :gen_tcp.recv(s, 0, 5000)
        read(s, acc <> b)
    end
  end

  defp body(_, b, n) when byte_size(b) >= n, do: b

  defp body(s, b, n) do
    {:ok, x} = :gen_tcp.recv(s, 0, 5000)
    body(s, b <> x, n)
  end

  defp serve(s, a) do
    try do
      {headers, bytes} = read(s, "")
      [method, path | _] = String.split(hd(String.split(headers, "\r\n")), " ")
      key = List.last(String.split(path, "/"))

      state =
        Agent.get_and_update(a, fn st ->
          next = %{
            st
            | calls: [{method, path, bytes} | st.calls],
              body: if(method == "PUT", do: bytes, else: st.body)
          }

          {next, next}
        end)

      mode = state.mode

      cond do
        match?({:stream, _, _, _}, mode) ->
          {:stream, total, receiver, ref} = mode
          # Size-only fixture: a slow reader must not turn a complete mutant
          # response into a write timeout. ExUnit's watchdog still bounds hangs.
          :inet.setopts(s, sndbuf: 16384, send_timeout: :infinity)

          :gen_tcp.send(
            s,
            "HTTP/1.1 200 OK\r\ncontent-length: #{total}\r\nconnection: close\r\n\r\n"
          )

          sent = stream(s, String.duplicate("x", 65536), total, 0)
          send(receiver, {:stream_finished, ref, sent})

        mode == :drop ->
          :ok

        mode == :hold ->
          Process.sleep(5000)

        mode == :drip ->
          :gen_tcp.send(s, "HTTP/1.1 200 OK\r\ncontent-length: 80\r\nconnection: close\r\n\r\n")

          for _ <- 1..80 do
            :gen_tcp.send(s, "x")
            Process.sleep(40)
          end

        true ->
          status =
            case mode do
              :http404 -> 404
              :http503 -> 503
              :redirect -> 307
              _ -> 200
            end

          v = %{
            "version" => 1,
            "key" => key,
            "digest" => Base.encode16(:crypto.hash(:sha256, state.body || "{}"), case: :lower),
            "kind" => "publication",
            "ack" => mode != :pending,
            "status" => status
          }

          v =
            case mode do
              :badkey -> Map.put(v, "key", String.duplicate("0", 64))
              :baddigest -> Map.put(v, "digest", String.duplicate("0", 64))
              _ -> v
            end

          sig = if mode == :badmac, do: String.duplicate("0", 64), else: mac(v)
          json = Jason.encode!(Map.drop(v, ["status"]))

          json =
            case mode do
              :oversize -> String.duplicate("x", 16385)
              :duplicate -> String.replace(json, "\"ack\":true", "\"ack\":false,\"ack\":true")
              :invalid -> "no-json"
              _ -> json
            end

          extra =
            case mode do
              :redirect -> "location: /redirected\r\n"
              :encoded -> "content-encoding: gzip\r\n"
              _ -> ""
            end

          :gen_tcp.send(
            s,
            "HTTP/1.1 #{status} Test\r\n#{extra}content-length: #{byte_size(json)}\r\nx-elzoo-signature: #{sig}\r\nconnection: close\r\n\r\n#{json}"
          )
      end
    after
      :gen_tcp.close(s)
    end
  end

  defp stream(_, _, total, sent) when sent >= total, do: sent

  defp stream(socket, chunk, total, sent) do
    case :gen_tcp.send(socket, chunk) do
      :ok -> stream(socket, chunk, total, sent + byte_size(chunk))
      _ -> sent
    end
  end
end
