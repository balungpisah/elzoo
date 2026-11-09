# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Telemetry do
  @moduledoc """
  `runtime/telemetry`: the one Elzoo event family, its measurement units and
  its metadata allowlist, emitted through `:telemetry.execute/3` (telemetry
  1.4.2). See the Piece README for the tables; `schema/0` returns them as data.

  Observation only: an event may be missing; it is not audit, metering,
  billing input or a control receipt. Handlers are synchronous and may be
  absent; `telemetry` detaches a handler that fails.

  `emit/4` checks every measurement and metadata key against the schema.
  `:production` omits what fails and still emits the rest; it never raises.
  `:strict` raises `ArgumentError` naming only the failing keys (never values):
  an invalid emission is an instrumentation defect of the emission point, not
  part of an Adapter's result Contract. `emit/3` uses `default_mode/0`, fixed
  at compile time: `:strict` when Mix is loaded and `Mix.env()` is `:dev` or
  `:test`, otherwise `:production`.
  """

  @families [:job, :effect]
  @kinds [:start, :stop, :exception]
  @events for f <- @families, k <- @kinds, do: [:elzoo, f, k]

  @adapters ["assembly/durable-job", "assembly/http-job"]

  # Measurement keys per event kind; every value is a non-negative integer.
  @measurements %{
    {:job, :start} => [:queue_wait],
    {:job, :stop} => [:duration],
    {:job, :exception} => [:duration],
    {:effect, :start} => [:payload_bytes],
    {:effect, :stop} => [:duration],
    {:effect, :exception} => [:duration]
  }

  @units %{queue_wait: :microsecond, duration: :microsecond, payload_bytes: :byte}

  # {adapter, operation} => {family, required keys, optional keys}.
  # `outcome` (stop) and `reason` (exception) are added as required per kind.
  @operations %{
    {"assembly/durable-job", :perform} =>
      {:job, [:adapter, :operation, :request_ref, :attempt, :queue], []},
    {"assembly/durable-job", :relay} => {:job, [:adapter, :operation, :queue], [:request_ref]},
    {"assembly/http-job", :perform} =>
      {:job, [:adapter, :operation, :attempt], [:request_ref, :queue, :tenant]},
    {"assembly/http-job", :send} =>
      {:effect, [:adapter, :operation], [:request_ref, :attempt, :tenant]},
    {"assembly/http-job", :poll} =>
      {:effect, [:adapter, :operation], [:request_ref, :attempt, :tenant]}
  }

  @effect_outcomes [
    :completed,
    :pending,
    :unavailable,
    :preflight_unavailable,
    :request_rejected,
    :http_4xx,
    :http_5xx,
    :http_redirect,
    :not_acknowledged,
    :receipt_invalid,
    :transport_timeout,
    :transport_error
  ]

  @outcomes %{
    perform: [:ok, :snooze, :cancel, :error],
    relay: [
      :done,
      :skip_indeterminate,
      :skip_contended,
      :skip_foreign_run,
      :skip_rejected,
      :skip_insert,
      :skip_unique_lock_held,
      :skip_malformed,
      :skip_damaged,
      :skip_unavailable,
      :skip_other
    ],
    send: @effect_outcomes,
    poll: @effect_outcomes
  }

  @reasons [:raise, :throw, :exit]

  @strict (if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
             Mix.env() in [:dev, :test]
           else
             false
           end)

  @doc "The compile-time default mode used by `emit/3`."
  def default_mode, do: if(@strict, do: :strict, else: :production)

  @doc "The fixed schema as data (event names, measurement keys and units, operations, outcomes, reasons)."
  def schema,
    do: %{
      events: @events,
      adapters: @adapters,
      measurements: @measurements,
      units: @units,
      operations: @operations,
      outcomes: @outcomes,
      reasons: @reasons
    }

  @doc "Emit with the compile-time default mode."
  def emit(event, measurements, metadata), do: emit(event, measurements, metadata, default_mode())

  @doc """
  Check, then call `:telemetry.execute/3` with only the clean subset.
  Returns `:ok`; in `:strict` mode an invalid emission raises `ArgumentError`.
  An unknown event name is never emitted.
  """
  def emit(event, measurements, metadata, mode) when mode in [:strict, :production] do
    {m_clean, m_bad} = measurements(event, measurements)
    {d_clean, d_bad} = split(event, metadata)

    case {mode, m_bad ++ d_bad} do
      {:strict, [_ | _] = bad} ->
        raise ArgumentError,
              "invalid Elzoo telemetry emission #{inspect(event_name(event))}: #{inspect(Enum.uniq(bad))}"

      _ ->
        if event in @events, do: :telemetry.execute(event, m_clean, d_clean)
        :ok
    end
  end

  @doc """
  Pure metadata check. `{:ok, clean}` when every required key is present and
  valid and no unknown key is present (optional keys failing their grammar are
  dropped from `clean`); otherwise `{:error, {:invalid, keys}}`.
  """
  def metadata(event, map) do
    case split(event, map) do
      {clean, []} -> {:ok, clean}
      {_, bad} -> {:error, {:invalid, Enum.uniq(bad)}}
    end
  end

  # Returns {clean_map, failing_key_names}. Never inspects values into output.
  defp split(event, map) when is_map(map) do
    with [:elzoo, family, kind] <- event,
         true <- event in @events,
         adapter when adapter in @adapters <- Map.get(map, :adapter),
         operation when is_atom(operation) <- Map.get(map, :operation),
         {^family, required, optional} <- Map.get(@operations, {adapter, operation}) do
      required = required ++ kind_keys(kind)
      allowed = required ++ optional

      unknown = for k <- Map.keys(map), k not in allowed, do: key_name(k)

      {clean, bad} =
        Enum.reduce(allowed, {%{}, []}, fn key, {clean, bad} ->
          case Map.fetch(map, key) do
            {:ok, value} ->
              cond do
                valid?(key, value, operation) -> {Map.put(clean, key, value), bad}
                key in required -> {clean, [key | bad]}
                true -> {clean, bad}
              end

            :error ->
              if key in required, do: {clean, [key | bad]}, else: {clean, bad}
          end
        end)

      {clean, Enum.reverse(bad) ++ unknown}
    else
      _ -> {%{}, [:event_or_operation]}
    end
  end

  defp split(_event, _map), do: {%{}, [:metadata]}

  defp kind_keys(:stop), do: [:outcome]
  defp kind_keys(:exception), do: [:reason]
  defp kind_keys(_), do: []

  defp key_name(k) when is_atom(k), do: k
  defp key_name(_), do: :non_atom_key

  defp measurements(event, map) when is_map(map) do
    allowed =
      case event do
        [:elzoo, f, k] -> Map.get(@measurements, {f, k}, [])
        _ -> []
      end

    Enum.reduce(map, {%{}, []}, fn {k, v}, {clean, bad} ->
      if k in allowed and is_integer(v) and v >= 0,
        do: {Map.put(clean, k, v), bad},
        else: {clean, [key_name(k) | bad]}
    end)
  end

  defp measurements(_event, _map), do: {%{}, [:measurements]}

  defp event_name(event) when is_list(event), do: Enum.filter(event, &is_atom/1)
  defp event_name(_), do: :invalid

  # -- positive grammars -------------------------------------------------------

  defp valid?(:adapter, v, _), do: v in @adapters
  defp valid?(:operation, v, _), do: is_atom(v)
  defp valid?(:request_ref, v, _), do: is_binary(v) and Regex.match?(~r/\A[0-9a-f]{64}\z/, v)
  defp valid?(:attempt, v, _), do: is_integer(v) and v >= 1 and v <= 1_000_000
  defp valid?(:queue, v, _), do: is_binary(v) and Regex.match?(~r/\A[a-z][a-z0-9_]{0,31}\z/, v)

  defp valid?(:tenant, v, _),
    do: is_binary(v) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.\-]{0,63}\z/, v)

  defp valid?(:outcome, v, operation), do: v in Map.get(@outcomes, operation, [])
  defp valid?(:reason, v, _), do: v in @reasons

  # -- helpers for emission points -------------------------------------------------

  @doc "A start mark in native monotonic units."
  def mark, do: System.monotonic_time()

  @doc "Microseconds elapsed since `mark/0`'s value."
  def duration(mark),
    do: System.convert_time_unit(System.monotonic_time() - mark, :native, :microsecond)

  @doc "Lowercase hex SHA-256 of a binary: the `request_ref` of a caller key that is never emitted itself."
  def ref(key) when is_binary(key), do: Base.encode16(:crypto.hash(:sha256, key), case: :lower)

  @doc "Microseconds from `scheduled` to `attempted`, clamped at 0; nil unless both are DateTimes."
  def queue_wait(%DateTime{} = attempted, %DateTime{} = scheduled),
    do: max(DateTime.diff(attempted, scheduled, :microsecond), 0)

  def queue_wait(_, _), do: nil

  @doc "The declared job outcome of an Oban perform result: the head of the result only."
  def job_outcome(:ok), do: :ok
  def job_outcome({:ok, _}), do: :ok
  def job_outcome({:snooze, _}), do: :snooze
  def job_outcome({:cancel, _}), do: :cancel
  def job_outcome(_), do: :error

  @doc "Exception `reason` of a caught kind."
  def reason(:error), do: :raise
  def reason(:throw), do: :throw
  def reason(:exit), do: :exit

  @doc "Drop nil values (an omitted optional key or measurement)."
  def compact(map), do: for({k, v} <- map, v != nil, into: %{}, do: {k, v})
end
