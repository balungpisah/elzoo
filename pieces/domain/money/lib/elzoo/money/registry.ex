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

  @doc """
  Whether `registry` has the shape `build!/1` writes, for every field that
  `Elzoo.Money` reads. Pure. A value `===` `default/0` is not walked; any
  other value is walked in full: exactly the keys `versions`, `snapshots`,
  `active_numeric` and `sources`; `versions` a non-empty list of distinct
  `YYYY-MM-DD` binaries, oldest first; the other three maps keyed by exactly
  those versions; each snapshot a plain map from a three-letter alpha code
  to a plain entry map with that `alpha`, `numeric` an integer 0..999 or nil,
  `minor_unit` an integer 0..99 or an atom, `status` `:active` or
  `{:retired, _}` and `rows` a list of maps with `numeric` an integer 0..999
  or nil; no two active entries share a numeric code; and each
  `active_numeric` value is exactly the map from the numeric code of each
  active entry to its alpha; and every alpha of a version is held by each
  later version (append-only).
  """
  def valid?(registry), do: registry === default() or walk?(registry)

  defp walk?(%{versions: [_ | _] = versions, snapshots: s, active_numeric: a, sources: src} = r)
       when map_size(r) == 4 and is_map(s) and is_map(a) and is_map(src) do
    ascending?(versions) and keyed?(s, versions) and keyed?(a, versions) and
      keyed?(src, versions) and
      Enum.all?(versions, &snapshot?(Map.fetch!(s, &1), Map.fetch!(a, &1))) and
      retained?(Enum.map(versions, &Map.fetch!(s, &1)))
  end

  defp walk?(_), do: false

  defp ascending?([v]), do: version?(v)
  defp ascending?([v, w | rest]), do: version?(v) and v < w and ascending?([w | rest])
  defp ascending?(_), do: false

  defp version?(v), do: is_binary(v) and Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, v)

  # The versions list is distinct (ascending), so equal sizes and every
  # version present mean the keys are exactly the versions.
  defp keyed?(map, versions),
    do: map_size(map) == length(versions) and Enum.all?(versions, &is_map_key(map, &1))

  defp snapshot?(snapshot, index)
       when is_map(snapshot) and not is_struct(snapshot) and is_map(index) do
    if Enum.all?(snapshot, &entry?/1) do
      pairs =
        for {alpha, %{status: :active, numeric: n}} <- snapshot, is_integer(n), do: {n, alpha}

      active = Map.new(pairs)
      map_size(active) == length(pairs) and active === index
    else
      false
    end
  end

  defp snapshot?(_, _), do: false

  # Append-only, as build!/1 folds: every alpha of a version is held by each
  # later one (current_status/2 reads the newest entry of an older member).
  defp retained?([older, newer | rest]),
    do:
      Enum.all?(older, fn {alpha, _} -> is_map_key(newer, alpha) end) and retained?([newer | rest])

  defp retained?(_), do: true

  defp entry?({<<a, b, c>> = alpha, %{alpha: alpha, numeric: n, minor_unit: m, status: s} = e})
       when a in ?A..?Z and b in ?A..?Z and c in ?A..?Z and not is_struct(e) and
              (is_atom(m) or (is_integer(m) and m in 0..99)) do
    numeric?(n) and status?(s) and rows?(Map.get(e, :rows))
  end

  defp entry?(_), do: false

  defp numeric?(n), do: is_nil(n) or (is_integer(n) and n in 0..999)

  defp status?(:active), do: true
  defp status?({:retired, _}), do: true
  defp status?(_), do: false

  defp rows?([]), do: true
  defp rows?([%{numeric: n} | rest]), do: numeric?(n) and rows?(rest)
  defp rows?(_), do: false

  @doc "The newest held version id."
  def latest(%{versions: versions}), do: List.last(versions)

  @doc "The entry for `alpha` in `version`, or nil."
  def entry(registry, version, alpha), do: get_in(registry, [:snapshots, version, alpha])

  @doc "Whether `version` is held."
  def held?(registry, version), do: Map.has_key?(registry.snapshots, version)
end
