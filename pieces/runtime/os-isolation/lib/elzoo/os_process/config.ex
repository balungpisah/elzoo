# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OsProcess.Config do
  @moduledoc """
  Construction-time Config of one Adapter instance. Fixed for the instance's lifetime.

  Settings: `max_concurrent` (positive integer, slots), `queue_limit` (non-negative integer,
  waiting requests), `queue_timeout_ms` (positive integer), `grace_s` (positive integer seconds
  between the provider's SIGTERM and SIGKILL, default 2), `observe_timeout_ms` (positive
  integer, bound of the group observation after the exit notification, default 3000),
  `max_output_bytes` (positive integer, default 1 MiB), `pgrep_path` (absolute path, default
  located with `System.find_executable/1`), `now_unix_ms` (zero-arity function, default
  `System.os_time(:millisecond)`), `name` (optional registered name) and `test_hooks`
  (map of zero-arity functions; test seam, `%{}` by default). Timers are bounded by the
  OTP limit 4_294_967_295 ms.
  """
  @max_timer 4_294_967_295
  defstruct max_concurrent: nil,
            queue_limit: nil,
            queue_timeout_ms: nil,
            grace_s: 2,
            observe_timeout_ms: 3_000,
            max_output_bytes: 1_048_576,
            pgrep_path: nil,
            now_unix_ms: nil,
            name: nil,
            test_hooks: %{},
            tid: nil,
            supervisor: nil

  def max_timer, do: @max_timer

  def validate(opts) do
    with true <- proper_keyword?(opts) || {:error, {:invalid_config, :options}},
         {:ok, max} <- pos_int(opts, :max_concurrent, nil),
         {:ok, ql} <- non_neg_int(opts, :queue_limit, nil),
         {:ok, qt} <- pos_int(opts, :queue_timeout_ms, nil, @max_timer),
         {:ok, grace} <- pos_int(opts, :grace_s, 2, div(@max_timer, 1000)),
         {:ok, observe} <- pos_int(opts, :observe_timeout_ms, 3_000, @max_timer),
         {:ok, bytes} <- pos_int(opts, :max_output_bytes, 1_048_576),
         {:ok, pgrep} <- tool(opts, :pgrep_path, "pgrep"),
         {:ok, now} <- fun0(opts, :now_unix_ms, fn -> System.os_time(:millisecond) end),
         {:ok, hooks} <- hooks(opts),
         :ok <- provider_started() do
      {:ok,
       %__MODULE__{
         max_concurrent: max,
         queue_limit: ql,
         queue_timeout_ms: qt,
         grace_s: grace,
         observe_timeout_ms: observe,
         max_output_bytes: bytes,
         pgrep_path: pgrep,
         now_unix_ms: now,
         name: Keyword.get(opts, :name),
         test_hooks: hooks
       }}
    end
  end

  defp pos_int(opts, key, default, max \\ nil) do
    case Keyword.get(opts, key, default) do
      v when is_integer(v) and v > 0 and (max == nil or v <= max) -> {:ok, v}
      _ -> {:error, {:invalid_config, key}}
    end
  end

  defp non_neg_int(opts, key, default) do
    case Keyword.get(opts, key, default) do
      v when is_integer(v) and v >= 0 -> {:ok, v}
      _ -> {:error, {:invalid_config, key}}
    end
  end

  defp tool(opts, key, name) do
    case Keyword.get(opts, key, System.find_executable(name)) do
      path when is_binary(path) ->
        if Path.type(path) == :absolute and File.regular?(path),
          do: {:ok, path},
          else: {:error, {:tool_unavailable, String.to_atom(name)}}

      _ ->
        {:error, {:tool_unavailable, String.to_atom(name)}}
    end
  end

  defp fun0(opts, key, default) do
    case Keyword.get(opts, key, default) do
      f when is_function(f, 0) -> {:ok, f}
      _ -> {:error, {:invalid_config, key}}
    end
  end

  defp hooks(opts) do
    case Keyword.get(opts, :test_hooks, %{}) do
      m when is_map(m) ->
        if Enum.all?(m, fn {k, v} -> is_atom(k) and is_function(v, 0) end),
          do: {:ok, m},
          else: {:error, {:invalid_config, :test_hooks}}

      _ ->
        {:error, {:invalid_config, :test_hooks}}
    end
  end

  defp provider_started do
    if is_pid(Process.whereis(:exec)), do: :ok, else: {:error, :erlexec_not_started}
  end

  defp proper_keyword?(opts), do: is_list(opts) and Keyword.keyword?(opts)
end
