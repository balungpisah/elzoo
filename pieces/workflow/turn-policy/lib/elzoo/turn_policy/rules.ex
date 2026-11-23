# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TurnPolicy.Rule do
  @moduledoc """
  The rule plug of `Elzoo.TurnPolicy`: two pure callbacks over plain data.

  `choose/2` answers `{{:turns, member_ids}, rule_state}` or
  `{{:decide, context}, rule_state}` for a person's message; `read/3` answers
  `{{:turns, member_ids}, rule_state}` for the outcome of the one decision
  action. Any other answer, a raise, a throw or an exit fails closed.
  """

  @callback choose(view :: map(), rule_state :: term()) ::
              {{:turns, [String.t()]} | {:decide, map()}, term()}
  @callback read(view :: map(), rule_state :: term(), outcome :: map()) ::
              {{:turns, [String.t()]}, term()}

  @doc false
  def bots(%{members: members}), do: for(%{id: id, kind: :bot} <- members, do: id)
end

defmodule Elzoo.TurnPolicy.Addressed do
  @moduledoc "Built-in rule `\"addressed\"`: the addressed members, else the default member."
  @behaviour Elzoo.TurnPolicy.Rule

  @impl true
  def choose(view, rule_state), do: {{:turns, addressed(view)}, rule_state}

  @impl true
  def read(_view, rule_state, _outcome), do: {{:turns, []}, rule_state}

  @doc false
  def addressed(%{addressed: [_ | _] = ids}), do: ids
  def addressed(%{reply_to: {:member, id}}), do: [id]
  def addressed(%{default_member: nil}), do: []
  def addressed(%{default_member: id}), do: [id]
end

defmodule Elzoo.TurnPolicy.RoundRobin do
  @moduledoc "Built-in rule `\"round_robin\"`: the next bot member after the last one chosen."
  @behaviour Elzoo.TurnPolicy.Rule

  @impl true
  def choose(view, position) do
    case Elzoo.TurnPolicy.Rule.bots(view) do
      [] ->
        {{:turns, []}, position}

      bots ->
        next = if is_integer(position), do: rem(position + 1, length(bots)), else: 0
        {{:turns, [Enum.at(bots, next)]}, next}
    end
  end

  @impl true
  def read(_view, rule_state, _outcome), do: {{:turns, []}, rule_state}
end

defmodule Elzoo.TurnPolicy.Everyone do
  @moduledoc "Built-in rule `\"everyone\"`: every bot member one turn, in member order."
  @behaviour Elzoo.TurnPolicy.Rule

  @impl true
  def choose(view, rule_state), do: {{:turns, Elzoo.TurnPolicy.Rule.bots(view)}, rule_state}

  @impl true
  def read(_view, rule_state, _outcome), do: {{:turns, []}, rule_state}
end

defmodule Elzoo.TurnPolicy.Decided do
  @moduledoc """
  Built-in rule `"decided"`: the addressed members, else one decision action.

  Its `read/3` alone may also answer `{:fallback, rule_state}`: the step then
  gives the turn to the default member with the note `decision_fallback`.
  """
  @behaviour Elzoo.TurnPolicy.Rule
  alias Elzoo.TurnPolicy.Addressed

  @impl true
  def choose(%{addressed: [], reply_to: nil}, rule_state), do: {{:decide, %{}}, rule_state}
  def choose(view, rule_state), do: {{:turns, Addressed.addressed(view)}, rule_state}

  # The outcome is untrusted model output: only an exact pick of bot members counts.
  @impl true
  def read(view, rule_state, %{
        class: "completed",
        schema_id: "elzoo.typed-decision.result",
        schema_version: 1,
        payload: %{"status" => "decided", "value" => %{"pick" => pick} = value}
      })
      when map_size(value) == 1 do
    bots = Elzoo.TurnPolicy.Rule.bots(view)

    cond do
      pick == "several" -> {{:turns, bots}, rule_state}
      pick?(pick, bots, []) -> {{:turns, pick}, rule_state}
      true -> {:fallback, rule_state}
    end
  end

  def read(_view, rule_state, _outcome), do: {:fallback, rule_state}

  defp pick?([], _bots, seen), do: seen != []

  defp pick?([id | rest], bots, seen) when length(seen) < 16,
    do: id in bots and id not in seen and pick?(rest, bots, [id | seen])

  defp pick?(_, _, _), do: false
end
