# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OsProcess do
  @moduledoc """
  OS-process Adapter: run one external command per request with bounded concurrency,
  an absolute deadline and group-scoped termination performed by erlexec's port program.

  The Adapter never sends a signal itself. erlexec spawns the command as a process-group
  leader, enforces the deadline (SIGTERM to the group, then SIGKILL after `grace_s`),
  stops the group when the owning BEAM process dies or the VM exits, and reports the
  leader's wait status. Elzoo owns admission, the bounded queue, the deadline conversion,
  the output bound, the group observation with `pgrep` and the result schema.
  A termination the provider performs on request (cancel, owner death) is reported as
  `unknown`, because the provider masks the ending signal on those paths.
  """
  use Supervisor
  alias Elzoo.OsProcess.{Adapter, Config, Result}

  @type result :: map()

  @doc "Start one Adapter instance (a supervisor). See `Elzoo.OsProcess.Config` for options."
  def start_link(opts) do
    with {:ok, config} <- Config.validate(opts) do
      case config.name do
        nil -> Supervisor.start_link(__MODULE__, config)
        name -> Supervisor.start_link(__MODULE__, config, name: name)
      end
    end
  end

  @impl true
  def init(config) do
    tid = :ets.new(:elzoo_os_process_runs, [:set, :public, read_concurrency: true])
    config = %{config | tid: tid, supervisor: self()}

    children = [
      {DynamicSupervisor, strategy: :one_for_one, max_restarts: 1000, max_seconds: 1},
      {Adapter, config}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Submit one command. Returns `{:ok, ref}` or `{:error, {:invalid_spec, field}}`.
  The result arrives as `{Elzoo.OsProcess, ref, result}` in the caller's mailbox.
  """
  def submit(sup, spec, opts),
    do: GenServer.call(adapter(sup), {:submit, spec, opts, self()}, :infinity)

  @doc """
  Submit and wait for the result: `{:ok, result}` or `{:error, reason}`.

  The wait is derived from the request: queue timeout + the admitted run limit (time to
  `deadline_unix_ms`, capped by `max_run_ms`) + the instance's grace and observation bounds
  + 5 s. A caller may shorten it with `await_ms`; when the wait ends first, the run is
  cancelled (acceptance only) and `{:error, {:no_result, ref}}` is returned; the late result
  message `{Elzoo.OsProcess, ref, result}` still arrives and must be consumed or ignored.
  """
  def run(sup, spec, opts) do
    adapter = adapter(sup)

    with {:ok, ref} <- GenServer.call(adapter, {:submit, spec, opts, self()}, :infinity) do
      bound = Keyword.get_lazy(opts, :await_ms, fn -> await_bound(adapter, opts) end)

      receive do
        {__MODULE__, ^ref, result} -> {:ok, result}
      after
        bound ->
          _ = GenServer.call(adapter, {:cancel, ref}, :infinity)
          {:error, {:no_result, ref}}
      end
    end
  end

  defp await_bound(adapter, opts) do
    bounds = GenServer.call(adapter, :bounds)

    run_limit =
      [
        opts[:max_run_ms],
        opts[:deadline_unix_ms] && max(opts[:deadline_unix_ms] - System.os_time(:millisecond), 0)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> 0 end)

    min(
      bounds.queue_timeout_ms + run_limit + bounds.grace_ms + bounds.observe_timeout_ms + 5_000,
      4_294_967_295
    )
  end

  @doc "Request termination of a queued or running command. Acceptance, not application."
  def cancel(sup, ref), do: GenServer.call(adapter(sup), {:cancel, ref}, :infinity)

  @doc "Inspection of one run: `%{status, os_pid, owner}` or `nil`."
  def info(sup, ref) do
    with pid when is_pid(pid) <- adapter(sup),
         tid when tid != nil <- GenServer.call(pid, :tid),
         [{^ref, owner, _submitter, os_pid, status}] <- :ets.lookup(tid, ref) do
      %{status: status, os_pid: os_pid, owner: owner}
    else
      _ -> nil
    end
  end

  @doc "Inspection: `%{in_flight, queued, capacity}`. Not telemetry."
  def snapshot(sup), do: GenServer.call(adapter(sup), :snapshot)

  @doc "The instance's time bounds used by `run/3`: `%{queue_timeout_ms, grace_ms, observe_timeout_ms}`."
  def bounds(sup), do: GenServer.call(adapter(sup), :bounds)

  @doc "Map an Adapter result to the core/envelope delivery result; see `Elzoo.OsProcess.Result`."
  defdelegate to_delivery_result(result, request), to: Result

  @doc false
  def adapter(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Adapter, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end
end
