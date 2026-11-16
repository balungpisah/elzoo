# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TriggerBinding do
  @moduledoc "Validate exact immutable trigger declarations and select from a bounded snapshot."

  @max_integer 9_223_372_036_854_775_807
  @declaration_keys ~w(version id revision tenant source schema_id schema_version enabled target)
  @target_keys ~w(bot_ref package_digest callable)

  @doc "Validate an exact v1 string-keyed declaration without changing it."
  def validate_declaration(declaration) do
    if valid_declaration?(declaration) do
      {:ok, declaration}
    else
      {:error, :invalid_declaration}
    end
  end

  @doc "Select one enabled declaration using host-supplied scope and declared event metadata."
  def select(snapshot, host_scope, event_schema) do
    with {:ok, scope} <- validate_scope(host_scope),
         {:ok, schema} <- validate_event_schema(event_schema),
         {:ok, rows} <- bounded_snapshot(snapshot),
         {:ok, declarations} <- validate_snapshot(rows),
         :ok <- unique_ids(declarations) do
      select_validated(declarations, scope, schema)
    end
  end

  defp valid_declaration?(declaration) do
    exact_plain_map?(declaration, @declaration_keys) and
      is_integer(declaration["version"]) and declaration["version"] == 1 and
      bounded_text?(declaration["id"], 160) and positive_integer?(declaration["revision"]) and
      bounded_text?(declaration["tenant"], 160) and bounded_text?(declaration["source"], 160) and
      bounded_text?(declaration["schema_id"], 160) and
      positive_integer?(declaration["schema_version"]) and is_boolean(declaration["enabled"]) and
      valid_target?(declaration["target"])
  end

  defp valid_target?(target) do
    exact_plain_map?(target, @target_keys) and bounded_text?(target["bot_ref"], 160) and
      lowercase_digest?(target["package_digest"]) and bounded_text?(target["callable"], 128)
  end

  defp validate_scope(scope) do
    if exact_plain_map?(scope, [:tenant, :source]) and bounded_text?(scope.tenant, 160) and
         bounded_text?(scope.source, 160) do
      {:ok, scope}
    else
      {:error, :invalid_scope}
    end
  end

  defp validate_event_schema(schema) do
    if exact_plain_map?(schema, ~w(schema_id schema_version)) and
         bounded_text?(schema["schema_id"], 160) and positive_integer?(schema["schema_version"]) do
      {:ok, schema}
    else
      {:error, :invalid_event_schema}
    end
  end

  defp bounded_snapshot(snapshot), do: bounded_snapshot(snapshot, 0, [])

  defp bounded_snapshot([], _count, rows), do: {:ok, Enum.reverse(rows)}
  defp bounded_snapshot([_ | _], 256, _rows), do: {:error, :invalid_snapshot}

  defp bounded_snapshot([row | rest], count, rows),
    do: bounded_snapshot(rest, count + 1, [row | rows])

  defp bounded_snapshot(_, _count, _rows), do: {:error, :invalid_snapshot}

  defp validate_snapshot(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, declarations} ->
      case validate_declaration(row) do
        {:ok, declaration} -> {:cont, {:ok, [declaration | declarations]}}
        {:error, :invalid_declaration} -> {:halt, {:error, :invalid_snapshot}}
      end
    end)
    |> case do
      {:ok, declarations} -> {:ok, Enum.reverse(declarations)}
      {:error, :invalid_snapshot} = error -> error
    end
  end

  defp unique_ids(declarations) do
    ids = Enum.map(declarations, & &1["id"])

    if MapSet.size(MapSet.new(ids)) == length(ids) do
      :ok
    else
      {:error, :duplicate_binding_id}
    end
  end

  defp select_validated(declarations, scope, schema) do
    candidates = Enum.map(declarations, &candidate/1)

    case apply(:"Cure.Elzoo.TriggerBinding", :select, [
           candidates,
           text(scope.tenant),
           text(scope.source),
           text(schema["schema_id"]),
           schema["schema_version"]
         ]) do
      :TriggerBindingNoMatch ->
        {:ok, :no_match}

      :TriggerBindingAmbiguous ->
        {:error, :ambiguous}

      {:TriggerBindingSelected, {:String, id}, revision} ->
        selected_declaration(declarations, List.to_string(id), revision)
    end
  end

  defp selected_declaration(declarations, id, revision) do
    case Enum.find(declarations, &(&1["id"] == id and &1["revision"] == revision)) do
      nil ->
        {:error, :invalid_snapshot}

      declaration ->
        {:ok,
         %{
           id: declaration["id"],
           revision: declaration["revision"],
           target: declaration["target"]
         }}
    end
  end

  defp candidate(declaration) do
    {:TriggerBindingCandidate, text(declaration["id"]), declaration["revision"],
     text(declaration["tenant"]), text(declaration["source"]), text(declaration["schema_id"]),
     declaration["schema_version"], declaration["enabled"]}
  end

  defp exact_plain_map?(value, keys) do
    is_map(value) and not is_struct(value) and map_size(value) == length(keys) and
      Enum.all?(keys, &Map.has_key?(value, &1))
  end

  defp bounded_text?(value, max_bytes) do
    is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
      :binary.match(value, <<0>>) == :nomatch
  end

  defp positive_integer?(value),
    do: is_integer(value) and value > 0 and value <= @max_integer

  defp lowercase_digest?(value) when is_binary(value) and byte_size(value) == 64 do
    Enum.all?(:binary.bin_to_list(value), fn byte ->
      (byte >= ?0 and byte <= ?9) or (byte >= ?a and byte <= ?f)
    end)
  end

  defp lowercase_digest?(_), do: false

  defp text(value), do: {:String, String.to_charlist(value)}
end
