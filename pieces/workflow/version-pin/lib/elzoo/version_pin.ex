# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.VersionPin do
  @moduledoc "Pure rule: the recipe version and the tool sources that one Run keeps. See the bundle README."
  alias Elzoo.ToolRegistry

  @identity_bytes 89
  @identity ~r/\Arecipe-package-v1:sha256:[0-9a-f]{64}\z/
  @source_id ~r/\A[a-zA-Z0-9_-]{1,32}\z/
  @kept ~w(id kind callable)

  @doc "Pins the version and the sources of one Run at its start."
  def new(version, sources) do
    with true <- identity?(version),
         {:ok, _} <- ToolRegistry.snapshot(sources) do
      {:ok, %{version: version, sources: Enum.map(sources, &Map.take(&1, @kept))}}
    else
      _ -> {:error, :invalid_input}
    end
  end

  @doc "The pinned package identity."
  def version(%{version: version}), do: version

  @doc "The captured `id`, `kind` and `callable` of each source, in the order given."
  def sources(%{sources: sources}), do: sources

  @doc "One input of the host. Always `{:Transition, pin, {:some, result}}`."
  def step(%{version: version, sources: sources} = pin, input) do
    {class, offered_version, offered_source} = classify(input, version, sources)
    result = cure(:decide, [class])

    pin = %{
      pin
      | version: cure(:next_version, [version, offered_version, result]),
        sources: cure(:next_sources, [sources, offered_source, result])
    }

    {:Transition, pin, {:some, term(result, version, offered_version)}}
  end

  # Classification only: operands are checked and sorted into the closed set of Cure classes.
  defp classify({:change_version, id}, version, _) do
    cond do
      not identity?(id) -> {kept(:RefusedInput), version, nil}
      id == version -> {kept(:ChangeSame), id, nil}
      true -> {:ChangeDifferent, id, nil}
    end
  end

  defp classify({:published, id}, version, _) do
    if identity?(id),
      do: {kept(:PublishedInput), id, nil},
      else: {kept(:RefusedInput), version, nil}
  end

  defp classify(:settings_changed, version, _), do: {kept(:SettingsInput), version, nil}

  defp classify({:listing, id}, version, sources) do
    cond do
      not source_id?(id) -> {kept(:RefusedInput), version, nil}
      Enum.any?(sources, &(&1["id"] == id)) -> {kept(:ListingKnown), version, nil}
      true -> {kept(:ListingUnknown), version, nil}
    end
  end

  defp classify({:add_source, term}, version, _), do: {kept(:AddSourceInput), version, term}
  defp classify(_, version, _), do: {kept(:RefusedInput), version, nil}

  defp term(:PinChanged, old, new), do: {:changed, old, new}
  defp term(:PinUnchanged, _, _), do: :unchanged
  defp term(:PinKnown, _, _), do: :known_source
  defp term(:PinOutside, _, _), do: {:refused, :outside_source}
  defp term(:PinClosed, _, _), do: {:refused, :source_set_closed}
  defp term(:PinInvalid, _, _), do: {:refused, :invalid_input}

  defp kept(class), do: {:KeepsVersion, class}
  defp cure(function, args), do: apply(:"Cure.Elzoo.VersionPin", function, args)

  defp identity?(value),
    do: is_binary(value) and byte_size(value) == @identity_bytes and Regex.match?(@identity, value)

  defp source_id?(value),
    do: is_binary(value) and byte_size(value) <= 32 and Regex.match?(@source_id, value)
end
