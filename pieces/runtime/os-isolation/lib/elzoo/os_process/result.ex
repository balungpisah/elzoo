# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OsProcess.Result do
  @moduledoc """
  Request validation, the Adapter result schema and its mapping to the core/envelope
  delivery result. The shared delivery-result map gains no key; the Adapter result is
  returned alongside it as the paired sidecar.
  """
  import Bitwise

  @doc "Validate spec and options; returns `{:ok, request}` or `{:error, {:invalid_spec, field}}`."
  def validate_request(spec, opts) do
    with true <- is_map(spec) || {:error, {:invalid_spec, :spec}},
         true <- (is_list(opts) and Keyword.keyword?(opts)) || {:error, {:invalid_spec, :options}},
         {:ok, exe} <- absolute(Map.get(spec, :executable), :executable),
         {:ok, args} <- binaries(Map.get(spec, :args, []), :args),
         {:ok, cwd} <- optional_absolute(Map.get(spec, :cwd), :cwd),
         {:ok, env} <- env(Map.get(spec, :env, %{})),
         {:ok, deadline} <-
           optional_non_neg(Keyword.get(opts, :deadline_unix_ms), :deadline_unix_ms),
         {:ok, max_run} <- optional_pos(Keyword.get(opts, :max_run_ms), :max_run_ms),
         true <- (deadline != nil or max_run != nil) || {:error, {:invalid_spec, :deadline}},
         {:ok, request} <- request_fields(Keyword.get(opts, :request, %{})) do
      {:ok,
       %{
         executable: exe,
         args: args,
         cwd: cwd,
         env: env,
         deadline_unix_ms: deadline,
         max_run_ms: max_run,
         request: request
       }}
    end
  end

  defp absolute(v, field) when is_binary(v) do
    if Path.type(v) == :absolute and String.valid?(v) and not String.contains?(v, "\0"),
      do: {:ok, v},
      else: {:error, {:invalid_spec, field}}
  end

  defp absolute(_, field), do: {:error, {:invalid_spec, field}}
  defp optional_absolute(nil, _), do: {:ok, nil}
  defp optional_absolute(v, field), do: absolute(v, field)

  defp binaries(list, field) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and String.valid?(&1) and not String.contains?(&1, "\0"))),
      do: {:ok, list},
      else: {:error, {:invalid_spec, field}}
  end

  defp binaries(_, field), do: {:error, {:invalid_spec, field}}

  defp env(%{} = env) do
    inherit = Map.get(env, :inherit, [])
    set = Map.get(env, :set, [])
    extra = Map.keys(env) -- [:inherit, :set]

    with true <- extra == [] || {:error, {:invalid_spec, :env}},
         {:ok, _} <- binaries(inherit, :env),
         true <-
           (is_list(set) and Enum.all?(set, &name_value?/1)) || {:error, {:invalid_spec, :env}} do
      {:ok, %{inherit: inherit, set: set}}
    end
  end

  defp env(_), do: {:error, {:invalid_spec, :env}}

  defp name_value?({n, v}),
    do:
      is_binary(n) and n != "" and not String.contains?(n, ["=", "\0"]) and is_binary(v) and
        not String.contains?(v, "\0")

  defp name_value?(_), do: false

  defp optional_non_neg(nil, _), do: {:ok, nil}
  defp optional_non_neg(v, _) when is_integer(v) and v >= 0, do: {:ok, v}
  defp optional_non_neg(_, field), do: {:error, {:invalid_spec, field}}
  defp optional_pos(nil, _), do: {:ok, nil}
  defp optional_pos(v, _) when is_integer(v) and v > 0 and v <= 4_294_967_295, do: {:ok, v}
  defp optional_pos(_, field), do: {:error, {:invalid_spec, field}}

  defp request_fields(%{} = request) do
    allowed = ~w(message_id correlation_id attempt_id)

    if Enum.all?(request, fn {k, v} -> k in allowed and is_binary(v) and v != "" end),
      do: {:ok, request},
      else: {:error, {:invalid_spec, :request}}
  end

  defp request_fields(_), do: {:error, {:invalid_spec, :request}}

  # ---- result constructors (atom-keyed maps)

  def rejected(reason) when reason in [:queue_full, :queue_timeout, :spawn_failed, :cancelled],
    do: %{status: :rejected, reason: reason}

  def expired(request), do: %{status: :expired, deadline_unix_ms: request.deadline_unix_ms}

  def completed(exit_code, output, truncated, leftovers, os_pid),
    do: %{
      status: :completed,
      exit_code: exit_code,
      output: output,
      truncated: truncated,
      leftovers: leftovers,
      os_pid: os_pid
    }

  def terminated(stage, signal, output, truncated, os_pid),
    do: %{
      status: :terminated,
      cause: :deadline,
      stage: stage,
      signal: signal,
      exit_code: nil,
      output: output,
      truncated: truncated,
      os_pid: os_pid
    }

  def unknown(reason, fields) when is_map(fields),
    do:
      Map.merge(
        %{
          status: :unknown,
          reason: reason,
          cause: nil,
          os_pid: nil,
          members: [],
          output: "",
          truncated: false,
          exit_code: nil
        },
        fields
      )

  @doc "Decode a wait(2) status as erlexec reports it: `{:exit, code}` or `{:signal, number}`."
  def decode_wait_status(status) when is_integer(status) do
    termsig = band(status, 0x7F)

    if termsig != 0 and termsig != 0x7F,
      do: {:signal, termsig},
      else: {:exit, bsr(band(status, 0xFF00), 8)}
  end

  # ---- delivery mapping

  @doc """
  `{:ok, delivery_result_map, adapter_result}` or `{:error, reason}`. `request` is a
  string-keyed map with `message_id` and optional `correlation_id`, `attempt_id`,
  `deadline_unix_ms` (the request Envelope's deadline, echoed).
  """
  def to_delivery_result(%{status: status} = result, request) when is_map(request) do
    with {:ok, base} <- base(request) do
      map =
        case status do
          :completed ->
            Map.merge(base, %{
              "outcome" => "completed",
              "dispatch" => "dispatched",
              "value" => %{
                "exit_code" => result.exit_code,
                "output" => result.output,
                "truncated" => result.truncated
              },
              "value_schema_id" => "elzoo/os-process-completed",
              "value_schema_version" => 1
            })

          :rejected ->
            class =
              if result.reason in [:queue_full, :queue_timeout],
                do: "unavailable",
                else: "permanent"

            failure(base, "rejected", "not_dispatched", class)

          :expired ->
            failure(base, "timed_out", "not_dispatched", "unclassified")

          :terminated ->
            failure(base, "timed_out", "dispatched", "unclassified")

          :unknown ->
            failure(base, "unknown", "dispatched", "unclassified")
        end

      case Elzoo.Envelope.validate_result(map) do
        {:ok, checked} -> {:ok, checked, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp base(request) do
    case request["message_id"] do
      id when is_binary(id) and id != "" ->
        base = %{
          "version" => 1,
          "message_id" => id,
          "correlation_id" => request["correlation_id"] || id
        }

        base =
          Enum.reduce(~w(attempt_id deadline_unix_ms), base, fn key, acc ->
            case request[key] do
              nil -> acc
              v -> Map.put(acc, key, v)
            end
          end)

        {:ok, base}

      _ ->
        {:error, :missing_message_id}
    end
  end

  defp failure(base, outcome, dispatch, class),
    do: Map.merge(base, %{"outcome" => outcome, "dispatch" => dispatch, "error_class" => class})
end
