# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Scheduler.Slots do
  @moduledoc """
  Due-slot evaluation for `state/scheduler`. Cron expressions are evaluated in
  the declared IANA zone by enumerating local wall-clock matches with the
  pinned `crontab` evaluator (public API, minute resolution) and mapping each
  local slot to UTC instants through the declared `Calendar.TimeZoneDatabase`
  Need. Occurrence identity keys on the UTC instant: an ambiguous local slot
  (fall-back overlap) yields the first matching UTC instant and reports its
  second match for the caller's `skipped{ambiguous}` recording; a gap slot
  (spring-forward) yields no instant. Evaluation reads no clock and performs
  no I/O beyond the tz database lookup.
  """

  # UTC offsets never exceed 14h; 26h of slack on each side makes the local
  # enumeration window strictly cover the UTC window at every transition.
  @margin_ms 26 * 3_600_000
  @backlog_cap 1_000

  @doc """
  Parse a `{:cron, expression}` spec with the pinned crontab parser
  (five-field syntax). `@reboot` has no durable meaning and is refused; any
  unparseable or six-field (seconds) expression is refused.
  """
  def parse_cron(expression) when is_binary(expression) do
    five_field? =
      expression
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)
      |> length() == 5

    if five_field? and not String.contains?(expression, "@reboot") do
      case Crontab.CronExpression.Parser.parse(expression) do
        {:ok, %Crontab.CronExpression{reboot: true}} -> {:error, :invalid_spec}
        {:ok, parsed} -> {:ok, parsed}
        {:error, _} -> {:error, :invalid_spec}
      end
    else
      {:error, :invalid_spec}
    end
  end

  def parse_cron(_), do: {:error, :invalid_spec}

  @doc "Resolve a declared IANA zone through the declared database Need."
  def zone_resolvable?(zone, time_zone_database) when is_binary(zone) do
    match?({:ok, _}, DateTime.from_naive(~N[2000-01-01 00:00:00], zone, time_zone_database))
  rescue
    _ -> false
  end

  def zone_resolvable?(_, _), do: false

  @doc """
  Due instants of `spec` in `(after_unix_ms, now_unix_ms]`, oldest first, at
  most `max` of them, plus `backlog` (further due instants, capped at
  #{@backlog_cap}).

  Returns `{:ok, emissions, backlog}` where each emission is
  `{instant_unix_ms, :win | :ambiguous}` in ascending order: `:win` is a slot
  to admit through trigger, `:ambiguous` is the discarded second UTC match of
  a local slot to record `skipped{ambiguous}` without admission.
  """
  def due(spec, zone, time_zone_database, after_unix_ms, now_unix_ms, max) do
    case spec do
      {:at, instant} -> due_at(instant, after_unix_ms, now_unix_ms, max)
      {:cron, parsed} -> due_cron(parsed, zone, time_zone_database, after_unix_ms, now_unix_ms, max)
    end
  end

  defp due_at(instant, after_unix_ms, now_unix_ms, max) do
    if max >= 1 and instant > after_unix_ms and instant <= now_unix_ms,
      do: {:ok, [{instant, :win}], 0},
      else: {:ok, [], 0}
  end

  defp due_cron(parsed, zone, db, after_unix_ms, now_unix_ms, max) do
    with {:ok, first_naive} <- naive_of(after_unix_ms - @margin_ms, zone, db),
         {:ok, last_naive} <- naive_of(now_unix_ms + @margin_ms, zone, db) do
      stream =
        Crontab.Scheduler.get_next_run_dates(parsed, first_naive)
        |> Stream.take_while(&(NaiveDateTime.compare(&1, last_naive) != :gt))

      step = fn naive, {emissions, emitted, backlog} ->
        case instants(naive, zone, db) do
          :error ->
            {:halt, :error}

          [] ->
            {:cont, {emissions, emitted, backlog}}

          instants ->
            in_range =
              instants
              |> Enum.with_index()
              |> Enum.filter(fn {u, _} -> u > after_unix_ms and u <= now_unix_ms end)

            cond do
              Enum.any?(instants, &(&1 > now_unix_ms)) ->
                {:halt, {emissions, emitted, backlog}}

              backlog >= @backlog_cap ->
                {:halt, {emissions, emitted, backlog}}

              emitted < max ->
                {fit, rest} = Enum.split(in_range, max - emitted)

                {:cont,
                 {add_emissions(emissions, fit), emitted + length(fit), backlog + length(rest)}}

              true ->
                {:cont, {emissions, emitted, min(backlog + length(in_range), @backlog_cap)}}
            end
        end
      end

      case Enum.reduce_while(stream, {[], 0, 0}, step) do
        :error -> {:error, :invalid_spec}
        {emissions, _emitted, backlog} -> {:ok, Enum.reverse(emissions), backlog}
      end
    else
      _ -> {:error, :invalid_spec}
    end
  end

  # Position 0 of a local slot's UTC instants wins admission; each later
  # instant of the same slot is the ambiguous match to record as skipped.
  defp add_emissions(emissions, tagged),
    do:
      Enum.reduce(tagged, emissions, fn {instant, position}, acc ->
        [{instant, if(position == 0, do: :win, else: :ambiguous)} | acc]
      end)

  @doc "UTC instants (ascending) realizing the local wall time; `[]` for a gap, `:error` for an unresolvable zone."
  def instants(naive, zone, time_zone_database) do
    case DateTime.from_naive(naive, zone, time_zone_database) do
      {:ok, dt} -> [millis(dt)]
      {:ambiguous, first, second} -> Enum.sort([millis(first), millis(second)])
      {:gap, _just_before, _just_after} -> []
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp naive_of(unix_ms, zone, db) do
    utc = DateTime.from_unix!(unix_ms, :millisecond)

    case DateTime.shift_zone(utc, zone, db) do
      {:ok, dt} -> {:ok, DateTime.to_naive(dt)}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp millis(dt), do: DateTime.to_unix(dt, :millisecond)
end
