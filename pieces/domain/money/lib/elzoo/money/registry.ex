# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Money.Registry do
  @moduledoc """
  The closed, versioned ISO 4217 registry held by this bundle revision.

  Built at compile time by `Elzoo.Money.Registry.Source.build!/1` from the
  dated extracts in `iso4217/` beside this file; no literal is edited by hand.
  A registry value has `versions` (oldest first), one `snapshots` map per
  version (`alpha => entry`), the version's active numeric index and the source
  headers. Pass another value built by `build!/1` through the `registry:`
  option of `Elzoo.Money` functions, either raw (walked by `valid?/1` on
  every call) or as the checked value `check/1` returns (a constant-time test).
  """
  alias Elzoo.Money.Registry.Source

  defmodule Checked do
    @moduledoc """
    An opaque registry that `Elzoo.Money.Registry.check/1` walked once. It
    holds the registry only inside a closure that `Elzoo.Money.Registry` made;
    a value of this shape with any other closure is refused.
    """
    @enforce_keys [:read]
    defstruct @enforce_keys
  end

  @extracts Path.wildcard(Path.join([__DIR__, "iso4217", "*.tsv"])) |> Enum.sort()
  for path <- @extracts, do: @external_resource(path)
  @default Source.build!(Enum.map(@extracts, &File.read!/1))

  # The compiler's name of the closure in seal/1. A test compares it with the
  # name of a genuine checked value.
  @sealed :"-seal/1-fun-0-"

  @doc "The registry compiled from the held extracts."
  def default, do: @default

  @doc "Build a registry from extract texts (see `Elzoo.Money.Registry.Source`)."
  defdelegate build!(texts), to: Source

  @doc """
  Walk `registry` once with `valid?/1`: `{:ok, checked}` with an opaque
  `Elzoo.Money.Registry.Checked`, else `{:error, {:invalid_registry, nil}}`.
  Pure. Pass `checked` as `registry:` to skip the walk on each call. The
  compiled default also gives a checked value; a genuine checked value gives
  `{:ok, same}` in constant time.
  """
  def check(registry) do
    cond do
      sealed?(registry) -> {:ok, registry}
      valid?(registry) -> {:ok, seal(registry)}
      true -> {:error, {:invalid_registry, nil}}
    end
  end

  defp seal(registry), do: %Checked{read: fn -> registry end}

  # Constant time: the struct check/1 returns, holding the closure of seal/1
  # (module, local type, arity 0 and its compiler name). Never calls the closure.
  defp sealed?(%Checked{read: read}) when is_function(read) do
    :erlang.fun_info(read, :module) == {:module, __MODULE__} and
      :erlang.fun_info(read, :type) == {:type, :local} and
      :erlang.fun_info(read, :arity) == {:arity, 0} and
      :erlang.fun_info(read, :name) == {:name, @sealed}
  end

  defp sealed?(_), do: false

  @doc false
  # The registry of a genuine checked value; any other term unchanged and
  # unchecked. Every positional function reads its registry through this.
  def unwrap(registry), do: if(sealed?(registry), do: registry.read.(), else: registry)

  @doc false
  # The one check of a registry: option, deciding once: the default by ===, a
  # checked value by sealed?/1 (then its registry), any other term by the walk.
  def resolve(registry) do
    cond do
      registry === default() -> {:ok, registry}
      sealed?(registry) -> {:ok, registry.read.()}
      walk?(registry) -> {:ok, registry}
      true -> {:error, {:invalid_registry, nil}}
    end
  end

  @doc """
  Whether `registry` has the shape `build!/1` writes, for every field that
  `Elzoo.Money` reads. Pure. A value `===` `default/0` and a genuine checked
  value of `check/1` are not walked; any
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
  def valid?(registry), do: match?({:ok, _}, resolve(registry))

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

  # Positional functions do not validate: a genuine checked value is unwrapped,
  # any other value is read as given.

  @doc "The held version ids, oldest first."
  def versions(registry), do: held_versions(unwrap(registry))

  defp held_versions(%{versions: versions}), do: versions

  @doc "The newest held version id."
  def latest(registry), do: List.last(versions(registry))

  @doc "The entry for `alpha` in `version`, or nil."
  def entry(registry, version, alpha), do: get_in(unwrap(registry), [:snapshots, version, alpha])

  @doc "Whether `version` is held."
  def held?(registry, version), do: Map.has_key?(unwrap(registry).snapshots, version)
end
