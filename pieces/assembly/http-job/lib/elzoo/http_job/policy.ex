# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.HttpJob.Policy do
  @moduledoc false
  @core :"Cure.Elzoo.HttpJobPolicy"
  def action(s, maximum) when is_map(s) and maximum in 1..16 do
    with true <- is_boolean(s.active),
         true <- is_boolean(s.flags.quarantined) and is_boolean(s.flags.disarmed),
         true <- is_integer(s.attempts) and s.attempts in 0..256,
         {phase, count} <- phase(s.phase),
         true <- count == s.attempts do
      apply(@core, :decide, [
        phase,
        s.active,
        s.flags.quarantined,
        s.flags.disarmed,
        s.attempts,
        maximum
      ])
    else
      _ -> :JobUnavailable
    end
  rescue
    _ -> :JobUnavailable
  end

  def action(_, _), do: :JobUnavailable
  defp phase({:Intended, _, n}), do: {:JobIntended, n}
  defp phase({:Dispatched, _, n}), do: {:JobDispatched, n}
  defp phase({:Definite, _, n}), do: {:JobDefinite, n}
  defp phase({:Confirmed, n}), do: {:JobConfirmed, n}
  defp phase({:Stranded, n}), do: {:JobStranded, n}
  defp phase(_), do: :invalid
end
