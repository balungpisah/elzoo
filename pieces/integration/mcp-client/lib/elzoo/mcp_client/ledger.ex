# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Ledger do
  @moduledoc false
  # Every distinct token the Elzoo auth provider has handed to ex_mcp on one
  # session, so redaction covers exactly what was sent (however often the
  # credential rotates). The tokens never leave this process: the only
  # operations are record/2 (from the provider, before a token is handed out)
  # and redact/3, which returns server data with every recorded token (and the
  # caller's bookend resolutions) replaced. There is no read operation. The
  # tokens live in a :private ETS table owned by this process (any other process
  # gets badarg; :sys.get_state/1 shows only the table id), and format_status/1
  # hides the state from :sys status and crash reports.
  # Bounded: a 65th distinct token is refused (the provider then refuses the
  # request as credentials_unavailable), never sent unrecorded. The process
  # monitors the session's client and stops when it exits for any reason,
  # normal included.
  use GenServer
  alias Elzoo.McpClient.Redact

  @max 64

  def start, do: GenServer.start(__MODULE__, nil)

  @doc "Binds the ledger to the client; the ledger stops when the client exits."
  def watch(ledger, client), do: GenServer.cast(ledger, {:watch, client})

  @doc "Records a token before it is handed out; `:error` means do not send it."
  def record(ledger, token) when is_pid(ledger) and is_binary(token) do
    GenServer.call(ledger, {:record, token}, 5_000)
  catch
    _, _ -> :error
  end

  def record(_, _), do: :error

  @doc "Redacts every recorded token and the bookends from server data; `:error` if the ledger is gone."
  def redact(ledger, value, bookends) when is_pid(ledger) and is_list(bookends) do
    GenServer.call(ledger, {:redact, value, bookends}, 15_000)
  catch
    _, _ -> :error
  end

  def redact(_, _, _), do: :error

  def stop(ledger) when is_pid(ledger) do
    GenServer.stop(ledger, :normal, 1_000)
  catch
    _, _ -> :ok
  end

  def stop(_), do: :ok

  @impl true
  def init(_), do: {:ok, %{table: :ets.new(__MODULE__, [:set, :private]), client: nil}}

  @impl true
  def handle_cast({:watch, client}, s) do
    Process.monitor(client)
    {:noreply, %{s | client: client}}
  end

  @impl true
  def handle_call({:record, token}, _from, %{table: t} = s) do
    cond do
      :ets.member(t, token) -> {:reply, :ok, s}
      :ets.info(t, :size) < @max -> {:reply, (:ets.insert(t, {token}) && :ok) || :error, s}
      true -> {:reply, :error, s}
    end
  end

  def handle_call({:redact, value, bookends}, _from, %{table: t} = s) do
    tokens = :ets.select(t, [{{:"$1"}, [], [:"$1"]}])
    {:reply, {:ok, Redact.value(value, bookends ++ tokens)}, s}
  rescue
    _ -> {:reply, :error, s}
  end

  @impl true
  def handle_info({:DOWN, _, :process, client, _}, %{client: client} = s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, :redacted)
  end
end
