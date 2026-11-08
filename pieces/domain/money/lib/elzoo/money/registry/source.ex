# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Money.Registry.Source do
  @moduledoc """
  Parse the dated ISO 4217 extracts and fold them into an append-only registry.

  Pure: takes extract texts, returns a registry value or raises `ArgumentError`
  on a malformed extract or a fold that would break a registry rule. Rules
  (ELZ-031 proposal §3.3–3.5): every current row with a code gives an active
  identity; `N.A.` stays `:not_applicable`; a historic-only code is retired and
  keeps an exponent recorded by a prior version, else `:not_recorded`; a code
  known before and absent now is retained as retired; no entry is ever removed;
  active numeric codes are unique within a version.
  """

  @format "# elzoo domain/money ISO 4217 derived extract, format 1"
  @columns "table\talpha\tnumeric\tminor_unit\twithdrawal\tfund"
  @required ~w(version current_source current_published current_sha256 historic_source historic_published historic_sha256 downloaded columns)

  @doc "Parse one extract text."
  def parse!(text) when is_binary(text) do
    lines = String.split(text, "\n", trim: true)
    if List.first(lines) != @format, do: raise(ArgumentError, "not a format-1 extract")

    header =
      for "# " <> line <- lines, [key, value] <- [String.split(line, "\t", parts: 2)], into: %{},
        do: {key, value}

    for key <- @required,
        do: if(not is_binary(header[key]), do: raise(ArgumentError, "extract header lacks #{key}"))

    if header["columns"] != @columns, do: raise(ArgumentError, "unexpected extract columns")

    if header["version"] != header["current_published"],
      do: raise(ArgumentError, "extract version must equal current_published")

    if not Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, header["version"]),
      do: raise(ArgumentError, "extract version must be YYYY-MM-DD")

    rows = lines |> Enum.reject(&String.starts_with?(&1, "#")) |> Enum.map(&row!/1)

    %{
      version: header["version"],
      header: header,
      current: Enum.filter(rows, &(&1.table == :current)),
      historic: Enum.filter(rows, &(&1.table == :historic))
    }
  end

  defp row!(line) do
    case String.split(line, "\t") do
      [table, alpha, numeric, minor, withdrawal, fund] when fund in ["true", "false"] ->
        row = %{
          table: table!(table),
          alpha: optional(alpha, ~r/\A[A-Z]{3}\z/, & &1),
          numeric: optional(numeric, ~r/\A\d{3}\z/, &String.to_integer/1),
          minor_unit: minor!(minor),
          withdrawal: if(withdrawal == "", do: nil, else: withdrawal),
          fund: fund == "true"
        }

        check_row!(row, line)

      _ ->
        raise ArgumentError, "malformed extract row: #{inspect(line)}"
    end
  end

  defp table!("current"), do: :current
  defp table!("historic"), do: :historic
  defp table!(other), do: raise(ArgumentError, "unknown extract table #{inspect(other)}")

  defp optional("", _, _), do: nil

  defp optional(value, pattern, convert) do
    if Regex.match?(pattern, value),
      do: convert.(value),
      else: raise(ArgumentError, "malformed extract field #{inspect(value)}")
  end

  defp minor!(""), do: nil
  defp minor!("N.A."), do: :not_applicable

  defp minor!(digits) do
    if Regex.match?(~r/\A\d{1,2}\z/, digits),
      do: String.to_integer(digits),
      else: raise(ArgumentError, "malformed minor unit #{inspect(digits)}")
  end

  # A current row either names a currency with all three fields, or none (a
  # country row "No universal currency"). A historic row names an alpha code and
  # a withdrawal text and never a minor unit.
  defp check_row!(%{table: :current} = row, line) do
    fields = [row.alpha, row.numeric, row.minor_unit]
    ok = (Enum.all?(fields, &(&1 != nil)) or Enum.all?(fields, &is_nil/1)) and is_nil(row.withdrawal)
    if ok, do: row, else: raise(ArgumentError, "inconsistent current row: #{inspect(line)}")
  end

  defp check_row!(%{table: :historic} = row, line) do
    ok = row.alpha != nil and row.withdrawal != nil and is_nil(row.minor_unit)
    if ok, do: row, else: raise(ArgumentError, "inconsistent historic row: #{inspect(line)}")
  end

  @doc "Fold extract texts (any order) into a registry, oldest version first."
  def build!(texts) when is_list(texts) and texts != [] do
    parsed = texts |> Enum.map(&parse!/1) |> Enum.sort_by(& &1.version)
    versions = Enum.map(parsed, & &1.version)

    if length(Enum.uniq(versions)) != length(versions),
      do: raise(ArgumentError, "duplicate extract version")

    {snapshots, _} =
      Enum.map_reduce(parsed, %{}, fn extract, previous ->
        snapshot = step!(previous, extract)
        {{extract.version, snapshot}, snapshot}
      end)

    snapshots = Map.new(snapshots)

    %{
      versions: versions,
      snapshots: snapshots,
      active_numeric: Map.new(snapshots, fn {v, s} -> {v, active_numeric!(v, s)} end),
      sources: Map.new(parsed, &{&1.version, &1.header})
    }
  end

  defp step!(previous, extract) do
    current = Enum.group_by(Enum.filter(extract.current, & &1.alpha), & &1.alpha)
    historic = Enum.group_by(extract.historic, & &1.alpha)

    active =
      Map.new(current, fn {alpha, rows} ->
        identity = rows |> Enum.map(&{&1.numeric, &1.minor_unit}) |> Enum.uniq()

        case identity do
          [{numeric, minor}] ->
            {alpha,
             entry(alpha, numeric, minor, :active, rows ++ Map.get(historic, alpha, []), false)}

          _ ->
            raise ArgumentError, "rows of #{alpha} disagree in #{extract.version}"
        end
      end)

    retired =
      for {alpha, rows} <- historic, not Map.has_key?(active, alpha), into: %{} do
        numeric =
          case rows |> Enum.map(& &1.numeric) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
            [] -> nil
            [n] -> n
            _ -> raise ArgumentError, "historic rows of #{alpha} disagree in #{extract.version}"
          end

        status = {:retired, latest_withdrawal(rows)}

        case Map.get(previous, alpha) do
          %{minor_unit: minor, numeric: prior} when is_integer(minor) ->
            if numeric != nil and numeric != prior,
              do: raise(ArgumentError, "#{alpha} numeric changed on retirement in #{extract.version}")

            {alpha, entry(alpha, prior, minor, status, rows, false)}

          _ ->
            {alpha, entry(alpha, numeric, :not_recorded, status, rows, false)}
        end
      end

    retained =
      for {alpha, prior} <- previous,
          not Map.has_key?(active, alpha) and not Map.has_key?(retired, alpha),
          into: %{} do
        status = if prior.status == :active, do: {:retired, :not_recorded}, else: prior.status
        {alpha, %{prior | status: status, rows: [], retained: true}}
      end

    snapshot = active |> Map.merge(retired) |> Map.merge(retained)
    missing = Map.keys(previous) -- Map.keys(snapshot)
    if missing != [], do: raise(ArgumentError, "fold would delete #{inspect(missing)}")
    snapshot
  end

  defp entry(alpha, numeric, minor, status, rows, retained),
    do: %{
      alpha: alpha,
      numeric: numeric,
      minor_unit: minor,
      status: status,
      rows: rows,
      retained: retained
    }

  defp active_numeric!(version, snapshot) do
    pairs = for {alpha, %{status: :active, numeric: n}} <- snapshot, is_integer(n), do: {n, alpha}
    index = Map.new(pairs)

    if map_size(index) != length(pairs),
      do: raise(ArgumentError, "active numeric codes repeat in #{version}")

    index
  end

  # The latest withdrawal text by its last YYYY or YYYY-MM date; the text is
  # kept verbatim ("1989 to 1990" stays as written).
  @doc false
  def latest_withdrawal(rows) do
    rows
    |> Enum.map(& &1.withdrawal)
    |> Enum.max_by(fn text ->
      Regex.scan(~r/(\d{4})(?:-(\d{2})(?!\d))?/, text)
      |> List.last()
      |> case do
        [_, year, month] -> {String.to_integer(year), String.to_integer(month)}
        [_, year] -> {String.to_integer(year), 0}
      end
    end)
  end
end
