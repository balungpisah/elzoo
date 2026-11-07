# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Budget do
  @moduledoc """
  Unit-tagged budget reservation and settlement (ELZ-022).

  `step/2` is the arity-2 `Elzoo.Unit` transition. It checks the state
  invariant I0, decodes the input, then calls the Cure decision functions in
  `Cure.Elzoo.Budget` (sweep first, then exactly one operation) and translates
  the Cure result. It makes no budget decision itself and reads no clock.

  This is not money settlement, a financial ledger, a quota or a rate limiter.
  """

  @cure :"Cure.Elzoo.Budget"

  @type generation :: {String.t(), pos_integer()}
  @type result :: {atom(), term()}

  @reserve_keys [:cap, :unit, :estimate, :cost_ref, :expiry]
  @settle_keys [:cost_ref, :generation, :actual]
  @release_keys [:cost_ref, :generation]
  @reset_keys [:generation]

  @doc "Build a readable initial state with the sealed cap and unit."
  @spec initial(term(), term(), term(), term()) :: {:ok, tuple()} | {:error, atom()}
  def initial(budget_id, incarnation, cap, unit) do
    cond do
      not text?(budget_id) or not text?(incarnation) ->
        {:error, :invalid_input}

      not amount?(cap) ->
        {:error, :invalid_amount}

      not text?(unit) ->
        {:error, :invalid_unit}

      true ->
        {:ok,
         apply(@cure, :initial, [cure_text(budget_id), cure_text(incarnation), cap, cure_text(unit)])}
    end
  end

  @doc "Unit transition: `step(state, {now_ms, input})`. Total; never raises."
  @spec step(term(), term()) :: {:Transition, term(), {:some, result()}}
  def step(state, message) do
    cond do
      not readable?(state) -> reply(state, {:rejected, :unreadable})
      true -> decoded(state, decode_message(message))
    end
  end

  defp decoded(state, {:error, reason}), do: reply(state, {:rejected, reason})

  defp decoded(state, {:ok, now, :sweep}) do
    translate(apply(@cure, :sweep_step, [state, now]), nil)
  end

  defp decoded(state, {:ok, now, operation}) do
    swept = apply(@cure, :sweep, [state, now])

    case operation do
      {:reserve, %{cap: cap, unit: unit, estimate: estimate, cost_ref: ref, expiry: expiry}} ->
        translate(
          apply(@cure, :reserve, [
            swept,
            now,
            cap,
            cure_text(unit),
            cure_text(ref),
            estimate,
            expiry
          ]),
          ref
        )

      {:settle, %{cost_ref: ref, generation: generation, actual: actual}} ->
        translate(
          apply(@cure, :settle, [swept, cure_text(ref), cure_generation(generation), actual]),
          ref
        )

      {:release, %{cost_ref: ref, generation: generation}} ->
        translate(apply(@cure, :release, [swept, cure_text(ref), cure_generation(generation)]), ref)

      {:reset, %{generation: generation}} ->
        translate(apply(@cure, :reset, [swept, cure_generation(generation)]), nil)

      :status ->
        translate(apply(@cure, :status, [swept]), nil)
    end
  end

  defp reply(state, result), do: {:Transition, state, {:some, result}}

  defp translate({:Step, next, result}, ref) do
    generation = generation_of(next)

    output =
      case result do
        {:Reserved, estimate, remaining} ->
          {:reserved,
           %{cost_ref: ref, generation: generation, estimate: estimate, remaining: remaining}}

        {:Rejected, reason} ->
          {:rejected, reason}

        {:SettledRefund, refund, late} ->
          {:settled, %{cost_ref: ref, generation: generation, refund: refund, late: late}}

        {:SettledOverage, overage, late} ->
          {:settled, %{cost_ref: ref, generation: generation, overage: overage, late: late}}

        :ReleasedOk ->
          {:released, %{cost_ref: ref, generation: generation}}

        {:ResetOk, forfeited} ->
          {:reset, %{generation: generation, forfeited: forfeited}}

        {:Status, remaining, open} ->
          {:status, status_map(next, remaining, open)}

        {:Swept, expired} ->
          {:swept, %{expired: expired}}
      end

    reply(next, output)
  end

  defp status_map(
         {:BudgetState, {:String, id}, cap, {:String, unit}, _g, committed, reserved, _e} = s,
         remaining,
         open
       ) do
    %{
      budget_id: List.to_string(id),
      generation: generation_of(s),
      cap: cap,
      unit: List.to_string(unit),
      committed: committed,
      reserved: reserved,
      remaining: remaining,
      open: open
    }
  end

  defp generation_of(
         {:BudgetState, _id, _cap, _unit, {:Generation, {:String, inc}, counter}, _c, _r, _e}
       ),
       do: {List.to_string(inc), counter}

  # ── input decoding (stage 1 after I0) ─────────────────────────────────

  defp decode_message({now, input}) when is_integer(now) and now > 0 do
    case decode_input(input) do
      {:ok, operation} -> {:ok, now, operation}
      error -> error
    end
  end

  defp decode_message(_), do: {:error, :invalid_input}

  defp decode_input(:status), do: {:ok, :status}
  defp decode_input(:sweep), do: {:ok, :sweep}

  defp decode_input({kind, map})
       when kind in [:reserve, :settle, :release, :reset] and is_map(map) do
    keys =
      case kind do
        :reserve -> @reserve_keys
        :settle -> @settle_keys
        :release -> @release_keys
        :reset -> @reset_keys
      end

    with {:ok, fields} <- exact_keys(map, keys),
         :ok <- check(kind, fields) do
      {:ok, {kind, fields}}
    end
  end

  defp decode_input(_), do: {:error, :invalid_input}

  # All keys atoms or all keys strings, exactly the listed set.
  defp exact_keys(map, keys) do
    atom_set = MapSet.new(keys)
    string_set = MapSet.new(keys, &Atom.to_string/1)
    actual = MapSet.new(Map.keys(map))

    cond do
      MapSet.equal?(actual, atom_set) ->
        {:ok, map}

      MapSet.equal?(actual, string_set) ->
        {:ok, Map.new(keys, &{&1, Map.fetch!(map, Atom.to_string(&1))})}

      true ->
        {:error, :invalid_input}
    end
  end

  defp check(:reserve, f) do
    first_error([
      {positive?(f.expiry), :invalid_input},
      {amount?(f.cap) and amount?(f.estimate), :invalid_amount},
      {text?(f.unit), :invalid_unit},
      {text?(f.cost_ref), :invalid_cost_ref}
    ])
  end

  defp check(:settle, f) do
    first_error([
      {generation?(f.generation), :invalid_input},
      {amount?(f.actual), :invalid_amount},
      {text?(f.cost_ref), :invalid_cost_ref}
    ])
  end

  defp check(:release, f) do
    first_error([
      {generation?(f.generation), :invalid_input},
      {text?(f.cost_ref), :invalid_cost_ref}
    ])
  end

  defp check(:reset, f), do: first_error([{generation?(f.generation), :invalid_input}])

  defp first_error(checks) do
    case Enum.find(checks, fn {ok, _} -> not ok end) do
      nil -> :ok
      {_, reason} -> {:error, reason}
    end
  end

  defp amount?(value), do: is_integer(value) and value > 0
  defp positive?(value), do: is_integer(value) and value > 0
  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)

  defp generation?({incarnation, counter}), do: text?(incarnation) and positive?(counter)
  defp generation?(_), do: false

  defp cure_text(value), do: {:String, String.to_charlist(value)}
  defp cure_generation({incarnation, counter}), do: {:Generation, cure_text(incarnation), counter}

  # ── state invariant I0 ─────────────────────────────────────────────────

  @doc "True when `state` satisfies I0 (shape, scalars, entries, reserved sum)."
  @spec readable?(term()) :: boolean()
  def readable?(
        {:BudgetState, id, cap, unit, {:Generation, inc, counter}, committed, reserved, entries}
      )
      when is_integer(cap) and cap > 0 and is_integer(counter) and counter > 0 and
             is_integer(committed) and committed >= 0 and is_integer(reserved) and reserved >= 0 and
             is_list(entries) do
    cure_text?(id) and cure_text?(unit) and cure_text?(inc) and entries_ok?(entries, reserved)
  end

  def readable?(_), do: false

  defp entries_ok?(entries, reserved) do
    Enum.reduce_while(entries, {0, MapSet.new()}, fn
      {:EntryRow, ref, entry}, {sum, seen} ->
        with true <- cure_text?(ref) and not MapSet.member?(seen, ref),
             {:ok, open} <- entry_ok(entry) do
          {:cont, {sum + open, MapSet.put(seen, ref)}}
        else
          _ -> {:halt, :bad}
        end

      _, _ ->
        {:halt, :bad}
    end)
    |> case do
      {sum, _} -> sum == reserved
      :bad -> false
    end
  rescue
    _ -> false
  end

  defp entry_ok({:Open, e, x}), do: if(amount?(e) and positive?(x), do: {:ok, e}, else: :bad)
  defp entry_ok({:Expired, e}), do: if(amount?(e), do: {:ok, 0}, else: :bad)
  defp entry_ok({:Released, e}), do: if(amount?(e), do: {:ok, 0}, else: :bad)

  defp entry_ok({:Settled, e, a, l}),
    do: if(amount?(e) and amount?(a) and is_boolean(l), do: {:ok, 0}, else: :bad)

  defp entry_ok(_), do: :bad

  # A flat, nonempty list of code points (no chardata, no nested lists).
  defp cure_text?({:String, chars}) when is_list(chars) and chars != [] do
    case Enum.all?(chars, &is_integer/1) and :unicode.characters_to_binary(chars) do
      binary when is_binary(binary) -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp cure_text?(_), do: false

  # ── critical-path time admission ──────────────────────────────────────

  @doc "`ceil(n / k) * bound` against `deadline` (same time unit; retries excluded)."
  @spec critical_path(term(), term(), term(), term()) ::
          {:admit, non_neg_integer()}
          | {:reject, :deadline_insufficient, pos_integer()}
          | {:error, :invalid_input}
  def critical_path(n, k, bound, deadline) do
    if positive?(n) and positive?(k) and positive?(bound) and deadline?(deadline),
      do: admission(apply(@cure, :critical_path, [n, k, bound, deadline])),
      else: {:error, :invalid_input}
  end

  @doc "Sum over waves of `ceil(|w| / k) * max(w)`; assumes wave barriers and worst-case bounds."
  @spec critical_path_waves(term(), term(), term()) ::
          {:admit, non_neg_integer()}
          | {:reject, :deadline_insufficient, pos_integer()}
          | {:error, :invalid_input}
  def critical_path_waves(waves, k, deadline) do
    if waves?(waves) and positive?(k) and deadline?(deadline),
      do: admission(apply(@cure, :critical_path_waves, [waves, k, deadline])),
      else: {:error, :invalid_input}
  end

  defp deadline?(value), do: is_integer(value) and value >= 0

  defp waves?(waves) when is_list(waves) and waves != [] do
    Enum.all?(waves, fn wave -> is_list(wave) and wave != [] and Enum.all?(wave, &positive?/1) end)
  rescue
    _ -> false
  end

  defp waves?(_), do: false

  defp admission({:Admit, required}), do: {:admit, required}
  defp admission({:DeadlineInsufficient, required}), do: {:reject, :deadline_insufficient, required}
end
