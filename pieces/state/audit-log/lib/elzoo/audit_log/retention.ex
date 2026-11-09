# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AuditLog.Retention do
  @moduledoc """
  Explicit, dated retention rule. `%{keep_days: 1..36_500, effective_from: Date}`: from
  `effective_from` (UTC date, inclusive) on, an audit transaction whose `inserted_at` lies more
  than `keep_days` days before `now` is past the rule; before `effective_from` nothing is.

  `expired?/3` is the pure decision; `expired/5` is the caller-invoked query that **selects**
  transaction IDs past the rule. Nothing here deletes, schedules or runs a job; deletion is the
  consumer's, under the audit owner role.
  """
  alias Ecto.Adapters.SQL

  @max_days 36_500

  def validate(%{keep_days: days, effective_from: %Date{} = from} = rule)
      when map_size(rule) == 2 and is_integer(days) and days >= 1 and days <= @max_days,
      do: {:ok, %{keep_days: days, effective_from: from}}

  def validate(_), do: {:error, :invalid_rule}

  @doc "Cutoff instant (naive UTC) or `:not_in_force` before the rule's date."
  def cutoff(rule, %DateTime{} = now) do
    with {:ok, rule} <- validate(rule) do
      now = DateTime.shift_zone!(now, "Etc/UTC")

      if Date.compare(DateTime.to_date(now), rule.effective_from) == :lt,
        do: {:ok, :not_in_force},
        else: {:ok, now |> DateTime.add(-rule.keep_days * 86_400, :second) |> DateTime.to_naive()}
    end
  end

  def cutoff(_, _), do: {:error, :invalid_rule}

  @doc "Pure: is an audit transaction inserted at `inserted_at` (naive UTC) past the rule at `now`?"
  def expired?(rule, %NaiveDateTime{} = inserted_at, now) do
    case cutoff(rule, now) do
      {:ok, :not_in_force} -> {:ok, false}
      {:ok, cutoff} -> {:ok, NaiveDateTime.compare(inserted_at, cutoff) == :lt}
      error -> error
    end
  end

  def expired?(_, _, _), do: {:error, :invalid_option}

  @doc "Selects up to `limit` (1..10_000) audit transaction IDs past the rule, oldest first."
  def expired(repo, carbonite_prefix, rule, %DateTime{} = now, limit)
      when is_integer(limit) and limit in 1..10_000 do
    with :ok <- Elzoo.AuditLog.identifier(carbonite_prefix),
         {:ok, cutoff} <- cutoff(rule, now) do
      if cutoff == :not_in_force do
        {:ok, []}
      else
        rows =
          SQL.query!(
            repo,
            "SELECT id FROM #{carbonite_prefix}.transactions WHERE inserted_at < $1 ORDER BY id LIMIT $2",
            [cutoff, limit],
            log: false
          ).rows

        {:ok, Enum.map(rows, &hd/1)}
      end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :unavailable}
  end

  def expired(_, _, _, _, _), do: {:error, :invalid_option}
end
