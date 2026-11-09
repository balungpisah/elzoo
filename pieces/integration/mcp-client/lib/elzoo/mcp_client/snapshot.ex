# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Snapshot do
  @moduledoc """
  The local, pre-send admission filter over the caller's bounded discovery
  snapshot. It may only narrow admission: a tool absent from the snapshot is
  `unknown_tool`, arguments failing the snapshot input schema are
  `invalid_arguments`. Neither claims anything about the server's current tool
  set or schema. A schema with any `$id` or any `$ref` that is not a local
  `#...` pointer is refused, so validation never resolves a remote document.
  """

  def check(%{tools: tools}, tool, arguments) when is_list(tools) do
    case Enum.find(tools, &(is_map(&1) and &1["name"] == tool)) do
      %{"input_schema" => schema} when is_map(schema) -> validate(schema, arguments)
      _ -> {:error, :unknown_tool}
    end
  end

  def check(_, _, _), do: {:error, :unknown_tool}

  defp validate(schema, arguments) do
    with true <- local_only?(schema),
         resolved = ExJsonSchema.Schema.resolve(schema),
         :ok <- ExJsonSchema.Validator.validate(resolved, arguments) do
      :ok
    else
      _ -> {:error, :invalid_arguments}
    end
  rescue
    _ -> {:error, :invalid_arguments}
  catch
    _, _ -> {:error, :invalid_arguments}
  end

  defp local_only?(%{} = m) do
    Enum.all?(m, fn
      {"$id", _} -> false
      {"id", v} when is_binary(v) -> false
      {"$ref", "#" <> _} -> true
      {"$ref", _} -> false
      {_, v} -> local_only?(v)
    end)
  end

  defp local_only?(l) when is_list(l), do: Enum.all?(l, &local_only?/1)
  defp local_only?(_), do: true
end
