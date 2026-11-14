# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaBinding do
  @moduledoc """
  Pure resolution of the module functions that a recipe declares against the
  manifests that the caller supplies, with a check of the arguments of a call
  and of its result. Calls no function, runs no Lua and discovers nothing.
  Bindings are the tagged plain term `{:LuaBinding, entries}`; only `resolve/2`
  makes one. See the bundle README.
  """
  alias Elzoo.{PayloadSchema, ToolRegistry}

  @manifest_keys ~w(arguments cost description name permissions result version)
  @max_declared 64
  @max_manifests 256
  @max_permissions 64
  @max_version 2_147_483_647
  @max_estimate 9_007_199_254_740_992

  @doc "Resolve a declaration against the manifests; `{:ok, bindings}` or `{:refused, reasons}`."
  def resolve(declaration, manifests) do
    with {:ok, declared} <- declared(declaration),
         {:ok, listed} <- listed(manifests) do
      outcomes = Enum.map(declared, &outcome(&1, listed))

      case for({:error, reason} <- outcomes, do: reason) do
        [] ->
          {:ok, {:LuaBinding, Map.new(for {:ok, name, entry} <- outcomes, do: {name, entry})}}

        reasons ->
          {:refused, Enum.sort_by(reasons, &{&1.name, &1.code})}
      end
    else
      :error -> {:error, :invalid_input}
    end
  end

  @doc "The declared names, sorted."
  def names({:LuaBinding, entries}) when is_map(entries), do: entries |> Map.keys() |> Enum.sort()
  def names(_), do: {:error, :invalid_input}

  @doc "`lua-binding-v1:sha256:` and the lowercase hex SHA-256 of the canonical resolved manifests."
  def identity({:LuaBinding, entries}) when is_map(entries) do
    manifests = for {_, entry} <- Enum.sort_by(entries, &elem(&1, 0)), do: entry.manifest

    "lua-binding-v1:sha256:" <>
      Base.encode16(:crypto.hash(:sha256, canonical(manifests)), case: :lower)
  end

  def identity(_), do: {:error, :invalid_input}

  @doc "Check the plain arguments of a call against the arguments schema of the function."
  def check_arguments(bindings, name, arguments), do: check(bindings, name, :arguments, arguments)

  @doc "Check the plain result of a call against the result schema of the function."
  def check_result(bindings, name, result), do: check(bindings, name, :result, result)

  @doc "The cost that the manifest of the function states."
  def cost({:LuaBinding, entries}, name) when is_map(entries) do
    case entries do
      %{^name => %{manifest: %{"cost" => cost}}} -> {:ok, cost}
      _ -> {:error, :unknown_function}
    end
  end

  def cost(_, _), do: {:error, :invalid_input}

  @doc "The sorted union of the permissions of the resolved functions."
  def permissions({:LuaBinding, entries}) when is_map(entries) do
    entries
    |> Enum.flat_map(fn {_, entry} -> entry.manifest["permissions"] end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def permissions(_), do: {:error, :invalid_input}

  @doc "One tool-registry source with one descriptor for each resolved function."
  def source({:LuaBinding, entries}, id) when is_map(entries) do
    if is_binary(id) and String.match?(id, ~r/\A[a-zA-Z0-9_-]{1,32}\z/) do
      tools =
        for {name, entry} <- Enum.sort_by(entries, &elem(&1, 0)) do
          %{
            "trust" => "untrusted",
            "name" => name,
            "description" => entry.manifest["description"],
            "annotations" => %{},
            "input_schema" => entry.manifest["arguments"]["schema"]
          }
        end

      source = %{"id" => id, "kind" => "other", "callable" => "adapter", "tools" => tools}

      case ToolRegistry.snapshot([source]) do
        {:ok, _} -> {:ok, source}
        _ -> {:error, :invalid_input}
      end
    else
      {:error, :invalid_input}
    end
  end

  def source(_, _), do: {:error, :invalid_input}

  defp check({:LuaBinding, entries}, name, side, value) when is_map(entries) do
    case entries do
      %{^name => %{manifest: manifest}} ->
        %{"port" => port, "schema" => schema} = manifest[Atom.to_string(side)]

        # The schema is built here, not kept: bindings stay plain data.
        with {:ok, built} <- PayloadSchema.build(port, schema),
             :ok <- PayloadSchema.check(built, port, value) do
          :ok
        else
          {:error, {:violations, violations}} ->
            {:refused, %{name: name, violations: violations}}

          {:error, reason} ->
            {:refused, %{name: name, violations: [%{path: [], code: reason}]}}
        end

      _ ->
        {:error, :unknown_function}
    end
  end

  defp check(_, _, _, _), do: {:error, :invalid_input}

  # A declaration: at most 64 exact {name, version} maps with unique names.
  defp declared(declaration) do
    with {:ok, list} <- bounded(declaration, @max_declared),
         true <- Enum.all?(list, &declared_entry?/1),
         names = Enum.map(list, & &1["name"]),
         true <- length(Enum.uniq(names)) == length(names) do
      {:ok, Enum.map(list, &{&1["name"], &1["version"]})}
    else
      _ -> :error
    end
  end

  defp declared_entry?(%{"name" => name, "version" => version} = entry)
       when map_size(entry) == 2 and not is_struct(entry),
       do: binding_name?(name) and version?(version)

  defp declared_entry?(_), do: false

  # Of every manifest only name and version are read here, to match it.
  defp listed(manifests) do
    with {:ok, list} <- bounded(manifests, @max_manifests),
         true <- Enum.all?(list, &(is_map(&1) and not is_struct(&1))),
         true <- Enum.all?(list, &(binding_name?(&1["name"]) and version?(&1["version"]))),
         keys = Enum.map(list, &{&1["name"], &1["version"]}),
         true <- length(Enum.uniq(keys)) == length(keys) do
      {:ok, list}
    else
      _ -> :error
    end
  end

  defp outcome({name, version}, listed) do
    case Enum.filter(listed, &(&1["name"] == name)) do
      [] ->
        {:error, %{name: name, code: :unknown_function}}

      same_name ->
        case Enum.find(same_name, &(&1["version"] == version)) do
          nil ->
            {:error, %{name: name, code: :wrong_version}}

          manifest ->
            case checked(manifest) do
              {:ok, entry} -> {:ok, name, entry}
              :error -> {:error, %{name: name, code: :invalid_manifest}}
            end
        end
    end
  end

  defp checked(manifest) do
    with true <- Enum.sort(Map.keys(manifest)) == @manifest_keys,
         true <- text?(manifest["description"], 1_024),
         true <- cost?(manifest["cost"]),
         true <- permissions?(manifest["permissions"]),
         :ok <- operand(manifest["arguments"], "input"),
         :ok <- operand(manifest["result"], "output"),
         true <- object_schema?(manifest["arguments"]["schema"]) do
      {:ok, %{manifest: manifest}}
    else
      _ -> :error
    end
  end

  defp operand(%{"port" => port, "schema" => schema} = operand, direction)
       when map_size(operand) == 2 and is_map(port) and not is_struct(port) do
    with true <- Map.get(port, "direction") == direction,
         {:ok, _built} <- PayloadSchema.build(port, schema) do
      :ok
    else
      _ -> :error
    end
  end

  defp operand(_, _), do: :error

  defp object_schema?(schema),
    do: schema["type"] == "object" and schema["additionalProperties"] === false

  defp cost?(%{"unit" => unit, "estimate" => estimate} = cost) when map_size(cost) == 2,
    do: text?(unit, 128) and is_integer(estimate) and estimate >= 1 and estimate <= @max_estimate

  defp cost?(_), do: false

  defp permissions?(permissions) do
    case bounded(permissions, @max_permissions) do
      {:ok, list} -> Enum.all?(list, &text?(&1, 128)) and length(Enum.uniq(list)) == length(list)
      :error -> false
    end
  end

  defp text?(value, max),
    do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..max//1

  defp binding_name?(name),
    do: is_binary(name) and String.match?(name, ~r/\A[a-z][a-z0-9_]{0,63}\z/)

  defp version?(version), do: is_integer(version) and version >= 1 and version <= @max_version

  # A proper list of at most `max` elements.
  defp bounded(list, max), do: bounded(list, max, [])
  defp bounded([], _max, acc), do: {:ok, Enum.reverse(acc)}
  defp bounded([head | tail], max, acc) when max > 0, do: bounded(tail, max - 1, [head | acc])
  defp bounded(_, _, _), do: :error

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
