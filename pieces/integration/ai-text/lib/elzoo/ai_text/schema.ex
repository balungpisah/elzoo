# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.Schema do
  @moduledoc """
  JSON Schema compilation and validation through `jsv` (draft 2020-12), with no
  remote reference resolution: a schema that needs a resolver fails to build and
  the request is refused `:invalid_request`. Validation never casts or creates
  atoms; the caller keeps the original value.
  """

  @doc "Compiles a decoded JSON Schema object."
  def build(schema) when is_map(schema) do
    case JSV.build(schema, resolver: [], formats: false, atoms: false) do
      {:ok, root} -> {:ok, root}
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  def build(_), do: {:error, :invalid_request}

  @doc "`:ok` when `value` validates against the compiled root, else `{:error, :schema_mismatch}`."
  def validate(value, root) do
    case JSV.validate(value, root, cast: false) do
      {:ok, _} -> :ok
      _ -> {:error, :schema_mismatch}
    end
  rescue
    _ -> {:error, :schema_mismatch}
  catch
    _, _ -> {:error, :schema_mismatch}
  end
end
