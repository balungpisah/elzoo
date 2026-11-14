# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeConfig do
  @moduledoc """
  Pure check of tenant settings against a caller-supplied versioned schema
  descriptor. Secret settings are credential references, never values; nothing
  is resolved. Schema compilation and validation are the ready
  `Elzoo.PayloadSchema`. Failures are fixed tags only; see the README.
  """

  @keys ["id", "port", "revision", "schema", "secrets", "version"]
  @max_revision 2_147_483_647
  @reference %{
    "type" => "object",
    "properties" => %{
      "ref" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
      "scope" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}
    },
    "additionalProperties" => false
  }

  @doc "Build a checked schema from an exact version 1 descriptor."
  def build(descriptor) do
    with :ok <- bounded(descriptor, :invalid_descriptor),
         :ok <- version(descriptor),
         :ok <- descriptor(descriptor),
         :ok <- settings_schema(descriptor["schema"], descriptor["secrets"]) do
      %{"id" => id, "revision" => revision, "port" => port, "schema" => schema} = descriptor

      case Elzoo.PayloadSchema.build(port, schema) do
        {:ok, checked} ->
          {:ok, {__MODULE__, {id, revision, 1}, port, descriptor["secrets"], checked}}

        {:error, :invalid_port} ->
          {:error, :invalid_descriptor}

        _ ->
          {:error, :invalid_schema}
      end
    end
  end

  @doc "Check settings: bounds, then secret reference shape, then the ready schema check."
  def check({__MODULE__, _identity, port, secrets, checked}, settings) do
    with :ok <- bounded(settings, :invalid_settings),
         :ok <- references(settings, secrets) do
      case Elzoo.PayloadSchema.check(checked, port, settings) do
        :ok -> {:ok, settings}
        {:error, :validation_failed} -> {:error, :validation_failed}
        _ -> {:error, :invalid_settings}
      end
    end
  end

  def check(_, _), do: {:error, :validation_failed}

  defp version(%{"version" => version}) when is_integer(version) and version != 1,
    do: {:error, :unsupported_version}

  defp version(_), do: :ok

  defp descriptor(%{"id" => id, "revision" => revision, "port" => port, "secrets" => secrets} = d)
       when map_size(d) == 6 and is_integer(revision) and revision in 1..@max_revision and
              is_map(port) and is_list(secrets) and length(secrets) <= 64 do
    if Enum.sort(Map.keys(d)) == @keys and d["version"] === 1 and name?(id) and
         port["direction"] == "input" and Enum.all?(secrets, &is_binary/1) and
         length(Enum.uniq(secrets)) == length(secrets),
       do: :ok,
       else: {:error, :invalid_descriptor}
  end

  defp descriptor(_), do: {:error, :invalid_descriptor}

  defp settings_schema(
         %{"type" => "object", "properties" => properties, "additionalProperties" => false} =
           schema,
         secrets
       )
       when is_map(properties) and map_size(properties) <= 64 do
    cond do
      Map.has_key?(schema, "patternProperties") or Map.has_key?(schema, "unevaluatedProperties") or
          not Enum.all?(Map.keys(properties), &name?/1) ->
        {:error, :invalid_schema}

      not Enum.all?(secrets, &Map.has_key?(properties, &1)) ->
        {:error, :invalid_descriptor}

      Enum.all?(secrets, &reference_schema?(properties[&1])) ->
        :ok

      true ->
        {:error, :invalid_schema}
    end
  end

  defp settings_schema(_, _), do: {:error, :invalid_schema}

  defp reference_schema?(%{"required" => required} = schema) when is_list(required) do
    Enum.sort(required) === ["ref", "scope"] and Map.delete(schema, "required") === @reference
  end

  defp reference_schema?(_), do: false

  defp name?(name), do: is_binary(name) and byte_size(name) in 1..128 and String.valid?(name)

  defp references(settings, secrets) when is_map(settings) do
    if Enum.all?(secrets, &(not Map.has_key?(settings, &1) or reference?(settings[&1]))),
      do: :ok,
      else: {:error, :invalid_secret}
  end

  defp references(_, _), do: :ok

  defp reference?(%{"ref" => ref, "scope" => scope} = reference),
    do: map_size(reference) == 2 and identifier?(ref) and identifier?(scope)

  defp reference?(_), do: false

  defp identifier?(value), do: is_binary(value) and byte_size(value) in 1..128

  # Plain JSON data, container depth at most 32 and compact JSON at most 65,536
  # bytes, with the same counting as core/payload-schema.
  defp bounded(value, invalid) do
    with :ok <- plain(value, 0),
         {:ok, json} <- Jason.encode(value) do
      if byte_size(json) <= 65_536, do: :ok, else: bound_error(:too_large, invalid)
    else
      {:error, :too_deep} -> bound_error(:too_deep, invalid)
      _ -> {:error, invalid}
    end
  end

  defp bound_error(_, :invalid_descriptor), do: {:error, :invalid_descriptor}
  defp bound_error(reason, _), do: {:error, reason}

  defp plain(value, depth) when is_map(value) and not is_struct(value) do
    cond do
      depth == 32 ->
        {:error, :too_deep}

      Enum.all?(Map.keys(value), &(is_binary(&1) and String.valid?(&1))) ->
        all(Map.values(value), depth + 1)

      true ->
        {:error, :invalid}
    end
  end

  defp plain(value, depth) when is_list(value) do
    cond do
      depth == 32 -> {:error, :too_deep}
      proper?(value) -> all(value, depth + 1)
      true -> {:error, :invalid}
    end
  end

  defp plain(value, _) when is_binary(value),
    do: if(String.valid?(value), do: :ok, else: {:error, :invalid})

  defp plain(value, _) when is_number(value) or value in [nil, true, false], do: :ok
  defp plain(_, _), do: {:error, :invalid}

  defp all(values, depth) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case plain(value, depth) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp proper?([]), do: true
  defp proper?([_ | tail]), do: proper?(tail)
  defp proper?(_), do: false
end
