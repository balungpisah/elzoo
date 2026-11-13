# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ProviderStream do
  @moduledoc """
  The partial output of one Anthropic Messages call, partial tool-call
  arguments included, offered to one local sink one acknowledged frame at a
  time, and one result assembled inside a byte bound.

  `run(payload, sink, settings)` makes at most one POST and returns when the
  call has ended. It blocks the calling process. The HTTP exchange and each
  sink call run in workers linked to that process; both are dead before it
  returns. The result is `{:complete, result}`, `{:incomplete, reason}`,
  `{:refused, reason}` or `{:error, :configuration}`; each reason is a fixed
  atom and no result holds provider text other than the assembled output.
  """
  alias Elzoo.DataStream.{Framer, Transport}
  alias Elzoo.ProviderStream.{Frame, Protocol, Request}

  @keys [
    :credentials,
    :models,
    :total_timeout_ms,
    :receive_timeout_ms,
    :ack_timeout_ms,
    :max_result_bytes
  ]
  @required [:credentials, :models, :max_result_bytes]
  @defaults [total_timeout_ms: 60_000, receive_timeout_ms: 5_000, ack_timeout_ms: 1_000]
  @refused [
    :provider_invalid_request,
    :authentication_failed,
    :billing_error,
    :permission_denied,
    :not_found,
    :conflict,
    :provider_too_large,
    :throttled,
    :overloaded
  ]
  @max_received 4_194_304

  def run(payload, sink, settings), do: run(payload, sink, settings, :production)

  @doc false
  # Private entry for tests: `{:loopback, origin, ca}` through Transport.endpoint/1.
  def run(payload, sink, settings, seam) do
    case config(settings) do
      {:ok, c} when is_function(sink, 1) ->
        deadline = System.monotonic_time(:millisecond) + c.total_timeout_ms

        case Request.prepare(payload, c.models) do
          {:ok, body, model} -> exchange(body, model, sink, c, deadline, seam)
          {:error, reason} -> {:refused, reason}
        end

      _ ->
        {:error, :configuration}
    end
  end

  defp config(settings) do
    with true <- is_list(settings) and Keyword.keyword?(settings),
         keys = Keyword.keys(settings),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 in @keys)) and Enum.all?(@required, &(&1 in keys)),
         c = Map.new(Keyword.merge(@defaults, settings)),
         true <- is_function(c.credentials, 0),
         true <- is_list(c.models) and length(c.models) in 1..16,
         true <- length(c.models) == length(Enum.uniq(c.models)),
         true <- Enum.all?(c.models, &Elzoo.AiModel.text?(&1, 256)),
         true <- integer?(c.max_result_bytes, 1_048_576),
         true <- integer?(c.total_timeout_ms, 300_000),
         true <- integer?(c.receive_timeout_ms, min(30_000, c.total_timeout_ms)),
         true <- integer?(c.ack_timeout_ms, min(10_000, c.total_timeout_ms)) do
      {:ok, c}
    else
      _ -> {:error, :configuration}
    end
  rescue
    _ -> {:error, :configuration}
  end

  defp integer?(n, max), do: is_integer(n) and n >= 1 and n <= max

  defp exchange(body, model, sink, c, deadline, seam) do
    parent = self()
    tag = make_ref()
    http = spawn_link(fn -> http(parent, tag, body, c, seam) end)

    loop(%{
      tag: tag,
      http: http,
      monitor: Process.monitor(http),
      sink: sink,
      callback_ref: make_ref(),
      seq: 0,
      ack_timeout_ms: c.ack_timeout_ms,
      deadline: deadline,
      model: model,
      request_id: :absent,
      protocol: Protocol.new(c.max_result_bytes)
    })
  end

  defp loop(%{tag: tag, http: http, monitor: monitor} = s) do
    receive do
      {^tag, ^http, {:headers, status, headers}} ->
        case Transport.headers(status, headers) do
          {:ok, request_id, _} -> reply(%{s | request_id: request_id}, :ok)
          {:error, reason, _} when reason in @refused -> close(s, {:refused, reason})
          {:error, reason, _} -> close(s, {:incomplete, reason})
        end

      {^tag, ^http, {:block, raw}} ->
        case Protocol.block(s.protocol, raw) do
          {:ok, p, nil} -> reply(%{s | protocol: p}, :ok)
          {:ok, p, {kind, payload}} -> offer(%{s | protocol: p}, kind, payload)
          {:stop, p} -> reply(%{s | protocol: p}, :halt)
          {:error, reason} -> close(s, {:incomplete, reason})
        end

      {^tag, ^http, {:fail, reason}} ->
        close(s, {:incomplete, reason})

      {^tag, ^http, {:done, outcome}} ->
        done(s, outcome)

      {:DOWN, ^monitor, :process, _, _} ->
        # The worker is already dead; its only DOWN is taken here.
        flush(s.tag)
        {:incomplete, :adapter_error}
    after
      remaining(s) -> close(s, {:incomplete, :timeout})
    end
  end

  defp reply(s, message) do
    send(s.http, {s.tag, message})
    loop(s)
  end

  defp done(%{protocol: %{phase: :stopped}} = s, :source_stop) do
    monitor = s.monitor

    receive do
      {:DOWN, ^monitor, :process, _, :normal} ->
        flush(s.tag)
        {:complete, Protocol.result(s.protocol, s.model, s.request_id)}

      {:DOWN, ^monitor, :process, _, _} ->
        flush(s.tag)
        {:incomplete, :adapter_error}
    end
  end

  defp done(s, :credentials_unavailable), do: close(s, {:refused, :credentials_unavailable})
  defp done(s, :source_stop), do: close(s, {:incomplete, :malformed_response})
  defp done(s, reason), do: close(s, {:incomplete, reason})

  # One frame offered; nothing else is decoded or read until its sink worker
  # answers, because the HTTP worker waits for the reply to this block.
  defp offer(s, kind, payload) do
    frame = %Frame{
      callback_ref: s.callback_ref,
      seq: s.seq,
      chunk: %{seq: s.seq, kind: kind, payload: payload}
    }

    s = %{s | seq: s.seq + 1}
    {parent, tag, sink} = {self(), s.tag, s.sink}
    worker = spawn_link(fn -> send(parent, {tag, self(), {:sink, call(sink, frame)}}) end)
    monitor = Process.monitor(worker)

    receive do
      {^tag, ^worker, {:sink, answer}} ->
        receive do
          {:DOWN, ^monitor, :process, _, _} -> :ok
        end

        case answer do
          {:ack, ref, seq} when ref == frame.callback_ref and seq == frame.seq -> reply(s, :ok)
          {:cancel, :caller_cancelled} -> close(s, {:incomplete, :caller_cancelled})
          {:error, :disconnected} -> close(s, {:incomplete, :disconnected})
          _ -> close(s, {:incomplete, :sink_failed})
        end
    after
      min(s.ack_timeout_ms, remaining(s)) ->
        kill(worker, monitor)
        close(s, {:incomplete, if(remaining(s) == 0, do: :timeout, else: :sink_timeout)})
    end
  end

  defp call(sink, frame) do
    sink.(frame)
  rescue
    _ -> :sink_failed
  catch
    _, _ -> :sink_failed
  end

  # Kills the HTTP worker (its socket closes with it) and returns the result.
  defp close(s, result) do
    kill(s.http, s.monitor)
    flush(s.tag)
    result
  end

  defp kill(pid, monitor) do
    Process.unlink(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, _, _} -> :ok
    end
  end

  defp flush(tag) do
    receive do
      {^tag, _, _} -> flush(tag)
    after
      0 -> :ok
    end
  end

  defp remaining(s), do: max(s.deadline - System.monotonic_time(:millisecond), 0)

  ## HTTP worker

  defp http(parent, tag, body, c, seam) do
    outcome =
      try do
        case key(c.credentials) do
          {:ok, key} -> exchange_http(parent, tag, body, key, c, seam)
          :error -> :credentials_unavailable
        end
      rescue
        _ -> :adapter_error
      catch
        _, _ -> :adapter_error
      end

    send(parent, {tag, self(), {:done, outcome}})
  end

  defp exchange_http(parent, tag, body, key, c, seam) do
    ask = fn message ->
      send(parent, {tag, self(), message})

      receive do
        {^tag, answer} -> answer
      end
    end

    block = fn raw, nil ->
      case ask.({:block, raw}) do
        :ok -> {:ok, nil}
        :halt -> {:halt, nil}
      end
    end

    headers = fn resp -> :ok = ask.({:headers, resp.status, resp.headers}) end
    Process.put(tag, %{framer: Framer.new(), called: false, received: 0, halted: false})

    into = fn {:data, bytes}, {req, resp} ->
      st = Process.get(tag)
      if not st.called, do: headers.(resp)
      received = st.received + byte_size(bytes)
      if received > @max_received, do: ask.({:fail, :receive_limit})

      case Framer.feed(st.framer, bytes, nil, block) do
        {:ok, f, _} ->
          Process.put(tag, %{st | framer: f, called: true, received: received})
          {:cont, {req, resp}}

        {:halt, f, _} ->
          Process.put(tag, %{st | framer: f, called: true, received: received, halted: true})
          {:halt, {req, resp}}

        {:error, reason, _, _} ->
          ask.({:fail, reason})
      end
    end

    response =
      Transport.request(body, key, %{receive_timeout_ms: c.receive_timeout_ms}, into, seam)
      |> Req.request()

    st = Process.delete(tag)

    case response do
      {:error, %Req.TransportError{reason: :timeout}} ->
        :timeout

      {:error, _} ->
        :transport

      {:ok, _} when st.halted ->
        :source_stop

      {:ok, resp} ->
        if not st.called, do: headers.(resp)

        case Framer.eof(st.framer, nil, block) do
          {:halt, _, _} -> :source_stop
          {:error, reason, _, _} -> reason
          {:ok, _, _} -> :missing_completion
        end
    end
  end

  defp key(credentials) do
    case credentials.() do
      {:ok, k} when is_binary(k) and byte_size(k) in 1..1024 ->
        if Regex.match?(~r/\A[\x21-\x7e]+\z/, k), do: {:ok, k}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
