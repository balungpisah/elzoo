# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OutputRepair do
  @moduledoc "Pure repair bound, violation list and failure names over an ai-text completed result."
  alias Elzoo.PayloadSchema

  @invalid [:missing, :schema_mismatch, :invalid_json]
  @finishes [:stop, :length, :tool_calls, :content_filter, :refusal]

  @doc "See the bundle README for operands and the five ordered rules."
  def decide(checked_schema, port, completed, used, bound) do
    if operands?(checked_schema, port, completed, used, bound) do
      %{content: content, structured: structured, finish: finish} = completed
      {b, violations} = content_check(checked_schema, port, content)

      decision =
        apply(:"Cure.Elzoo.OutputRepair", :decide, [
          finish_class(finish),
          structured != {:invalid, :missing} and String.trim(content) != "",
          match?({:valid, _}, structured),
          b,
          used < bound
        ])

      case decision do
        :Accept -> {:accept, elem(structured, 1)}
        :Repair -> {:repair, violations}
        :FailLength -> {:fail, :length, []}
        :FailNoAnswer -> {:fail, :no_answer, []}
        :FailDisagreement -> {:fail, :validator_disagreement, []}
        :FailAtBound -> {:fail, :invalid_at_bound, violations}
      end
    else
      {:error, :invalid_input}
    end
  end

  @doc "The repair text: a fixed head, one `<path>: <code>` line per violation, a fixed tail."
  def render(violations) do
    lines = Enum.map(violations, fn %{path: path, code: code} -> path(path) <> ": #{code}" end)

    Enum.join(
      ["The last output did not match the required schema."] ++
        lines ++ ["Answer again with one JSON value that matches the schema and nothing else."],
      "\n"
    )
  end

  defp path(segments) do
    Enum.reduce(segments, "$", fn
      :key, acc -> acc <> ".*"
      index, acc when is_integer(index) -> acc <> "[#{index}]"
    end)
  end

  defp finish_class(:stop), do: :FinishStop
  defp finish_class(:length), do: :FinishLength
  defp finish_class(_), do: :FinishOther

  defp content_check(checked_schema, port, content) do
    case Jason.decode(content) do
      {:ok, decoded} ->
        case PayloadSchema.check(checked_schema, port, decoded) do
          :ok -> {true, []}
          {:error, {:violations, list}} -> {false, list}
          _ -> {false, []}
        end

      _ ->
        {false, [%{path: [], code: :invalid_json}]}
    end
  end

  defp operands?(checked_schema, port, completed, used, bound) do
    match?({PayloadSchema, _, _, _, _}, checked_schema) and
      match?({:ok, _}, Elzoo.Port.decode(port)) and
      is_integer(bound) and bound in 0..8 and is_integer(used) and used in 0..bound//1 and
      completed?(completed)
  end

  defp completed?(%{content: content, structured: structured, finish: finish}) do
    is_binary(content) and String.valid?(content) and
      (match?({:valid, _}, structured) or
         match?({:invalid, reason} when reason in @invalid, structured)) and
      (finish in @finishes or match?({:other, text} when is_binary(text), finish))
  end

  defp completed?(_), do: false
end
