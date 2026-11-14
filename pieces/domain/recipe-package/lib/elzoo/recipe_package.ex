# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipePackage do
  @moduledoc "Pure bounded recipe package declarations; no loading or authority."

  @bytes 2_097_152
  @keys ~w(format_version name version identity needs permissions graph settings skills)
  @skill_keys ~w(name version tools frontmatter body)
  @front_required ~w(name description)
  @front_optional ~w(license compatibility metadata allowed-tools)

  @doc "Check decoded declarations and their canonical content identity."
  def decode(map) do
    try do
      plain(map, 0, 0)
      exact(map, @keys, :invalid_shape)
      require!(map["format_version"] === 1, :unsupported_version)
      text(map["name"], 1, 128, :invalid_shape)
      text(map["version"], 1, 128, :invalid_shape)
      identities(map["needs"], :invalid_shape)
      identities(map["permissions"], :invalid_shape)
      skills(map["skills"])

      case Elzoo.RecipeGraph.decode(map["graph"]) do
        {:ok, graph} -> require!(Elzoo.RecipeGraph.encode(graph) === map["graph"], :invalid_graph)
        _ -> fail(:invalid_graph)
      end

      case Elzoo.RecipeConfig.build(map["settings"]) do
        {:ok, _} -> :ok
        _ -> fail(:invalid_settings_descriptor)
      end

      identity(map)
      {:ok, {__MODULE__, map}}
    catch
      {:recipe_package_error, reason} -> {:error, reason}
    end
  end

  @doc "Return the exact original neutral map from a caller-held checked value."
  def encode({__MODULE__, map}), do: map

  defp require!(true, _), do: :ok
  defp require!(_, reason), do: fail(reason)
  defp fail(reason), do: throw({:recipe_package_error, reason})

  defp exact(map, keys, reason) do
    require!(is_map(map) and not is_struct(map), reason)
    require!(Enum.sort(Map.keys(map)) == Enum.sort(keys), reason)
  end

  defp text(value, min, max, reason) do
    require!(is_binary(value) and String.valid?(value), reason)
    require!(byte_size(value) >= min, reason)
    require!(byte_size(value) <= max, :too_large)
  end

  defp bounded(list, max, reason) do
    require!(is_list(list), reason)
    require!(length(list) <= max, :too_large)
  end

  defp identities(list, reason) do
    bounded(list, 64, reason)
    Enum.each(list, &text(&1, 1, 128, reason))
    require!(length(Enum.uniq(list)) == length(list), reason)
  end

  defp skills(list) do
    bounded(list, 16, :invalid_skill)
    Enum.each(list, &skill/1)
    names = Enum.map(list, & &1["name"])
    require!(length(Enum.uniq(names)) == length(names), :invalid_skill)
    require!(length(Enum.uniq(Enum.flat_map(list, & &1["tools"]))) <= 64, :too_large)
    require!(Enum.sum(Enum.map(list, &byte_size(&1["body"]))) <= 32_768, :too_large)
  end

  defp skill(s) do
    exact(s, @skill_keys, :invalid_skill)
    text(s["name"], 1, 64, :invalid_skill)
    require!(Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, s["name"]), :invalid_skill)
    text(s["version"], 1, 128, :invalid_skill)
    identities(s["tools"], :invalid_skill)
    text(s["body"], 0, 16_384, :invalid_skill)
    frontmatter(s["frontmatter"], s["name"])
  end

  defp frontmatter(front, name) do
    require!(is_map(front), :invalid_skill)
    keys = Map.keys(front)
    require!(Enum.all?(@front_required, &(&1 in keys)), :invalid_skill)
    require!(Enum.all?(keys, &(&1 in (@front_required ++ @front_optional))), :invalid_skill)
    require!(front["name"] === name, :invalid_skill)
    codepoints(front["description"], 1_024)

    if Map.has_key?(front, "license"), do: text(front["license"], 1, 1_024, :invalid_skill)
    if Map.has_key?(front, "compatibility"), do: codepoints(front["compatibility"], 500)

    if Map.has_key?(front, "allowed-tools"),
      do: text(front["allowed-tools"], 0, 4_096, :invalid_skill)

    if Map.has_key?(front, "metadata") do
      metadata = front["metadata"]
      require!(is_map(metadata), :invalid_skill)
      require!(map_size(metadata) <= 32, :too_large)

      Enum.each(metadata, fn {key, value} ->
        text(key, 1, 128, :invalid_skill)
        text(value, 0, 1_024, :invalid_skill)
      end)
    end
  end

  defp codepoints(value, max) do
    require!(is_binary(value) and String.valid?(value), :invalid_skill)
    count = length(String.to_charlist(value))
    require!(count > 0, :invalid_skill)
    require!(count <= max, :too_large)
  end

  # Count compact JSON incrementally before compiling schemas, traversing
  # references or hashing. Each container, including the root, adds one level.
  defp plain(value, depth, bytes) when is_map(value) and not is_struct(value) do
    require!(depth < 32, :too_large)

    Enum.reduce(value, add(bytes, 2 + max(map_size(value) - 1, 0)), fn {key, child}, size ->
      require!(is_binary(key), :invalid_shape)
      plain(child, depth + 1, add(plain(key, depth + 1, size), 1))
    end)
  end

  defp plain(value, depth, bytes) when is_list(value) do
    require!(depth < 32, :too_large)
    list_bytes(value, depth + 1, add(bytes, 2), 0)
  end

  defp plain(value, _, bytes) when is_binary(value) do
    require!(String.valid?(value), :invalid_shape)
    require!(byte_size(value) <= @bytes, :too_large)
    add(bytes, byte_size(Jason.encode!(value)))
  end

  defp plain(value, _, bytes) when is_integer(value) do
    require!(value in -9_223_372_036_854_775_808..9_223_372_036_854_775_807, :invalid_shape)
    scalar(value, bytes)
  end

  defp plain(value, _, bytes) when is_float(value) or value in [true, false, nil],
    do: scalar(value, bytes)

  defp plain(_, _, _), do: fail(:invalid_shape)

  defp list_bytes([], _, bytes, _), do: bytes

  defp list_bytes([head | tail], depth, bytes, comma),
    do: list_bytes(tail, depth, plain(head, depth, add(bytes, comma)), 1)

  defp list_bytes(_, _, _, _), do: fail(:invalid_shape)

  defp scalar(value, bytes) do
    case Jason.encode(value) do
      {:ok, json} -> add(bytes, byte_size(json))
      _ -> fail(:invalid_shape)
    end
  end

  defp add(bytes, count) do
    require!(bytes + count <= @bytes, :too_large)
    bytes + count
  end

  defp identity(map) do
    supplied = map["identity"]

    require!(
      is_binary(supplied) and
        Regex.match?(~r/\Arecipe-package-v1:sha256:[0-9a-f]{64}\z/, supplied),
      :invalid_identity
    )

    digest = :crypto.hash(:sha256, canonical(Map.delete(map, "identity")))
    expected = "recipe-package-v1:sha256:" <> Base.encode16(digest, case: :lower)
    require!(supplied === expected, :invalid_identity)
  end

  # Binary order is ascending UTF-8 bytes, not RFC 8785's UTF-16 order.
  defp canonical(value) when is_map(value) do
    members =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, child} -> [Jason.encode!(key), ?:, canonical(child)] end)

    [?{, Enum.intersperse(members, ?,), ?}]
  end

  defp canonical(value) when is_list(value),
    do: [?[, Enum.intersperse(Enum.map(value, &canonical/1), ?,), ?]]

  defp canonical(value), do: Jason.encode!(value)
end
