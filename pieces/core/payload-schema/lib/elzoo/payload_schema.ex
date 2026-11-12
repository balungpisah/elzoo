# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PayloadSchema do
  @moduledoc """
  Caller-owned JSON Schema checking bound to a Port direction and schema pair.
  Payloads are retained, not cast. Violations expose only redacted structural
  paths, never JSV errors. Bounds do not limit validator time or allocation.
  """

  @doc "Build a checked schema from an exact Port and a host-approved decoded schema object."
  def build(port, schema) do
    with {:ok, {:Descriptor, _, direction, id, version}} <- Elzoo.Port.decode(port) do
      if is_map(schema) and not is_struct(schema) and
           (not Map.has_key?(schema, "$schema") or
              schema["$schema"] == "https://json-schema.org/draft/2020-12/schema") and
           local_schema?(schema) do
        case JSV.build(schema,
               resolver: [],
               formats: false,
               atoms: false,
               warnings: :silence
             ) do
          {:ok, root} -> {:ok, {__MODULE__, direction, id, version, root}}
          _ -> {:error, :invalid_schema}
        end
      else
        {:error, :invalid_schema}
      end
    else
      _ -> {:error, :invalid_port}
    end
  rescue
    _ -> {:error, :invalid_schema}
  catch
    _, _ -> {:error, :invalid_schema}
  end

  @doc "Check binding, JSON representation, depth, compact size, then schema, in that order."
  def check({__MODULE__, direction, id, version, root}, port, payload) do
    case Elzoo.Port.decode(port) do
      {:ok, {:Descriptor, _, ^direction, ^id, ^version}} -> check_payload(root, payload)
      {:ok, {:Descriptor, _, ^direction, ^id, _}} -> {:error, :version_mismatch}
      {:ok, _} -> {:error, :port_mismatch}
      _ -> {:error, :invalid_port}
    end
  end

  # Also refuses reserved reference keys in literal schema data. No executable
  # schema normalization or resolver is reached before this scan succeeds.
  defp local_schema?(%{} = map) when not is_struct(map) do
    Enum.all?(map, fn
      {key, value} when is_binary(key) ->
        String.valid?(key) and
          case {key, value} do
            {ref, "#" <> _} when ref in ["$ref", "$dynamicRef"] -> String.valid?(value)
            {ref, _} when ref in ["$ref", "$dynamicRef"] -> false
            _ -> local_schema?(value)
          end

      _ ->
        false
    end)
  end

  defp local_schema?(list) when is_list(list), do: Enum.all?(list, &local_schema?/1)
  defp local_schema?(value) when is_binary(value), do: String.valid?(value)
  defp local_schema?(value) when is_number(value) or value in [nil, true, false], do: true
  defp local_schema?(_), do: false

  defp check_payload(root, payload) do
    with :ok <- representation(payload, 0),
         {:ok, json} <- Jason.encode(payload) do
      if byte_size(json) <= 65_536 do
        validate(root, payload)
      else
        {:error, :too_large}
      end
    else
      {:error, reason} when reason in [:invalid_payload, :too_deep] -> {:error, reason}
      _ -> {:error, :invalid_payload}
    end
  end

  defp representation(value, depth) when is_map(value) and not is_struct(value) do
    if depth == 32 do
      {:error, :too_deep}
    else
      Enum.reduce_while(value, :ok, fn {key, child}, :ok ->
        result =
          if is_binary(key) and String.valid?(key),
            do: representation(child, depth + 1),
            else: {:error, :invalid_payload}

        case result do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp representation(value, depth) when is_list(value) do
    if depth == 32, do: {:error, :too_deep}, else: list_values(value, depth + 1)
  end

  defp representation(value, _) when is_binary(value) do
    if String.valid?(value), do: :ok, else: {:error, :invalid_payload}
  end

  defp representation(value, _) when is_number(value) or value in [nil, true, false], do: :ok
  defp representation(_, _), do: {:error, :invalid_payload}

  defp list_values([], _), do: :ok

  defp list_values([head | tail], depth) do
    with :ok <- representation(head, depth), do: list_values(tail, depth)
  end

  defp list_values(_, _), do: {:error, :invalid_payload}

  defp validate(root, payload) do
    case JSV.validate(payload, root, cast: false) do
      {:ok, _discarded} ->
        :ok

      {:error, %JSV.ValidationError{errors: [_ | _] = errors}} ->
        violations =
          errors
          |> Enum.reverse()
          |> Enum.take(16)
          |> Enum.map(fn %JSV.Validator.Error{data_path: reversed} ->
            path =
              reversed
              |> Enum.reverse()
              |> Enum.take(32)
              |> Enum.map(fn
                key when is_binary(key) -> :key
                index when is_integer(index) and index >= 0 -> index
              end)

            %{path: path, code: :schema_mismatch}
          end)

        {:error, {:violations, violations}}

      _ ->
        {:error, :validation_failed}
    end
  rescue
    _ -> {:error, :validation_failed}
  catch
    _, _ -> {:error, :validation_failed}
  end
end
