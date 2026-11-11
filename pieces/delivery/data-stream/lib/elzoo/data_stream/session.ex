# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.Session do
  @moduledoc false
  use GenServer
  alias Elzoo.DataStream.{Adapter, Frame, FinishFrame, Protocol, Terminal, Transport}
  alias Elzoo.EffectIntent, as: Intent

  defstruct [
    :owner,
    :caller,
    :handle,
    :config,
    :prepared,
    :seam,
    :sup,
    :sup_ref,
    :owner_ref,
    :caller_ref,
    :generation,
    :bootstrap,
    :intent,
    :intent_ref,
    :adapter,
    :adapter_ref,
    :request,
    :http,
    :sink,
    :pending,
    :http_result,
    :sink_result,
    :ack_deadline,
    :protocol,
    :token,
    :secret,
    :seal_generation,
    :cleanup_timer,
    allow_volatile: false,
    phase: :preparing,
    terminal: %Terminal{},
    workers: %{},
    supervisor_down: false,
    cleaning: false,
    http_down: false,
    settling: false
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def custody(pid), do: GenServer.call(pid, :custody)
  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, sup} = Task.Supervisor.start_link()
    s = struct!(__MODULE__, opts)

    s = %{
      s
      | sup: sup,
        sup_ref: Process.monitor(sup),
        owner_ref: Process.monitor(s.owner),
        caller_ref: Process.monitor(s.caller),
        generation: make_ref(),
        token: make_ref(),
        secret: :crypto.strong_rand_bytes(32),
        seal_generation: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        protocol: Protocol.new(s.prepared.model, :absent)
    }

    Process.send_after(self(), {:deadline, s.token}, remaining(s))
    {:ok, s}
  end

  @impl true
  def handle_call(:custody, _, s), do: {:reply, s.sup, s}

  def handle_call(
        {:intent, g, pid, bootstrap},
        {bootstrap, _},
        %{generation: g, phase: :preparing} = s
      ) do
    if live?(s) and s.bootstrap == bootstrap do
      {:reply, :ok, %{s | intent: pid, intent_ref: Process.monitor(pid)}}
    else
      {:reply, :error, s}
    end
  end

  def handle_call(
        {:adapter, g, pid, req},
        {pid, _},
        %{generation: g, phase: :preparing, adapter: nil} = s
      ) do
    identity = identity(s)
    key = Elzoo.EffectIntent.Model.key(identity)
    expected = s.config.descriptor

    valid =
      live?(s) and req.key == key and req.attempt == 1 and req.attempt_id == key <> "/attempt/1" and
        req.arguments == s.prepared.body and
        req.arguments_digest == :crypto.hash(:sha256, s.prepared.body) and
        req.binding == expected.digest and req.schema == Adapter.schema() and
        req.context.session == self() and req.context.generation == s.generation

    if valid do
      c = s.prepared.command

      term = %{
        s.terminal
        | correlation: %{
            message_id: c["message_id"],
            correlation_id: Map.get(c, "correlation_id", c["message_id"]),
            logical_ref: c["idempotency_key"],
            intent_key: key,
            attempt_id: req.attempt_id
          },
          intent_confirmation: :unconfirmed
      }

      s = %{s | adapter: pid, adapter_ref: Process.monitor(pid), request: req, terminal: term}

      {task, s} =
        task(s, :http, fn ->
          Transport.run(self_session(req), s.token, s.prepared, s.config, s.seam)
        end)

      s = %{s | http: task, phase: :streaming}
      publish(s)
      {:reply, {:ok, s.token}, s}
    else
      {:reply, :error, s}
    end
  end

  def handle_call({:handoff, token, pid}, {pid, _}, s) do
    if http?(s, token, pid) and live?(s) and s.phase == :streaming,
      do: {:reply, :ok, s},
      else: {:reply, :error, s}
  end

  def handle_call({:received, token, pid, n, status, headers}, {pid, _}, s) do
    if http?(s, token, pid) and s.phase == :streaming and live?(s) do
      s = %{s | terminal: %{s.terminal | received_body_bytes: s.terminal.received_body_bytes + n}}

      case Transport.headers(status, headers) do
        {:error, r, retry_after} ->
          s = fail(%{s | terminal: %{s.terminal | retry_after: retry_after}}, r)
          {:reply, {:error, r}, s}

        {:ok, id, retry_after} ->
          s = %{
            s
            | protocol: %{s.protocol | request_id: id},
              terminal: %{s.terminal | retry_after: retry_after}
          }

          if s.terminal.received_body_bytes > 4_194_304 do
            {:reply, {:error, :receive_limit}, fail(s, :receive_limit)}
          else
            publish(s)
            {:reply, :ok, s}
          end
      end
    else
      {:reply, {:error, :timeout}, maybe_expire(s)}
    end
  end

  def handle_call({:block, token, pid, block}, from, s) do
    if elem(from, 0) == pid and http?(s, token, pid) and s.phase == :streaming and live?(s) do
      s = %{s | terminal: %{s.terminal | raw_blocks: s.terminal.raw_blocks + 1}}

      parsed = Protocol.block(block, s.protocol)
      # Parsing spends the lifetime too; a delayed timer is not authority to
      # commit an event after expiry.
      case if(live?(s), do: parsed, else: {:error, :timeout, s.protocol}) do
        {:ok, p} ->
          {:reply, :ok, observed(s, p)}

        {:ok, p, :none} ->
          {:reply, :ok, observed(s, p)}

        {:ok, p, {:text, text}} ->
          s = observed(s, p)
          s = offer(%{s | pending: from}, :text, text)
          {:noreply, s}

        {:ok, p, :stop} ->
          s = observed(s, p)
          s = %{s | phase: :finishing, terminal: %{s.terminal | source_complete: true}}
          publish(s)
          {:reply, :halt, s}

        {:ok, p, :stream_error} ->
          {:reply, {:error, :stream_error}, fail(observed(s, p), :stream_error)}

        {:error, r, _} ->
          {:reply, {:error, r}, fail(s, r)}
      end
    else
      {:reply, {:error, :timeout}, maybe_expire(s)}
    end
  end

  def handle_call({:http_failure, token, pid, r}, {pid, _}, s) do
    if http?(s, token, pid), do: {:reply, :ok, fail(s, r)}, else: {:reply, :error, s}
  end

  def handle_call(_, _, s), do: {:reply, :error, s}

  @impl true
  def handle_cast(:go, %{bootstrap: nil} = s) do
    if live?(s) do
      parent = self()
      {t, s} = task(s, :bootstrap, fn -> bootstrap(parent, s) end)
      {:noreply, %{s | bootstrap: t.pid}}
    else
      {:noreply, fail(s, :timeout)}
    end
  end

  def handle_cast(:cancel, s),
    do: {:noreply, if(s.terminal.delivery_complete, do: s, else: fail(s, :caller_cancelled))}

  def handle_cast(_, s), do: {:noreply, s}

  @impl true
  def handle_info({ref, result}, s) when is_reference(ref) do
    case Map.get(s.workers, ref) do
      {:http, _} -> {:noreply, %{s | http_result: result}}
      {:sink, _} -> {:noreply, %{s | sink_result: result}}
      {:bootstrap, _} -> {:noreply, fail(s, :intent_unavailable)}
      nil -> {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, s) do
    cond do
      ref == s.owner_ref or ref == s.caller_ref ->
        {:noreply, begin_cleanup(fail(s, :caller_cancelled))}

      ref == s.sup_ref ->
        finish_cleanup(%{s | supervisor_down: true})

      ref == s.intent_ref ->
        finish_cleanup(
          if(s.cleaning,
            do: %{s | intent_ref: nil},
            else: begin_cleanup(fail(%{s | intent_ref: nil}, :intent_unavailable))
          )
        )

      ref == s.adapter_ref ->
        s = %{s | adapter_ref: nil}
        if s.settling, do: send(s.bootstrap, {:check_settlement, s.token})
        finish_cleanup(if(s.cleaning or s.settling, do: s, else: fail(s, :session_lost)))

      true ->
        case Map.pop(s.workers, ref) do
          {nil, _} ->
            {:noreply, s}

          {{kind, ^pid}, workers} ->
            s = %{s | workers: workers}

            s =
              case kind do
                :http ->
                  http_down(%{s | http_down: true}, reason)

                :sink ->
                  sink_down(s, reason)

                :bootstrap ->
                  if(s.cleaning, do: s, else: begin_cleanup(fail(s, :intent_unavailable)))

                :cleanup ->
                  s
              end

            finish_cleanup(s)
        end
    end
  end

  def handle_info({:intent_view, token, pid, view}, %{token: token, bootstrap: pid} = s) do
    s =
      if view.active and view.revision >= 3 and s.settling,
        do: %{s | terminal: %{s.terminal | intent_confirmation: :confirmed}},
        else: s

    {:noreply, if(s.terminal.intent_confirmation == :confirmed, do: begin_cleanup(s), else: s)}
  end

  def handle_info({:initial_view, token, pid, view}, %{token: token, bootstrap: pid} = s) do
    s =
      if view.attempts > 0 and s.terminal.correlation == :absent do
        c = s.prepared.command

        %{
          s
          | terminal: %{
              s.terminal
              | intent_confirmation: :unconfirmed,
                correlation: %{
                  message_id: c["message_id"],
                  correlation_id: Map.get(c, "correlation_id", c["message_id"]),
                  logical_ref: c["idempotency_key"],
                  intent_key: view.key,
                  attempt_id: view.key <> "/attempt/" <> Integer.to_string(view.attempts)
                }
            }
        }
      else
        s
      end

    publish(s)
    {:noreply, s}
  end

  def handle_info({:bootstrap_failed, token}, %{token: token} = s),
    do: {:noreply, begin_cleanup(fail(s, :intent_unavailable))}

  def handle_info({:deadline, token}, %{token: token} = s) do
    if remaining(s) == 0 do
      {:noreply, begin_cleanup(if(s.terminal.delivery_complete, do: s, else: fail(s, :timeout)))}
    else
      Process.send_after(self(), {:deadline, token}, remaining(s))
      {:noreply, s}
    end
  end

  def handle_info({:ack_timeout, token, ref}, %{token: token, sink: %{ref: ref}} = s) do
    if System.monotonic_time(:millisecond) >= s.ack_deadline do
      {:noreply, fail(s, if(remaining(s) == 0, do: :timeout, else: :sink_timeout))}
    else
      Process.send_after(
        self(),
        {:ack_timeout, token, ref},
        s.ack_deadline - System.monotonic_time(:millisecond)
      )

      {:noreply, s}
    end
  end

  def handle_info({:cleanup, token}, %{token: token} = s), do: {:noreply, begin_cleanup(s)}

  def handle_info({:kill, token}, %{token: token} = s) do
    if Process.alive?(s.sup), do: Process.exit(s.sup, :kill)
    if is_pid(s.intent) and Process.alive?(s.intent), do: Process.exit(s.intent, :kill)
    Enum.each(s.workers, fn {_, {_, pid}} -> Process.exit(pid, :kill) end)
    {:noreply, s}
  end

  def handle_info({:EXIT, pid, _}, %{owner: pid} = s),
    do: {:noreply, begin_cleanup(fail(s, :caller_cancelled))}

  def handle_info(_, s), do: {:noreply, s}

  defp observed(s, p) do
    t = %{
      s.terminal
      | last_usage: p.last_usage,
        incurred_usage: p.incurred_usage,
        provenance: p.provenance,
        provider_reason: p.provider_reason
    }

    s = %{s | protocol: p, terminal: t}
    publish(s)
    s
  end

  defp offer(s, kind, text) do
    if live?(s) and is_nil(s.sink) do
      seq = s.terminal.offered_frames
      ref = make_ref()

      chunk =
        if kind == :text,
          do: %{seq: seq, kind: :text_delta, payload: text},
          else: %{seq: seq, kind: :finish, payload: %{reason: s.protocol.finish}}

      {:ok, _} = Elzoo.AiModel.StreamChunk.validate(chunk)
      fields = [handle_ref: s.handle.ref, callback_ref: ref, seq: seq, chunk: chunk]
      frame = if kind == :text, do: struct!(Frame, fields), else: struct!(FinishFrame, fields)

      deadline =
        min(s.prepared.deadline, System.monotonic_time(:millisecond) + s.config.ack_timeout_ms)

      sink = s.prepared.sink

      {t, s} =
        task(s, :sink, fn ->
          try do
            reply =
              if System.monotonic_time(:millisecond) < deadline, do: sink.(frame), else: :expired

            case reply do
              {:ack, ^ref, ^seq} -> :ack
              {:cancel, :caller_cancelled} -> :caller_cancelled
              {:error, :disconnected} -> :disconnected
              _ -> :sink_failed
            end
          rescue
            _ -> :sink_failed
          catch
            _, _ -> :sink_failed
          end
        end)

      Process.send_after(
        self(),
        {:ack_timeout, s.token, t.ref},
        max(0, deadline - System.monotonic_time(:millisecond))
      )

      s = %{
        s
        | sink: Map.put(t, :kind, kind),
          sink_result: nil,
          ack_deadline: deadline,
          terminal: %{s.terminal | offered_frames: seq + 1}
      }

      publish(s)
      s
    else
      fail(s, :timeout)
    end
  end

  defp sink_down(%{cleaning: true} = s, _), do: %{s | sink: nil, sink_result: nil}
  defp sink_down(%{phase: :stopping} = s, _), do: %{s | sink: nil, sink_result: nil}

  defp sink_down(s, reason) do
    kind = s.sink.kind
    value = s.sink_result
    s = %{s | sink: nil, sink_result: nil}

    cond do
      remaining(s) == 0 ->
        fail(s, :timeout)

      System.monotonic_time(:millisecond) >= s.ack_deadline ->
        fail(s, :sink_timeout)

      reason != :normal or value != :ack ->
        fail(s, if(value in [:caller_cancelled, :disconnected], do: value, else: :sink_failed))

      true ->
        s = %{s | terminal: %{s.terminal | acknowledged_frames: s.terminal.acknowledged_frames + 1}}

        if kind == :text do
          GenServer.reply(s.pending, :ok)
          s = %{s | pending: nil}
          publish(s)
          s
        else
          s = %{
            s
            | terminal: %{
                s.terminal
                | status: :complete,
                  reason: :completed,
                  delivery_complete: true
              }
          }

          publish(s)

          digest =
            s.terminal
            |> Terminal.plain()
            |> :erlang.term_to_binary([:deterministic])
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.encode16(case: :lower)

          settle(s, Adapter.completed(s.request, s.protocol.provenance.response_id, digest))
        end
    end
  end

  defp http_down(%{cleaning: true} = s, _), do: s
  defp http_down(%{phase: :stopping} = s, _), do: s

  defp http_down(s, reason) do
    cond do
      not live?(s) ->
        fail(s, :timeout)

      reason == :normal and s.http_result == :source_stop and s.phase == :finishing and
          s.terminal.source_complete ->
        offer(s, :finish, nil)

      reason != :normal ->
        fail(s, :session_lost)

      s.http_result in Map.keys(Elzoo.DataStream.Binding.failures()) ->
        fail(s, s.http_result)

      true ->
        fail(s, :adapter_error)
    end
  end

  defp fail(%{terminal: %{delivery_complete: true}} = s, _), do: s
  defp fail(%{phase: :stopping} = s, _), do: s

  defp fail(s, r) do
    if s.pending, do: GenServer.reply(s.pending, {:error, r})
    if s.http && Process.alive?(s.http.pid), do: Process.exit(s.http.pid, :kill)
    if s.sink && Process.alive?(s.sink.pid), do: Process.exit(s.sink.pid, :kill)

    refused =
      r in ~w(credentials_unavailable provider_invalid_request authentication_failed permission_denied not_found provider_too_large billing_error conflict throttled overloaded)a

    s = %{
      s
      | phase: :stopping,
        pending: nil,
        terminal: %{s.terminal | reason: r, status: if(refused, do: :refused, else: :partial)}
    }

    publish(s)
    if s.adapter, do: settle(s, {:error, r, :redacted}), else: begin_cleanup(s)
  end

  defp settle(s, result) do
    send(s.adapter, {:data_stream_adapter, s.token, result})
    Process.send_after(self(), {:cleanup, s.token}, min(1_000, remaining(s)))
    %{s | settling: true}
  end

  defp begin_cleanup(%{cleaning: true} = s), do: s

  defp begin_cleanup(s) do
    # Supervisor exit is a separate tracked cleanup operation. It cannot block
    # the session's controls. Its parent/link contract also covers session kill.
    Process.send_after(self(), {:kill, s.token}, 1_000)
    sup = s.sup

    {pid, ref} =
      Process.spawn(
        fn ->
          try do
            Supervisor.stop(sup, :shutdown, 1_000)
          catch
            _, _ -> :ok
          end
        end,
        [:link, :monitor]
      )

    %{
      s
      | workers: Map.put(s.workers, ref, {:cleanup, pid}),
        cleaning: true,
        phase: if(s.terminal.delivery_complete, do: :finishing, else: :stopping)
    }
  end

  defp finish_cleanup(s) do
    if s.cleaning and s.supervisor_down and map_size(s.workers) == 0 and is_nil(s.intent_ref) and
         is_nil(s.adapter_ref) do
      true = Terminal.size(s.terminal) <= 4096
      send(s.owner, {:settled, s.handle.ref, s.terminal})
      {:stop, :normal, s}
    else
      {:noreply, s}
    end
  end

  defp task(s, kind, fun) do
    t = Task.Supervisor.async_nolink(s.sup, fun, shutdown: :brutal_kill)
    {%{pid: t.pid, ref: t.ref}, %{s | workers: Map.put(s.workers, t.ref, {kind, t.pid})}}
  end

  defp bootstrap(parent, s) do
    try do
      context = %{
        session: parent,
        generation: s.generation,
        seal_key: s.secret,
        seal_generation: s.seal_generation
      }

      {:ok, pid} =
        Intent.start_link(
          binding: s.config.binding,
          identity: identity(s),
          arguments: s.prepared.body,
          deadline: s.prepared.command["deadline_unix_ms"],
          clock: fn -> System.system_time(:millisecond) end,
          store: s.config.store,
          host: s.config.host,
          task_supervisor: s.sup,
          adapter_context: context,
          allow_volatile: s.allow_volatile
        )

      :ok = GenServer.call(parent, {:intent, s.generation, pid, self()}, :infinity)
      outcome = Intent.advance(pid, :dispatch)
      send(parent, {:initial_view, s.token, self(), Intent.status(pid)})

      case outcome do
        {:ok, :dispatched} ->
          settlement_loop(parent, s.token, pid)

        _ ->
          send(parent, {:bootstrap_failed, s.token})

          receive do
          after
            :infinity -> :ok
          end
      end
    rescue
      _ ->
        send(parent, {:bootstrap_failed, s.token})

        receive do
        after
          :infinity -> :ok
        end
    catch
      _, _ ->
        send(parent, {:bootstrap_failed, s.token})

        receive do
        after
          :infinity -> :ok
        end
    end
  end

  defp settlement_loop(parent, token, intent) do
    receive do
      {:check_settlement, ^token} ->
        view = Intent.status(intent)
        send(parent, {:intent_view, token, self(), view})

        if view.revision < 3 and view.active do
          receive do
          after
            10 -> :ok
          end

          send(self(), {:check_settlement, token})
        end

        settlement_loop(parent, token, intent)
    end
  end

  defp identity(s),
    do: [
      s.config.tenant,
      s.config.descriptor.provider_account,
      s.config.descriptor.id,
      "generate_stream",
      s.prepared.command["idempotency_key"]
    ]

  defp self_session(req), do: req.context.session
  defp http?(%{http: %{pid: pid}, token: token, cleaning: false}, token, pid), do: true
  defp http?(_, _, _), do: false
  defp remaining(s), do: max(0, s.prepared.deadline - System.monotonic_time(:millisecond))

  defp live?(s),
    do: remaining(s) > 0 and Process.alive?(s.owner) and Process.alive?(s.caller) and not s.cleaning

  defp maybe_expire(s), do: if(remaining(s) == 0, do: fail(s, :timeout), else: s)
  defp publish(s), do: send(s.owner, {:summary, s.handle.ref, s.phase, s.terminal})
  @impl true
  def format_status(status),
    do: Map.new(status, fn {k, _} -> {k, if(k == :log, do: [], else: :redacted)} end)
end

defimpl Inspect, for: Elzoo.DataStream.Session do
  def inspect(_, _), do: "#DataStream.Session<redacted>"
end
