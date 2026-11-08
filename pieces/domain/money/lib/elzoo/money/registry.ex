# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Money.Registry do
  @moduledoc """
  The closed, versioned ISO 4217 registry held by this bundle revision.

  Built at compile time by `Elzoo.Money.Registry.Source.build!/1` from the
  dated extracts in `iso4217/` beside this file; no literal is edited by hand.
  A registry value has `versions` (oldest first), one `snapshots` map per
  version (`alpha => entry`), the version's active numeric index and the source
  headers. Pass another value built by `build!/1` through the `registry:`
  option of `Elzoo.Money` functions.
  """
  alias Elzoo.Money.Registry.Source

  @extracts Path.wildcard(Path.join([__DIR__, "iso4217", "*.tsv"])) |> Enum.sort()
  for path <- @extracts, do: @external_resource(path)
  @default Source.build!(Enum.map(@extracts, &File.read!/1))

  @doc "The registry compiled from the held extracts."
  def default, do: @default

  @doc "Build a registry from extract texts (see `Elzoo.Money.Registry.Source`)."
  defdelegate build!(texts), to: Source

  @doc "The newest held version id."
  def latest(%{versions: versions}), do: List.last(versions)

  @doc "The entry for `alpha` in `version`, or nil."
  def entry(registry, version, alpha), do: get_in(registry, [:snapshots, version, alpha])

  @doc "Whether `version` is held."
  def held?(registry, version), do: Map.has_key?(registry.snapshots, version)
end
